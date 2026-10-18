import AVFoundation
import Foundation

/// Operations pures sur les fichiers. Aucun etat, aucun acteur : utilisables
/// aussi bien depuis le main actor que depuis les delegates d'URLSession, qui
/// n'arrivent pas sur le main.
enum MediaFile {

    static var folder: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Downloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func isHLS(_ url: String) -> Bool { url.lowercased().contains(".m3u8") }
    static func isDASH(_ url: String) -> Bool { url.lowercased().contains(".mpd") }

    /// Nom propre, sans jeton, suffixe par la resolution.
    static func makeName(url: String, height: Int?, title: String?) -> String {
        var base = (URL(string: url)?.lastPathComponent ?? "").removingPercentEncoding ?? ""
        base = (base as NSString).deletingPathExtension
        base = base
            .components(separatedBy: CharacterSet(charactersIn: "-_ "))
            .filter { !$0.isEmpty }
            .joined(separator: "-")

        if base.count < 3, let title = title, !title.isEmpty {
            base = title
                .replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }
        if base.isEmpty { base = "video" }
        if base.count > 60 { base = String(base.prefix(60)) }

        // Un flux segmente est toujours assemble en MP4 par le systeme.
        let ext = (isHLS(url) || isDASH(url) || !url.lowercased().contains(".webm"))
            ? "mp4" : "webm"
        let suffix = (height ?? 0) > 0 ? "-\(height ?? 0)p" : ""
        return "\(base)\(suffix).\(ext)"
    }

    /// AVAssetDownloadURLSession ajoute lui-meme le conteneur : le titre ne
    /// doit pas porter d'extension.
    static func assetTitle(_ filename: String) -> String {
        (filename as NSString).deletingPathExtension
    }

    static func describe(status: Int) -> String {
        switch status {
        case 401: return "HTTP 401 - le lien exige une authentification"
        case 403: return "HTTP 403 - le CDN refuse l'accès (jeton expiré ?)"
        case 404: return "HTTP 404 - le lien a expiré"
        case 429: return "HTTP 429 - trop de requêtes, réessaie plus tard"
        default: return "HTTP \(status)"
        }
    }

    /// Evite d'ecraser un fichier deja telecharge.
    static func unique(_ folder: URL, _ name: String) -> URL {
        var candidate = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var counter = 2
        repeat {
            let next = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            candidate = folder.appendingPathComponent(next)
            counter += 1
        } while FileManager.default.fileExists(atPath: candidate.path)
        return candidate
    }

    static func size(of url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64 ?? 0
    }
}

/// Memorise le nom de chaque telechargement.
///
/// Les delegates d'URLSession ne passent pas par le main actor, or le fichier
/// temporaire d'un telecharge est supprime des la sortie de la methode : le
/// nom doit donc etre lisible sans attendre le main.
final class TitleCache: @unchecked Sendable {
    private let lock = NSLock()
    private var titles: [String: String] = [:]

    func set(_ title: String, for id: String) {
        lock.lock(); titles[id] = title; lock.unlock()
    }

    func title(for id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return titles[id]
    }

    func remove(_ id: String) {
        lock.lock(); titles[id] = nil; lock.unlock()
    }
}

/// Telechargement sur l'iPhone.
///
/// Deux chemins :
///  * `URLSession` en arriere-plan pour un fichier direct ;
///  * `AVAssetDownloadURLSession` pour un flux HLS, apres avoir choisi la
///    variante correspondant a la resolution demandee.
///
/// Aucun repli WebKit : creer un second WKWebView hors ecran s'est revele
/// instable et a provoque un crash. En cas de refus 403, on le dit
/// clairement plutot que de tenter un coup fragile.
@MainActor
final class DownloadEngine: NSObject, ObservableObject {
    static let shared = DownloadEngine()

    /// Appele quand iOS reveille le processus pour une session en arriere-plan.
    var backgroundCompletionHandler: (() -> Void)?

    @Published private(set) var notice: String?

    private var session: URLSession!
    private var hls: AVAssetDownloadURLSession!
    private let titles = TitleCache()

    private override init() {
        super.init()
        start()
    }

    // ---------------------------------------------------------------- chemins

    // --------------------------------------------------------------- sessions

