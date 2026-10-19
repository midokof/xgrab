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

    /// Noms de fichiers que les CDN donnent a un manifeste sans extension :
    /// `/playlist`, `/manifest`, `/master`. Sans cette detection, l'application
    /// sauvegarde le texte du manifeste dans un fichier intititule `.mp4`.
    ///
    /// Volontairement absent : `index`. Trop d'adresses directes se terminent
    /// ainsi, et le juge de paix reste le corps de la reponse.
    private static let manifestNames: Set<String> = [
        "playlist", "manifest", "master", "chunklist", "media",
    ]

    /// Heuristique : vrai pour un manifeste a forte probabilite, faux ne
    /// garantit pas un fichier direct. Le juge de paix reste le corps de la
    /// reponse, qui commence par `#EXTM3U`.
    static func looksLikeManifest(_ url: String) -> Bool {
        if isHLS(url) || isDASH(url) { return true }
        guard let path = URL(string: url)?.path.lowercased() else { return false }
        guard let last = path.split(separator: "/").last else { return false }
        return manifestNames.contains(String(last))
    }

    /// Noms que tous les CDN donnent a leur manifeste. Ils ne renseignent
    /// personne : un fichier `index-720p.mp4` est inexploitable dans le
    /// dossier telechargements, la ou le titre de la video l'est.
    private static let genericNames: Set<String> = [
        "index", "master", "manifest", "playlist", "media", "stream",
        "video", "chunklist", "main", "playlist0", "list",
    ]

    /// Un nom muet : surtout hexadecimal, avec au plus un prefixe — les
    /// identifiants de session que les CDN inventent n'ont aucun sens pour
    /// l'utilisateur.
    private static func isOpaque(_ name: String) -> Bool {
        guard name.count >= 8 else { return false }
        var hex = 0
        var other = 0
        for character in name {
            if character.isHexDigit { hex += 1 } else { other += 1 }
        }
        return other <= 2 && hex >= 8
    }

    /// Nom propre, sans jeton, suffixe par la resolution.
    static func makeName(url: String, height: Int?, title: String?) -> String {
        var base = (URL(string: url)?.lastPathComponent ?? "").removingPercentEncoding ?? ""
        base = (base as NSString).deletingPathExtension
        base = base
            .components(separatedBy: CharacterSet(charactersIn: "-_ "))
            .filter { !$0.isEmpty }
            .joined(separator: "-")

        let vague = base.count < 3
            || genericNames.contains(base.lowercased())
            || isOpaque(base)

        if vague, let title = title, !title.isEmpty {
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
                                      cookies: cookies, filename: name, height: height,
                                      title: title)
        titles.set(name, for: job.id)
        notice = "Téléchargement lancé"

        if MediaFile.looksLikeManifest(url) {
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

    // MARK: - Flux HLS

    /// Point d'entree unique des flux segmentes.
    ///
    /// Un flux **en clair** passe par `AVAssetDownloadURLSession` : c'est le
    /// chemin qui fonctionne, il survit a une suspension de l'app et produit un
    /// conteneur propre.
    ///
    /// Un flux **chiffre** passe par `HLSDownloader`. Pas par choix :
    /// `AVAssetDownloadURLSession` accepte la tache, ne leve aucune erreur et
    /// n'appelle jamais aucun delegate. Le job reste « en cours » indefini.
    @discardableResult
    func launch(plan: HLSPlan,
                referer: String,
                userAgent: String?,
                cookies: CookieJar,
                title: String?) -> String? {

        let height = plan.height > 0 ? plan.height : nil
        let name = MediaFile.makeName(url: plan.variant.absoluteString,
                                      height: height, title: title)

        let job = JobStore.shared.add(url: plan.manifest.absoluteString, referer: referer,
                                      userAgent: userAgent, cookies: cookies.flat,
                                      filename: name, height: height, title: title)
        titles.set(name, for: job.id)
        notice = "Téléchargement lancé"

        if let blocked = plan.unsupportedMethod() {
            let reason = HLSError.unsupported(blocked).errorDescription ?? "Chiffrement non pris en charge"
            JobStore.shared.update(id: job.id) {
                $0.state = .failed
                $0.error = reason
            }
            return job.id
        }

        if plan.encrypted {
            JobStore.shared.update(id: job.id) { $0.error = "Lecture du flux chiffré…" }
            HLSDownloader.shared.run(plan: plan, jobID: job.id, name: name,
                                     referer: referer, userAgent: userAgent,
                                     jar: cookies)
        } else {
            // `plan.variant` est deja un manifeste media : la variante a ete
            // choisie en amont. Relire le manifeste ici ne ferait qu'ajouter
            // un aller-retour et ne changerait rien.
            //
            // Le `Cookie` est restreint a l'hote du media : transmettre tout le
            // magasin du navigateur au CDN serait divulguer des sessions
            // etrangeres au flux demande.
            JobStore.shared.update(id: job.id) { $0.error = "Téléchargement du flux…" }
            startHLS(jobID: job.id, url: plan.variant.absoluteString, name: name,
                     referer: referer, userAgent: userAgent,
                     cookies: cookies.header(for: plan.variant))
        }
        return job.id
    }

    /// Repli quand le plan n'a pas pu etre construit dans la page : CORS, ou
    /// script absent parce que le blocage est coupe.
    ///
    /// Le `WKWebView` n'a pas toujours les memes droits que la page sur un
    /// manifeste tiers. Sans ce repli, l'echec serait definitif.
    func enqueueHLSNatively(manifest: String,
                            height: Int,
                            referer: String,
                            userAgent: String?,
                            cookies: CookieJar,
                            title: String?) {
        guard let url = URL(string: manifest), url.scheme != nil else {
            notice = "Lien de flux invalide"
            return
        }
        notice = "Lecture du flux…"
        CrashLog.step("plan HLS natif : \(manifest.prefix(70))")

        Task {
            do {
                let plan = try await HLSFetcher.plan(manifest: url, height: height,
                                                     referer: referer,
                                                     userAgent: userAgent,
                                                     cookies: cookies)
                _ = launch(plan: plan, referer: referer, userAgent: userAgent,
                           cookies: cookies, title: title)
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription

                // Le predicat « manifeste » est une heuristique : des CDN
                // nomment leurs fichiers `/playlist` sans extension, mais la
                // meme forme peut designer un fichier direct. Plutot que de
                // declarer forfait, on tente le telechargement brut.
                if !MediaFile.isHLS(manifest) {
                    CrashLog.step("pas un manifeste, telechargement direct : "
                                  + "\(manifest.prefix(50))")
                    _ = enqueue(url: manifest, referer: referer,
                                userAgent: userAgent,
                                cookies: cookies.flat,
                                height: height > 0 ? height : nil,
                                title: title)
                } else {
                    notice = reason
                    CrashLog.step("plan HLS natif en echec : \(reason)")
                }
            }
        }
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
        // Le chemin natif n'a pas de tete URLSession a annuler : c'est la
        // boucle entre les segments qu'il faut interrompre.
        HLSDownloader.shared.stop(jobID)
        JobStore.shared.update(id: jobID) {
            $0.state = .failed
            $0.error = "Annulé"
        }
    }

    func retry(jobID: String) {
        guard let job = JobStore.shared.job(id: jobID) else { return }
        JobStore.shared.remove(id: jobID)

        // Un flux segmente ne repasse jamais par `AVAssetDownloadURLSession` :
        // c'est precisement le chemin qui echoue en silence. Le plan est
        // reconstruit, et c'est lui qui decidera du chemin a prendre.
        if MediaFile.looksLikeManifest(job.url) {
            enqueueHLSNatively(manifest: job.url,
                               height: job.height ?? 0,
                               referer: job.referer,
                               userAgent: job.userAgent,
                               cookies: CookieJar(header: job.cookies),
                               title: job.title)
            return
        }

        enqueue(url: job.url, referer: job.referer, userAgent: job.userAgent,
                cookies: job.cookies, height: job.height, title: job.title)
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

// MARK: - Flux HLS chiffre

/// Telechargement, dechiffrement et assemblage d'un flux HLS chiffre.
///
/// Tout se passe hors du main actor : une heure de video represente plusieurs
/// centaines de requetes et aucun de ces pas n'a besoin de l'interface.
///
/// L'assemblage depend du format, et se decide sur les octets reels plutot
/// que sur le manifeste :
///
///  * des segments MPEG-2 concatenes forment un `.ts` valide qu'il faut
///    remuxer en MP4 — `AVAssetExportSession` le fait sans recompresser ;
///  * des fragments MP4 (`EXT-X-MAP` + `.m4s`) forment deja un fichier
///    ISO-BMFF complet une fois le segment d'initialisation prepended.
final class HLSDownloader: @unchecked Sendable {

    static let shared = HLSDownloader()

    /// Quatre requetes simultanees : au-dela, le CDN commence a renvoyer des
    /// 429 et le gain devient nul.
    private let window = 4

    private let lock = NSLock()
    private var stopped: Set<String> = []
    /// Jobs dont un thread natif est effectivement responsable. Un verrou
    /// d'annulation pose sur un job qui n'en a pas — un telechargement direct,
    /// un flux non chiffre — ne serait jamais leve.
    private var owned: Set<String> = []

    private init() {}

    func stop(_ jobID: String) {
        lock.lock(); defer { lock.unlock() }
        guard owned.contains(jobID) else { return }
        stopped.insert(jobID)
    }

    /// Prend la responsabilite du job, puis la rend en fin de tache. C'est ce
    /// qui borne `stopped` : sans `owned`, une annulation sur un job natif deja
    /// termine laisserait une entree pour toute la duree du processus.
    private func claim(_ jobID: String) {
        lock.lock(); owned.insert(jobID); lock.unlock()
    }

    private func forget(_ jobID: String) {
        lock.lock(); stopped.remove(jobID); owned.remove(jobID); lock.unlock()
    }

    private func isStopped(_ jobID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped.contains(jobID)
    }

    func run(plan: HLSPlan,
             jobID: String,
             name: String,
             referer: String,
             userAgent: String?,
             jar: CookieJar) {

        var headers: [String: String] = [:]
        if let agent = userAgent, !agent.isEmpty { headers["User-Agent"] = agent }
        if !referer.isEmpty { headers["Referer"] = referer }

        let total = plan.segments.count
        CrashLog.step("HLS: \(total) segments, cle\(plan.keyUris.count > 1 ? "s" : "") \(plan.keyUris.count)")
        claim(jobID)

        Task.detached(priority: .utility) { [self] in
            defer { forget(jobID) }
            do {
                let file = try await assemble(plan: plan, jobID: jobID, name: name,
                                             headers: headers, jar: jar, total: total)
                await JobStore.shared.update(id: jobID) {
                    $0.state = .done
                    $0.progress = 1
                    $0.bytes = MediaFile.size(of: file)
                    $0.localPath = file.path
                    $0.error = nil
                }
                CrashLog.step("HLS termine : \(file.lastPathComponent)")
            } catch {
                // Une annulation remonte sous la forme de `HLSError.cancelled`
                // ou d'une `URLError.cancelled` du transport : les deux
                // doivent se lire « Annulé », pas comme une panne.
                let reason: String
                if isStopped(jobID) || Task.isCancelled {
                    reason = "Annulé"
                } else {
                    reason = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                }
                await JobStore.shared.update(id: jobID) {
                    $0.state = .failed
                    $0.error = reason
                }
                CrashLog.step("HLS en echec : \(reason)")
            }
        }
    }

    private enum Assembly: Equatable {
        case transportStream
        case fragmentedMP4
    }

    private func assemble(plan: HLSPlan,
                          jobID: String,
                          name: String,
                          headers: [String: String],
                          jar: CookieJar,
                          total: Int) async throws -> URL {

        let folder = MediaFile.folder
        let work = folder.appendingPathComponent(".xgrab-\(jobID.prefix(8))",
                                                 isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        // Le dossier de travail ne contient que des intermediaires : le
        // fichier livre est deja sorti.
        defer { try? FileManager.default.removeItem(at: work) }

        // 1. Cles absentes du plan : la page les a lues quand elle a pu, on
        //    complete ce qu'elle n'a pas obtenu.
        var fetched = plan.keys
        if fetched.count < plan.keyUris.count {
            fetched.append(contentsOf: Array(repeating: Data(),
                                             count: plan.keyUris.count - fetched.count))
        }
        for index in fetched.indices where fetched[index].isEmpty && index < plan.keyUris.count {
            guard !isStopped(jobID) else { throw HLSError.cancelled }
            fetched[index] = try await HLSFetcher.key(from: plan.keyUris[index],
                                                       headers: headers, jar: jar)
            CrashLog.step("HLS: cle \(index + 1) recuperee en natif")
        }
        let keys = fetched

        // 2. Segment d'initialisation. La specification dit qu'il n'est jamais
        //    chiffre par la cle du media : il s'ecrit tel quel.
        var head = Data()
        if let initURL = plan.initURL {
            head = try await HLSFetcher.data(from: initURL, range: plan.initRange,
                                             headers: headers, jar: jar)
        }

        // 3. Segments : `window` requetes en vol, ecriture dans l'ordre.
        //    L'ordre compte — on ne peut pas permuter, le flux est continu.
        let joined = work.appendingPathComponent("joined.ts")
        _ = FileManager.default.createFile(atPath: joined.path, contents: nil)
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: joined)
        } catch {
            // Sans ce bouclage, le job affiche une erreur Foundation brute au
            // lieu d'une explication utile.
            throw HLSError.assembly
        }
        defer { try? handle.close() }

        var written = Int64(0)
        var first: Data?
        if !head.isEmpty {
            try handle.write(contentsOf: head)
            written += Int64(head.count)
        }

        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            var scheduled = 0
            var next = 0
            var buffered: [Int: Data] = [:]

            while next < total || !buffered.isEmpty {
                if isStopped(jobID) {
                    group.cancelAll()
                    throw HLSError.cancelled
                }
                while scheduled < total && (scheduled - next) < window {
                    let index = scheduled
                    scheduled += 1
                    let segment = plan.segments[index]
                    group.addTask {
                        let payload = try await HLSFetcher.payload(of: segment, keys: keys,
                                                                    headers: headers, jar: jar)
                        return (index, payload)
                    }
                }
                guard let (index, data) = try await group.next() else { break }

                buffered[index] = data
                while let ready = buffered.removeValue(forKey: next) {
                    if first == nil { first = ready }
                    try handle.write(contentsOf: ready)
                    written += Int64(ready.count)
                    next += 1
                    let done = next
                    let bytes = written
                    await JobStore.shared.update(id: jobID) {
                        $0.progress = min(Double(done) / Double(total), 1)
                        $0.bytes = bytes
                        $0.state = .running
                    }
                }
            }
        }

        // 4. Assemblage. Le fichier doit etre vide sur le disque avant que
        // `AVURLAsset` ne l'ouvre ; la fermeture est differee a la fin de la
        // fonction, on force donc l'ecriture ici.
        // `synchronizeFile` ne leve pas : il force l'ecriture sans garantie de
        // retour.
        handle.synchronizeFile()

        // Le format se decide sur ce que le manifeste annonce, le
        // test des octets ne servant qu'a confirmer le cas MPEG-2.
        let sample = first ?? head
        let kind: Assembly
        if plan.initURL != nil {
            // Un segment d'initialisation n'existe que dans un flux fragmente.
            kind = .fragmentedMP4
        } else if HLSCrypto.looksLikeMPEGTS(sample) {
            kind = .transportStream
        } else {
            throw HLSError.assembly
        }

        let target = MediaFile.unique(folder, name)
        try? FileManager.default.removeItem(at: target)

        switch kind {
        case .fragmentedMP4:
            // Init + fragments : deja un MP4 complet, rien a remuxer.
            try FileManager.default.moveItem(at: joined, to: target)
        case .transportStream:
            let remuxed = work.appendingPathComponent("out.mp4")
            try await remux(from: joined, to: remuxed)
            try FileManager.default.moveItem(at: remuxed, to: target)
        }
        return target
    }

    /// Convertit le `.ts` concatene. `AVAssetExportPresetPassthrough` ne
    /// recompresse rien : la qualite d'origine est conservee.
    ///
    /// `export(to:as:)` est `iOS 18.0+` sur les SDK 16 et 17, puis recule
    /// en `iOS 13.0+` avec `@backDeployed` sur le SDK 26. Sans le garde, le
    /// projet ne compilerait que sur le dernier. Le garde reste necessaire,
    /// et le compilateur ne se plaint pas de la depreciation dans la branche
    /// qu'il protege.
    private func remux(from source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let exporter = AVAssetExportSession(asset: asset,
                                                 presetName: AVAssetExportPresetPassthrough) else {
            throw HLSError.assembly
        }
        exporter.shouldOptimizeForNetworkUse = true

        if #available(iOS 18.0, *) {
            try await exporter.export(to: destination, as: .mp4)
        } else {
            exporter.outputURL = destination
            exporter.outputFileType = .mp4
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                exporter.exportAsynchronously { done.resume() }
            }
            guard exporter.status == .completed else { throw HLSError.assembly }
        }
    }
}