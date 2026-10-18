import SwiftUI
import WebKit

/// Flux propose a l'utilisateur.
struct Track: Identifiable, Equatable {
    let url: String
    let width: Int
    let height: Int
    let segmented: Bool
    var id: String { url }

    var label: String {
        let size = (width > 0 && height > 0) ? " · \(width)×\(height)" : ""
        return String(((url as NSString).lastPathComponent).prefix(40)) + size
    }
}

/// Navigateur.
///
/// Un seul `WKWebView`, cree a l'ouverture de l'app et conserve jusqu'a sa
/// fermeture. Changer d'onglet ne le deplace pas dans la hierarchie de vues :
/// c'est ce qui evitait les ecrans blancs.
@MainActor
final class BrowserModel: NSObject, ObservableObject {

    // MARK: - Etat publie

    @Published var address = "" { didSet { syncAddress() } }
    @Published private(set) var loading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var message: String?
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var adCount = 0
    @Published private(set) var buttonPlaced = false
    @Published private(set) var failure: String?
    @Published private(set) var blocking = true
    @Published var pickedURL: String?

    // MARK: - Vue

    let web: WKWebView

    private var currentPage = ""
    private var lastLog = ""

    static var buildLabel: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "v\(version) (\(build))"
    }

    override init() {
        // La valeur est lue dans une constante locale : toucher une propriete
        // @Published avant super.init() est interdit par Swift.
        let enabled = UserDefaults.standard.object(forKey: "blocking") as? Bool ?? true

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .default()

        // Scripts enregistres une fois : ils sont appliques a chaque document
        // affiche par cette vue, sans jamais dependre d'un stockage externe.
        if enabled {
            config.userContentController.addUserScript(
                WKUserScript(source: PageScript.shield, injectionTime: .atDocumentStart,
                             forMainFrameOnly: false))
            config.userContentController.addUserScript(
                WKUserScript(source: PageScript.probe, injectionTime: .atDocumentStart,
                             forMainFrameOnly: false))
        }

        web = WKWebView(frame: UIScreen.main.bounds, configuration: config)
        super.init()

        blocking = enabled
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true

        CrashLog.step("Navigateur: pret \(Self.buildLabel)")
        address = "https://duckduckgo.com"
        currentPage = address
    }

    // MARK: - Navigation

    private func syncAddress() {
        guard address != currentPage else { return }
        guard let url = Self.normalise(address) else { return }
        currentPage = url.absoluteString
        message = nil
        tracks = []
        pickedURL = nil
        web.load(URLRequest(url: url))
    }

    private static func normalise(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil { return url }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "https://duckduckgo.com/?q=" + encoded)
    }

    func goBack() { web.goBack() }
    func reload() { web.reload() }

    func clearAddress() { address = "" }

    func toggleBlocking() {
        blocking.toggle()
        UserDefaults.standard.set(blocking, forKey: "blocking")
        // Le bouclier expose son etat : on le coupe sans recreer la vue, donc
        // sans jamais risquer un ecran blanc.
        let flag = blocking ? "true" : "false"
        web.evaluateJavaScript(
            "if (window.__xgrabShield) { window.__xgrabShield.on = \(flag); }"
        ) { [weak self] _, _ in
            self?.message = flag == "true" ? "Blocage activé" : "Blocage désactivé"
        }
        if !blocking {
            // La feuille de style disparait immediatement, la page revient a
            // son etat d'origine des le prochain battement.
            web.evaluateJavaScript("var s = document.getElementById('xgrab-shield'); if (s) s.remove();")
        }
    }

    // MARK: - Flux

    /// Flux retenu : celui choisi par l'utilisateur, sinon le meilleur.
    var chosen: Track? {
        if let pickedURL, let match = tracks.first(where: { $0.url == pickedURL }) { return match }
        return tracks.first
    }

    // MARK: - Telechargement

    func download(_ track: Track) {
        CrashLog.step("download: \(track.url.prefix(60)) \(track.height)p")
        web.evaluateJavaScript("navigator.userAgent") { [weak self] value, _ in
            guard let self = self else { return }
            let agent = (value as? String) ?? ""

            self.web.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                Task { @MainActor in
                    // Les cookies du WKWebView sont plus complets que ce que
                    // la page peut exposer : ils conditionnent l'acceptation
                    // d'un CDN.
                    let jar = self.cookieHeader(cookies, for: track.url)
                    _ = DownloadEngine.shared.enqueue(
                        url: track.url,
                        referer: self.currentPage,
                        userAgent: agent,
                        cookies: jar,
                        height: track.height > 0 ? track.height : nil,
                        title: self.web.title
                    )
                    self.message = "Ajouté aux fichiers"
                }
            }
        }
    }

    /// Ne renvoie que les cookies qui concernent le domaine du media.
    private func cookieHeader(_ cookies: [HTTPCookie], for url: String) -> String {
        guard let host = URL(string: url)?.host?.lowercased() else { return "" }
        return cookies
            .filter { cookie in
                let domain = cookie.domain
                    .lowercased()
                    .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return host == domain || host.hasSuffix("." + domain)
            }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }
}

// MARK: - Navigation