    private func start() {
        let config = URLSessionConfiguration.background(withIdentifier: "app.xgrab.files")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        let hlsConfig = URLSessionConfiguration.background(withIdentifier: "app.xgrab.hls")
        hlsConfig.sessionSendsLaunchEvents = true
        hls = AVAssetDownloadURLSession(
            configuration: hlsConfig,
            assetDownloadDelegate: self,
            delegateQueue: nil
        )
        CrashLog.step("Telechargement: sessions pretes")
    }

    // ---------------------------------------------------------------- actions

    @discardableResult
    func enqueue(url: String,
                 referer: String,
                 userAgent: String?,
                 cookies: String?,
                 height: Int?,
                 title: String?) -> String? {
        CrashLog.step("enqueue: \(url.prefix(70)) \(height ?? 0)p")

        guard let parsed = URL(string: url),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            notice = "Lien non valide"
            return nil
        }

        let name = MediaFile.makeName(url: url, height: height, title: title)

        if MediaFile.isDASH(url) {
            let job = JobStore.shared.add(url: url, referer: referer, userAgent: userAgent,
                                          cookies: cookies, filename: name, height: height)
            JobStore.shared.update(id: job.id) {
                $0.state = .failed
                $0.error = "Flux MPEG-DASH non pris en charge par iOS"
            }
            notice = "Flux DASH : format non pris en charge"
            return job.id
        }

        let job = JobStore.shared.add(url: url, referer: referer, userAgent: userAgent,
                                      cookies: cookies, filename: name, height: height)
        titles.set(name, for: job.id)
        notice = "Téléchargement lancé"

        if MediaFile.isHLS(url) {
            JobStore.shared.update(id: job.id) {
                $0.state = .running
                $0.error = "Lecture des qualités…"
            }
            let id = job.id
            HLSVariants.resolve(master: url, height: height ?? 0, referer: referer,
                                userAgent: userAgent, cookies: cookies) { [weak self] picked in
                Task { @MainActor in
                    self?.startHLS(jobID: id, url: picked, name: name,
                                   referer: referer, userAgent: userAgent, cookies: cookies)
                }
            }
        } else {
            startDirect(jobID: job.id, url: parsed, name: name, referer: referer,
                        userAgent: userAgent, cookies: cookies)
        }
        return job.id
    }

    private func startDirect(jobID: String, url: URL, name: String,
                             referer: String, userAgent: String?, cookies: String?) {
        var request = URLRequest(url: url)
        if !referer.isEmpty { request.setValue(referer, forHTTPHeaderField: "Referer") }
        // Un CDN protege refuse une requete depourvue du User-Agent du
        // navigateur et des cookies de session : reponse 403 sans eux.
        if let agent = userAgent, !agent.isEmpty {
            request.setValue(agent, forHTTPHeaderField: "User-Agent")
        }
        if let jar = cookies, !jar.isEmpty {
            request.setValue(jar, forHTTPHeaderField: "Cookie")
        }

        let task = session.downloadTask(with: request)
        task.taskDescription = jobID
        task.resume()
        JobStore.shared.update(id: jobID) { $0.state = .running }
    }

    private func startHLS(jobID: String, url: String, name: String,
                          referer: String, userAgent: String?, cookies: String?) {
        guard let parsed = URL(string: url) else {
            JobStore.shared.update(id: jobID) {
                $0.state = .failed
                $0.error = "URL de flux invalide"
            }
            return
        }

        var headers: [String: String] = [:]
        if let agent = userAgent, !agent.isEmpty { headers["User-Agent"] = agent }
        if let jar = cookies, !jar.isEmpty { headers["Cookie"] = jar }
        if !referer.isEmpty { headers["Referer"] = referer }

        // La constante Swift n'est pas exposee : on utilise la cle litterale
        // attendue par AVURLAsset.
        let options: [String: Any] = headers.isEmpty
            ? [:]
            : ["AVURLAssetHTTPHeaderFieldsKey": headers]

        let asset = AVURLAsset(url: parsed, options: options)
        let task = hls.makeAssetDownloadTask(
            asset: asset,
            assetTitle: MediaFile.assetTitle(name),
            assetArtworkData: nil,
            options: [:]
        )
        task?.taskDescription = jobID
        task?.resume()
        JobStore.shared.update(id: jobID) { $0.error = nil }
    }

    func cancel(jobID: String) {
        session.getAllTasks { tasks in
            tasks.first { $0.taskDescription == jobID }?.cancel()
        }
        hls.getAllTasks { tasks in
            tasks.first { $0.taskDescription == jobID }?.cancel()
        }
        JobStore.shared.update(id: jobID) {
            $0.state = .failed
            $0.error = "Annulé"
        }
    }

    func retry(jobID: String) {
        guard let job = JobStore.shared.job(id: jobID) else { return }
        JobStore.shared.remove(id: jobID)
        enqueue(url: job.url, referer: job.referer, userAgent: job.userAgent,
                cookies: job.cookies, height: job.height, title: nil)
    }

    func delete(jobID: String) {
        cancel(jobID: jobID)
        if let path = JobStore.shared.job(id: jobID)?.localPath {
            try? FileManager.default.removeItem(atPath: path)
        }
        JobStore.shared.remove(id: jobID)
    }
}

