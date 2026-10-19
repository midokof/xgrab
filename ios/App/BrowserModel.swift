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
    /// Combien de balises <video> la page contient, et combien ont expose une
    /// URL exploitable. C'est le couple qui dit immediatement pourquoi le
    /// bouton est absent.
    @Published private(set) var seen = 0
    @Published private(set) var resolved = 0
    @Published private(set) var failure: String?
    @Published private(set) var blocking = true
    @Published var pickedURL: String?

    // MARK: - Vue

    let web: WKWebView

    /// Relais faible vers le gestionnaire de messages : sans lui, le
    /// `WKUserContentController` retiendrait le modele, qui retient la vue,
    /// qui retient la configuration, qui retient le controleur.
    private let bridge = ScriptBridge()

    /// `User-Agent` du lecteur, lu une fois : le CDN refuse une requete qui
    /// ne le reprend pas, et le relire a chaque clic coute un aller-retour.
    private(set) var agent = ""

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
        //
        // Le planificateur HLS est toujours injecte, bloque ou non : il ne
        // touche ni au DOM ni aux fonctions natives, il se contente d'ouvrir
        // des requetes quand on lui demande un plan. Le reste depend du
        // blocage.
        config.userContentController.addUserScript(
            WKUserScript(source: PageScript.hlsPlanner, injectionTime: .atDocumentStart,
                         forMainFrameOnly: false))

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

        // `addUserScript` enregistre des scripts, pas des canaux. Sans cet
        // `add`, `window.webkit.messageHandlers.xgrab` vaut `undefined`, chaque
        // `postMessage` leve une TypeError que le `try/catch` des scripts avale,
        // et l'app ne sait rien du tout — silencieusement.
        //
        // Le relais est faible : `WKUserContentController` retient son handler,
        // et la configuration est retenue par la vue, qui l'est par le modele.
        // `WKWebView` recopie sa configuration : on enregistre donc le canal sur
        // celle de la vue, qui est celle qui sert vraiment.
        bridge.owner = self
        web.configuration.userContentController.add(bridge, name: "xgrab")

        blocking = enabled
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true

        web.evaluateJavaScript("navigator.userAgent") { [weak self] value, _ in
            guard let text = value as? String, !text.isEmpty else { return }
            Task { @MainActor in self?.agent = text }
        }

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
        // Un flux segmenté passe par le planificateur de la page : c'est le seul
        // endroit ou le manifeste et la cle sont lisibles. `AVAssetDownloadURLSession`
        // refuse un flux chiffre sans rien dire.
        if MediaFile.looksLikeManifest(track.url) {
            planFromPage(track)
            return
        }

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

    /// Demande le plan a la page, comme le fait le bouton qu'elle pose.
    ///
    /// `callAsyncJavaScript` attend la promesse et passe ses arguments par un
    /// dictionnaire : l'URL n'est jamais concatenee dans du JavaScript, ce qui
    /// supprime toute question d'echappement.
    private func planFromPage(_ track: Track) {
        CrashLog.step("plan HLS depuis la page : \(track.url.prefix(60))")
        message = "Lecture du flux…"

        // Deux libelles `in:` : le selecteur ObjC est
        // `callAsyncJavaScript:arguments:inFrame:inContentWorld:completionHandler:`,
        // et WebKit retranche `Frame` puis `ContentWorld` pour ne pas repeter
        // le type. Un seul `in:` ne compile pas.
        _ = web.callAsyncJavaScript(
            "return await window.__xgrabHLS.plan(url, height);",
            arguments: ["url": track.url, "height": track.height],
            in: nil,
            in: .page
        ) { [weak self] result in
            Task { @MainActor in
                // `[weak self]` est ce qui rend le `guard let` valable : sans
                // liste de capture, `self` n'est pas optionnel ici.
                guard let self = self else { return }
                if case .success(let body as [String: Any]) = result {
                    self.acceptPlan(body)
                } else {
                    // Page pas encore injectee, CORS, ou reponse non
                    // serialisable : le plan se construit en Swift plutot que
                    // de s'arreter.
                    if case .failure(let error) = result {
                        CrashLog.step("plan HLS refuse par la page : "
                                      + "\(error.localizedDescription.prefix(60))")
                    }
                    self.enqueueNativePlan(url: track.url, height: track.height)
                }
            }
        }
    }

    /// Repli quand la page ne sait pas lire le manifeste : CORS, ou script
    /// absent parce que le blocage est coupe.
    private func enqueueNativePlan(url: String, height: Int) {
        CrashLog.step("plan HLS en repli natif : \(url.prefix(60))")
        message = "Plan du flux en cours…"
        web.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            Task { @MainActor in
                guard let self = self else { return }
                DownloadEngine.shared.enqueueHLSNatively(
                    manifest: url,
                    height: height,
                    referer: self.currentPage,
                    userAgent: self.agent,
                    cookies: CookieJar(cookies: cookies),
                    title: self.web.title
                )
            }
        }
    }

    @MainActor
    private func acceptPlan(_ body: [String: Any]) {
        guard let plan = HLSPlan(message: body) else {
            message = "Plan de flux illisible"
            CrashLog.step("plan HLS rejete")
            return
        }
        CrashLog.step("plan HLS accepte : \(plan.segments.count) segments, "
                      + (plan.encrypted ? "chiffre" : "en clair"))

        web.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            Task { @MainActor in
                guard let self = self else { return }
                _ = DownloadEngine.shared.launch(
                    plan: plan,
                    referer: self.currentPage,
                    userAgent: self.agent,
                    cookies: CookieJar(cookies: cookies),
                    title: self.web.title
                )
                self.message = "Ajouté aux fichiers · \(plan.segments.count) segments"
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

// MARK: - Pont avec la page

/// Relais entre le `WKUserContentController` et `BrowserModel`.
///
/// L'enregistrement se fait sur la configuration, qui vit au moins aussi
/// longtemps que le modele. Passer le modele lui-meme creerait un cycle que
/// rien ne pourrait rompre : d'ou la reference faible.
private final class ScriptBridge: NSObject, WKScriptMessageHandler {

    weak var owner: BrowserModel?

    /// `nonisolated` explicite : `BrowserModel` est `@MainActor`, son temoin
    /// l'est aussi, et c'est ce marqueur qui rend l'appel legal d'ici.
    nonisolated func userContentController(_ controller: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        owner?.userContentController(controller, didReceive: message)
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

        case "hooked":
            CrashLog.step("flux MSE detecte : \((body["manifest"] as? String ?? "").prefix(60))")

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

        // Plan d'un flux chiffre construit dans la page : c'est le chemin
        // nominal, le seul ou la cle est lisible.
        case "hls-plan":
            Task { @MainActor in acceptPlan(body) }

        // La page n'a pas su lire le manifeste. Le repli natif tente la meme
        // chose hors du contexte de la page : CORS passe, il ne reste que le
        // refus du CDN, auquel cas le message doit rester clair.
        case "hls-error":
            let url = (body["url"] as? String) ?? ""
            let height = (body["height"] as? Int) ?? 0
            let text = (body["message"] as? String) ?? "Manifeste illisible"
            CrashLog.step("plan HLS refuse par la page : \(text)")
            Task { @MainActor in
                if url.isEmpty {
                    // `message` sans `self` designe ici le parametre
                    // `WKScriptMessage` de la fonction enclosing, pas la
                    // propriete du modele : le compilateur refuse l'ecriture.
                    self.message = text
                } else {
                    self.enqueueNativePlan(url: url, height: height)
                }
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
        seen = (body["seen"] as? Int) ?? 0
        resolved = (body["resolved"] as? Int) ?? 0
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
            message = seen == 0
                ? "Aucune balise vidéo sur cette page"
                : "\(seen) lecteur\(seen > 1 ? "s" : "") trouvé\(seen > 1 ? "s" : "") mais aucune URL lisible (MSE ?)"
        }
    }
}