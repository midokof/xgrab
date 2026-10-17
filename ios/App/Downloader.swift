import AVFoundation
import Foundation

/// Telecharge sur l'iPhone : URLSession en arriere-plan pour les fichiers
/// directs, AVAssetDownloadURLSession pour les flux HLS.
final class Downloader: NSObject, ObservableObject {
    static let shared = Downloader()

    /// Appele par l'app quand iOS reveille le processus pour une session.
    var backgroundCompletionHandler: (() -> Void)?

    private var downloads: URLSession!
    private var hls: AVAssetDownloadURLSession!
    private var mapping: [Int: String] = [:]

    private override init() {
        super.init()
        start()
    }

    // ------------------------------------------------------------- destination

    static var mediaDirectory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Downloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func isHLS(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.contains(".m3u8")
    }

    static func isDASH(_ url: String) -> Bool {
        url.lowercased().contains(".mpd")
    }

    static func filename(for url: String) -> String {        guard let components = URL(string: url)?.lastPathComponent,
              !components.isEmpty, components != "/" else {
            return "video-\(Int(Date().timeIntervalSince1970)).mp4"
        }
        return components
    }

    /// Message d'erreur lisible pour les refus de CDN.
    static func describe(status: Int) -> String {
        switch status {
        case 401: return "HTTP 401 - le lien exige une authentification"
        case 403: return "HTTP 403 - le CDN refuse : referer, cookies ou UA manquants"
        case 404: return "HTTP 404 - le lien a expire"
        case 429: return "HTTP 429 - trop de requetes, reessaie plus tard"
        default: return "HTTP \(status)"
        }
    }

    /// Evite d'ecraser un fichier deja telecharge.
    private static func unique(_ folder: URL, _ name: String) -> URL {
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

    // ------------------------------------------------------------------ sessions

    private func start() {
        let config = URLSessionConfiguration.background(withIdentifier: "app.xgrab.downloads")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        downloads = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        let hlsConfig = URLSessionConfiguration.background(withIdentifier: "app.xgrab.hls")
        hlsConfig.sessionSendsLaunchEvents = true
        hls = AVAssetDownloadURLSession(
            configuration: hlsConfig,
            assetDownloadDelegate: self,
            delegateQueue: nil
        )
    }

    // -------------------------------------------------------------------- actions

    @discardableResult
    func enqueue(url: String, referer: String, userAgent: String? = nil, cookies: String? = nil) -> Job? {
        guard let parsed = URL(string: url),
              parsed.scheme?.lowercased() == "http" || parsed.scheme?.lowercased() == "https" else {
            return nil
        }

        let job = JobStore.shared.enqueue(
            url: url,
            referer: referer,
            userAgent: userAgent,
            cookies: cookies
        )

        if Self.isDASH(url) {
            JobStore.shared.update(id: job.id) {
                $0.state = .failed
                $0.error = "Flux DASH non supporte sur iOS"
            }
            return job
        }

        var request = URLRequest(url: parsed)
        if !referer.isEmpty {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        // Un CDN protege refuse les requetes qui ne portent ni le User-Agent
        // du navigateur ni les cookies de session : sans cela, reponse 403.
        if let agent = userAgent, !agent.isEmpty {
            request.setValue(agent, forHTTPHeaderField: "User-Agent")
        }
        if let jar = cookies, !jar.isEmpty {
            request.setValue(jar, forHTTPHeaderField: "Cookie")
        }

        if Self.isHLS(url) {
            // AVURLAsset doit porter les memes en-tetes que le navigateur,
            // sinon le CDN refuse le manifeste ou les segments.
            var headers: [String: String] = [:]
            if let agent = userAgent, !agent.isEmpty { headers["User-Agent"] = agent }
            if let jar = cookies, !jar.isEmpty { headers["Cookie"] = jar }
            if !referer.isEmpty { headers["Referer"] = referer }

            let options: [String: Any] = headers.isEmpty
                ? [:]
                : [AVURLAssetHTTPHeaderFieldsKey: headers]
            let asset = AVURLAsset(url: parsed, options: options)
            let task = hls.makeAssetDownloadTask(
                asset: asset,
                assetTitle: job.filename,
                assetArtworkData: nil,
                options: [:]
            )
            task?.taskDescription = job.id
            task?.resume()
        } else {
            let task = downloads.downloadTask(with: request)
            task.taskDescription = job.id
            task.resume()
        }

        JobStore.shared.update(id: job.id) { $0.state = .running }
        return job
    }

    func cancel(jobID: String) {
        downloads.getAllTasks { tasks in
            tasks.first { $0.taskDescription == jobID }?.cancel()
        }
        hls.getAllTasks { tasks in
            tasks.first { $0.taskDescription == jobID }?.cancel()
        }
        JobStore.shared.update(id: jobID) {
            $0.state = .failed
            $0.error = "Annule"
        }
    }

    func retry(jobID: String) {
        guard let job = JobStore.shared.job(id: jobID) else { return }
        JobStore.shared.remove(id: jobID)
        enqueue(
            url: job.url,
            referer: job.referer,
            userAgent: job.userAgent,
            cookies: job.cookies
        )
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

extension Downloader: URLSessionDownloadDelegate {

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let id = downloadTask.taskDescription else { return }
        let ratio = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        JobStore.shared.update(id: id) {
            $0.progress = ratio
            $0.bytes = totalBytesWritten
            $0.state = .running
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let id = downloadTask.taskDescription else { return }

        // Le fichier temporaire est detruit des que la methode rend la main :
        // il faut le deplacer immediatement.
        let response = downloadTask.response as? HTTPURLResponse
        let status = response?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            JobStore.shared.update(id: id) {
                $0.state = .failed
                $0.error = Self.describe(status: status)
            }
            return
        }

        let suggested = response?.suggestedFilename
        let wanted = JobStore.shared.job(id: id)?.filename
        let name = Self.unique(Self.mediaDirectory, wanted ?? suggested ?? "video.mp4")
        try? FileManager.default.moveItem(at: location, to: name)

        let size = (try? FileManager.default.attributesOfItem(atPath: name.path)[.size] as? Int64) ?? nil
        JobStore.shared.update(id: id) {
            $0.state = .done
            $0.progress = 1
            $0.bytes = size ?? $0.bytes
            $0.localPath = name.path
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let id = task.taskDescription, let error = error else { return }
        let nsError = error as NSError
        // Une annulation est deja reportee par cancel(jobID:).
        guard nsError.code != NSURLErrorCancelled else { return }
        JobStore.shared.update(id: id) {
            $0.state = .failed
            $0.error = error.localizedDescription
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }
}

// MARK: - Flux HLS

extension Downloader: AVAssetDownloadDelegate {

    func urlSession(
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
        JobStore.shared.update(id: id) {
            $0.progress = min(max(ratio, 0), 1)
            $0.state = .running
        }
    }

    func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let id = assetDownloadTask.taskDescription else { return }
        let wanted = JobStore.shared.job(id: id)?.filename ?? "flux"
        let target = Self.unique(Self.mediaDirectory, wanted)

        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.moveItem(at: location, to: target)
        } catch {
            JobStore.shared.update(id: id) {
                $0.state = .failed
                $0.error = "Deplacement impossible"
            }
            return
        }

        JobStore.shared.update(id: id) {
            $0.state = .done
            $0.progress = 1
            $0.localPath = target.path
        }
    }
}