// MARK: - Fichiers directs

extension DownloadEngine: URLSessionDownloadDelegate {

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let id = downloadTask.taskDescription else { return }
        let expected = totalBytesExpectedToWrite
        let ratio = expected > 0 ? Double(totalBytesWritten) / Double(expected) : 0
        Task { @MainActor in
            JobStore.shared.update(id: id) {
                $0.progress = ratio
                $0.bytes = totalBytesWritten
                $0.state = .running
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let id = downloadTask.taskDescription else { return }
        // Le fichier temporaire disparait a la sortie de la methode : le
        // deplacement doit avoir lieu maintenant, sans attendre le main actor.
        let response = downloadTask.response as? HTTPURLResponse
        let status = response?.statusCode ?? 0
        let wanted = titles.title(for: id) ?? "video.mp4"

        guard (200..<300).contains(status) else {
            let reason = MediaFile.describe(status: status)
            Task { @MainActor in
                JobStore.shared.update(id: id) { $0.state = .failed; $0.error = reason }
                CrashLog.step("refus \(status) : \(wanted)")
            }
            return
        }

        let target = MediaFile.unique(MediaFile.folder, wanted)
        try? FileManager.default.moveItem(at: location, to: target)
        let size = MediaFile.size(of: target)

        Task { @MainActor in
            JobStore.shared.update(id: id) {
                $0.state = .done
                $0.progress = 1
                $0.bytes = size
                $0.localPath = target.path
                $0.error = nil
            }
            CrashLog.step("termine : \(target.lastPathComponent)")
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let id = task.taskDescription, let error = error else { return }
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }
        let message = error.localizedDescription
        Task { @MainActor in
            JobStore.shared.update(id: id) { $0.state = .failed; $0.error = message }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            backgroundCompletionHandler?()
            backgroundCompletionHandler = nil
        }
    }
}

// MARK: - Flux HLS

extension DownloadEngine: AVAssetDownloadDelegate {

    nonisolated func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        didLoad timeRange: CMTimeRange,
        totalTimeRangesLoaded loadedTimeRanges: [NSValue],
        timeRangeExpectedToLoad: CMTimeRange,
        for asset: AVAsset
    ) {
        guard let id = assetDownloadTask.taskDescription else { return }
        let loaded = loadedTimeRanges.reduce(0.0) { total, value in
            total + value.timeRangeValue.duration.seconds
        }
        let expected = timeRangeExpectedToLoad.duration.seconds
        let ratio = expected > 0 ? loaded / expected : 0
        Task { @MainActor in
            JobStore.shared.update(id: id) {
                $0.progress = min(max(ratio, 0), 1)
                $0.state = .running
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let id = assetDownloadTask.taskDescription else { return }
        let wanted = titles.title(for: id) ?? "flux.mp4"
        let target = MediaFile.unique(MediaFile.folder, wanted)

        do {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: location, to: target)
        } catch {
            Task { @MainActor in
                JobStore.shared.update(id: id) {
                    $0.state = .failed
                    $0.error = "Enregistrement impossible"
                }
            }
            return
        }

        let size = MediaFile.size(of: target)
        Task { @MainActor in
            JobStore.shared.update(id: id) {
                $0.state = .done
                $0.progress = 1
                $0.bytes = size
                $0.localPath = target.path
                $0.error = nil
            }
            CrashLog.step("HLS termine : \(target.lastPathComponent)")
        }
    }
}