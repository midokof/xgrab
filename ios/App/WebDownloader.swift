import Foundation
import WebKit

/// Telecharge en passant par le moteur WebKit.
///
/// Certains CDN refusent une requete URLSession : ils verifient l'empreinte
/// TLS du client, pas seulement les en-tetes. Le navigateur passe, donc on
/// fait faire le travail a WebKit : un WKWebView hors ecran charge la page
/// d'origine (pour le Referer et les cookies), puis navigue vers le media
/// avec la politique `download`. WebKit ecrit alors le fichier lui-meme.
final class WebDownloader: NSObject {

    static let shared = WebDownloader()

    private var web: WKWebView?
    private var jobID: String?
    private var mediaURL: String?
    private var target: URL?
    private var progressTimer: Timer?
    /// Passe a vrai une fois la page d'origine chargee : la navigation
    /// suivante (le media) doit etre traitee comme un telechargement.
    private var awaitingMedia = false

    // MARK: - Lancement

    /// - Parameters:
    ///   - url: l'URL du media a recuperer
    ///   - pageURL: la page d'origine, chargee d'abord pour fournir le
    ///     Referer et poser les cookies de session
    func start(jobID: String, url: URL, pageURL: URL?, filename: String) {
        stop()

        self.jobID = jobID
        self.mediaURL = url.absoluteString

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        view.isHidden = true
        self.web = view

        let folder = Downloader.mediaDirectory
        let destination = unique(folder, filename)
        self.target = destination

        if let pageURL = pageURL {
            // La page d'abord : WebKit enverra son adresse comme Referer
            // lors de la navigation vers le media, et partagera ses cookies.
            view.load(URLRequest(url: pageURL))
        } else {
            view.load(URLRequest(url: url))
        }
    }

    func stop() {
        progressTimer?.invalidate()
        progressTimer = nil
        web?.navigationDelegate = nil
        web?.stopLoading()
        web = nil
    }

    // MARK: - Progression

    private func startProgress() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        guard let jobID = jobID, let web = web else { return }
        let total = web.progress.totalUnitCount
        let done = web.progress.completedUnitCount
        guard total > 0 else { return }
        JobStore.shared.update(id: jobID) {
            $0.progress = min(max(Double(done) / Double(total), 0), 1)
            $0.state = .running
        }
    }

    // MARK: - Destination

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

    private func finish(success: Bool, error: String?) {
        progressTimer?.invalidate()
        progressTimer = nil

        if let jobID = jobID {
            JobStore.shared.update(id: jobID) {
                if success {
                    $0.state = .done
                    $0.progress = 1
                    $0.localPath = self.target?.path
                } else {
                    $0.state = .failed
                    $0.error = error ?? "Echec du telechargement"
                }
            }
        }
        stop()
    }
}

// MARK: - Navigation

extension WebDownloader: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // La page d'origine est chargee : on part maintenant sur le media.
        guard let media = mediaURL, let url = URL(string: media) else { return }
        if awaitingMedia { return }
        awaitingMedia = true
        webView.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }
        finish(success: false, error: "Chargement impossible : \(nsError.localizedDescription)")
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }
        finish(success: false, error: "Site injoignable : \(nsError.localizedDescription)")
    }

    /// C'est ici que la requete vers le media est transformee en telechargement.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if awaitingMedia {
            awaitingMedia = false
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
        startProgress()
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
        startProgress()
    }
}

// MARK: - Telechargement

extension WebDownloader: WKDownloadDelegate {

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else {
            completionHandler(nil)
            finish(success: false, error: "HTTP \(status) - le CDN refuse toujours")
            return
        }
        completionHandler(target)
    }

    func downloadDidFinish(_ download: WKDownload) {
        finish(success: true, error: nil)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }
        finish(success: false, error: error.localizedDescription)
    }
}