extension BrowserModel: WKNavigationDelegate {

    nonisolated func webView(_ web: WKWebView, didStartProvisionalNavigation nav: WKNavigation!) {
        Task { @MainActor in loading = true }
    }

    nonisolated func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            loading = false
            canGoBack = web.canGoBack
        }
    }

    nonisolated func webView(_ web: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    nonisolated func webView(_ web: WKWebView,
                             didFailProvisionalNavigation navigation: WKNavigation!,
                             withError error: Error) {
        report(error)
    }

    /// iOS tue le processus de contenu quand la memoire manque ou au retour de
    /// l'arriere-plan : sans rechargement, la vue reste blanche definitivement.
    nonisolated func webViewWebContentProcessDidTerminate(_ web: WKWebView) {
        CrashLog.step("Navigateur: processus de contenu tue, rechargement")
        Task { @MainActor in web.reload() }
    }

    private nonisolated func report(_ error: Error) {
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }
        Task { @MainActor in
            loading = false
            message = "Chargement impossible : \(nsError.localizedDescription)"
        }
    }
}

// MARK: - Popups

extension BrowserModel: WKUIDelegate {

    /// Aucune fenetre secondaire ne peut s'ouvrir : les liens `target="_blank"`
    /// sont charges dans la vue principale.
    nonisolated func webView(_ web: WKWebView,
                              createWebViewWith configuration: WKWebViewConfiguration,
                              for action: WKNavigationAction,
                              windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, action.request.httpMethod != "POST" {
            web.load(action.request)
        }
        return nil
    }

    nonisolated func webView(_ web: WKWebView,
                              runJavaScriptAlertPanelWithMessage message: String,
                              initiatedByFrame frame: WKFrameInfo,
                              completionHandler: @escaping () -> Void) {
        Task { @MainActor in self.message = message }
        completionHandler()
    }

    nonisolated func webView(_ web: WKWebView,
                              runJavaScriptConfirmPanelWithMessage message: String,
                              initiatedByFrame frame: WKFrameInfo,
                              completionHandler: @escaping (Bool) -> Void) {
        Task { @MainActor in self.message = message }
        completionHandler(true)
    }

    nonisolated func webView(_ web: WKWebView,
                              runJavaScriptTextInputPanelWithPrompt prompt: String,
                              defaultText: String?,
                              initiatedByFrame frame: WKFrameInfo,
                              completionHandler: @escaping (String?) -> Void) {
        Task { @MainActor in self.message = prompt }
        completionHandler(nil)
    }
}

// MARK: - Messages de la page

extension BrowserModel: WKScriptMessageHandler {

    nonisolated func userContentController(_ controller: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        guard message.name == "xgrab",
              let body = message.body as? [String: Any] else { return }

        switch body["event"] as? String {
        case "url":
            guard let value = body["url"] as? String else { return }
            Task { @MainActor in
                if value != currentPage {
                    currentPage = value
                    address = value
                }
            }

        case "scan":
            Task { @MainActor in absorb(body) }

        case "placed":
            Task { @MainActor in buttonPlaced = true }

        case "download":
            Task { @MainActor in
                guard let url = body["url"] as? String else { return }
                let track = Track(
                    url: url,
                    width: (body["width"] as? Int) ?? 0,
                    height: (body["height"] as? Int) ?? 0,
                    segmented: url.lowercased().contains(".m3u8")
                        || url.lowercased().contains(".mpd")
                )
                download(track)
            }

        case "failure":
            let text = (body["message"] as? String) ?? "erreur inconnue"
            Task { @MainActor in
                failure = text
                CrashLog.step("sonde en echec : \(text)")
            }

        default:
            break
        }
    }

    @MainActor
    private func absorb(_ body: [String: Any]) {
        failure = nil

        let list = (body["list"] as? [[String: Any]]) ?? []
        let found = list.compactMap { item -> Track? in
            guard let url = item["url"] as? String, !url.isEmpty else { return nil }
            return Track(
                url: url,
                width: (item["w"] as? Int) ?? 0,
                height: (item["h"] as? Int) ?? 0,
                segmented: (item["segmented"] as? Bool) ?? false
            )
        }
        tracks = found
        adCount = (body["ads"] as? Int) ?? 0
        buttonPlaced = body["empty"] as? Bool != true && !found.isEmpty

        // Un choix manuel reste valable tant que son flux est propose.
        if let pickedURL, !found.contains(where: { $0.url == pickedURL }) {
            self.pickedURL = nil
        }

        if let media = body["media"] as? String, media != lastLog {
            lastLog = media
            CrashLog.step("flux : \(media.prefix(70))")
        }

        switch (tracks.count, chosen) {
        case (0, _):
            message = nil
        case (1, let track?):
            message = "Vidéo prête : \(track.height > 0 ? "\(track.height)p" : "MP4")"
        case (_, let track?):
            let ads = adCount > 0 ? " · \(adCount) pub\(adCount > 1 ? "s" : "") écartée\(adCount > 1 ? "s" : "")" : ""
            message = "\(tracks.count) vidéos détectées\(ads) · \(track.height)p retenue"
        default:
            message = nil
        }
    }
}