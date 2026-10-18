import SwiftUI
import WebKit

/// Navigateur integre, bloqueur de publicites et de popups.
///
/// L'app rend la page elle-meme, injecte du JavaScript pour trouver l'URL
/// brute du media, puis telecharge le fichier de maniere native. Aucune
/// extension Safari n'est requise.
struct BrowserView: View {
    @StateObject private var model = BrowserModel()

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                addressBar
                Divider()
                WebViewRepresentable(model: model)
            }

            downloadButton
                .padding(.bottom, 12)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    // ------------------------------------------------------------ barre d'adresse

    private var addressBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    model.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                }
                .disabled(!model.canGoBack)

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)

                    TextField("Collez un lien ici", text: $model.address)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .onSubmit { model.load(model.address) }
                        .font(.system(size: 15))

                    if model.loading {
                        ProgressView().controlSize(.small)
                    } else if !model.address.isEmpty {
                        Button {
                            model.load("")
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.accent.opacity(model.hasVideo ? 0.5 : 0), lineWidth: 2)
                )

                Button {
                    model.load(model.address)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Theme.accent.opacity(0.15)))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 8)

            HStack(spacing: 6) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 10, weight: .bold))
                Text("Pubs, popups et scripts publicitaires bloqués")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                StatusPill(title: "PROTÉGÉ", colour: Theme.success)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.gutter + 4)

            if let hint = model.hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.gutter + 4)
                    .padding(.bottom, 2)
            }

            chooser
        }
        .background(.bar)
    }

    /// Plusieurs lecteurs sur la page : l'utilisateur choisit lequel garder.
    @ViewBuilder
    private var chooser: some View {
        let usable = model.candidates.filter { !$0.isAd && $0.url != model.chosenURL }
        if !usable.isEmpty {
            HStack(spacing: 6) {
                Text("\(model.candidates.filter { !$0.isAd }.count) vidéos")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(usable) { item in
                        Button {
                            model.pickedURL = item.url
                        } label: {
                            Label(item.label, systemImage: "film")
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Choisir").font(.system(size: 10, weight: .bold))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Theme.accent.opacity(0.16)))
                    .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, Theme.gutter + 4)
            .padding(.bottom, 4)
        }
    }

    // ------------------------------------------------------------ bouton media

    @ViewBuilder
    private var downloadButton: some View {
        if model.hasVideo {
            Button {
                guard model.chosenURL != nil else {
                    model.hint = "Démarre la lecture : le flux n'est pas encore chargé."
                    return
                }
                CrashLog.step("bouton: appuye sur telecharger")
                model.download()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: model.chosenURL == nil
                          ? "hourglass.circle.fill" : "arrow.down.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                    Text(model.chosenURL == nil ? "Lecture requise" : "Télécharger la vidéo")
                        .font(.system(size: 15, weight: .bold))
                    if model.segmented && model.chosenURL != nil {
                        Text("· flux")
                            .font(.system(size: 12, weight: .medium))
                            .opacity(0.8)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 15)
                .background(Capsule().fill(Theme.accentGradient))
                .foregroundStyle(.white)
                .shadow(color: Theme.accent.opacity(0.45), radius: 18, x: 0, y: 8)
            }
            .buttonStyle(.plain)
            .transition(.scale.combined(with: .opacity))
        }
    }
}

// MARK: - Vue WKWebView

private struct WebViewRepresentable: UIViewRepresentable {
    @ObservedObject var model: BrowserModel

    func makeUIView(context: Context) -> WKWebView {
        CrashLog.step("makeUIView: creation du WKWebView")

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .default()
        config.userContentController.add(context.coordinator, name: "xgrab")
        // Le blocage JavaScript ne depend d'aucun stockage : il est toujours
        // present, contrairement au bloqueur natif.
        config.userContentController.addUserScript(AdBlocker.blocker())
        // La sonde est enregistree comme script de document : elle attend
        // ainsi le <video> depuis sa creation, au lieu d'apparaitre apres
        // didFinish, qui peut ne jamais survenir sur une page video.
        config.userContentController.addUserScript(
            WKUserScript(source: BrowserModel.probe,
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: false)
        )
        AdBlocker.installNative(into: config.userContentController)

        // Un cadre non nul evite l'ecran blanc sur les WKWebView crees hors
        // d'une hierarchie de vues deja cassee.
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 800), configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        context.coordinator.web = web

        // L'attente du compileur natif ne doit plus retarder le premier
        // chargement : la couche JavaScript, elle, est deja en place.
        DispatchQueue.main.async {
            model.attach(web)
        }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.model = model
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var model: BrowserModel
        weak var web: WKWebView?

        init(model: BrowserModel) { self.model = model }

        // MARK: messages

        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "xgrab" else { return }
            let body = message.body as? [String: Any] ?? [:]
            model.absorb(body)
        }

        // MARK: navigation

        func webView(_ web: WKWebView, didStartProvisionalNavigation nav: WKNavigation!) {
            CrashLog.step("nav: depart \(model.address.prefix(60))")
            model.loading = true
        }

        func webView(_ web: WKWebView, didCommit navigation: WKNavigation!) {
            CrashLog.step("nav: commit")
        }

        func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) {
            CrashLog.step("nav: fini")
            model.loading = false
            model.canGoBack = web.canGoBack
            model.inject()
        }

        func webView(_ web: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            model.loading = false
            model.report(error)
        }

        func webView(_ web: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            model.loading = false
            model.report(error)
        }

        /// iOS tue le processus de contenu quand la memoire manque ou que
        /// l'app revient de l'arriere-plan : sans rechargement, la vue reste
        /// blanche definitivement.
        func webViewWebContentProcessDidTerminate(_ web: WKWebView) {
            CrashLog.step("webcontent: processus termine, rechargement")
            model.loading = true
            web.reload()
        }

        // MARK: popups

        /// Renvoie nil : aucune fenêtre secondaire ne peut s'ouvrir. Les liens
        /// `target="_blank"` sont charges dans la vue principale.
        func webView(_ web: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            CrashLog.step("popup: bloque")
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                var request = navigationAction.request
                if request.httpBody == nil {
                    // Une requete POST ne peut pas etre rejouee telle quelle.
                    if request.httpMethod == "POST" { return nil }
                }
                request.url = url
                web.load(request)
            }
            return nil
        }

        func webView(_ web: WKWebView,
                     runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping () -> Void) {
            model.hint = message
            completionHandler()
        }

        func webView(_ web: WKWebView,
                     runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (Bool) -> Void) {
            model.hint = message
            completionHandler(true)
        }

        func webView(_ web: WKWebView,
                     runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (String?) -> Void) {
            model.hint = prompt
            completionHandler(nil)
        }
    }
}

// MARK: - Modele

final class BrowserModel: ObservableObject {
    @Published var address: String = "" {
        didSet { if address != shown { load(address) } }
    }
    @Published var loading = false
    @Published var canGoBack = false
    @Published var hint: String?

    /// Flux detecte sur la page. Une page de recherche porte presque toujours
/// des lecteurs publicitaires : le choix automatique privilegie le contenu.
struct Candidate: Identifiable {
    let url: String
    let width: Int
    let height: Int
    let isAd: Bool
    var id: String { url }

    var label: String {
        let name = (url as NSString).lastPathComponent
        let short = name.isEmpty ? (url as NSString).lastPathComponent : name
        let size = (width > 0 && height > 0) ? " · \(width)×\(height)" : ""
        return String(short.prefix(46)) + size
    }
}

/// URL de media trouvee sur la page courante.
    @Published private(set) var mediaURL: String?
    @Published private(set) var segmented = false
    /// Un element <video> est present, meme si son flux n'est pas encore connu.
    @Published private(set) var hasVideo = false
    /// Tous les flux detectes, pour que l'utilisateur puisse trancher.
    @Published private(set) var candidates: [Candidate] = []
    @Published var pickedURL: String?

    private weak var web: WKWebView?
    private var shown = ""
    private var adCount = 0

    private static let startPage = "https://duckduckgo.com"

    /// Affiche le numero de build dans l'onglet Fichiers : sans cela, on
    /// ne sait jamais quelle version est reellement installee.
    static var buildLabel: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let marketing = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "v\(marketing) (\(build))"
    }

    // ------------------------------------------------------------- navigation

    func attach(_ web: WKWebView) {
        self.web = web
        address = Self.startPage
        shown = Self.startPage
    }

    func load(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let url = Self.normalise(text) else { return }
        shown = url.absoluteString
        address = shown
        mediaURL = nil
        hasVideo = false
        candidates = []
        pickedURL = nil
        adCount = 0
        hint = nil
        web?.load(URLRequest(url: url))
    }

    func goBack() {
        web?.goBack()
    }

    private static func normalise(_ text: String) -> URL? {
        if let url = URL(string: text), url.scheme != nil { return url }
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let candidate = "https://duckduckgo.com/?q=" + encoded
        return URL(string: candidate)
    }

    // ------------------------------------------------------------------- media

    /// Relit ce que le JavaScript a observe sur la page.
    func absorb(_ body: [String: Any]) {
        switch body["event"] as? String {
        case "url":
            let value = body["url"] as? String ?? ""
            if value != shown { shown = value; address = value }
        case "media":
            let found = body["media"] as? String
            let video = (body["hasVideo"] as? Bool) ?? false
            let raw = body["list"] as? [[String: Any]] ?? []

            let list = raw.compactMap { item -> Candidate? in
                guard let url = item["url"] as? String, !url.isEmpty else { return nil }
                return Candidate(
                    url: url,
                    width: (item["w"] as? Int) ?? 0,
                    height: (item["h"] as? Int) ?? 0,
                    isAd: (item["ad"] as? Bool) ?? false
                )
            }

            // Un seul log par decouverte, sinon le journal noie tout.
            if video && !hasVideo {
                CrashLog.step("media: <video> detecte (\(list.count) flux)")
            }
            if found != nil && found != mediaURL {
                CrashLog.step("media: flux \(found!.prefix(70))")
            }
            let pubCount = list.filter(\.isAd).count
            if pubCount > 0 && adCount != pubCount {
                adCount = pubCount
                CrashLog.step("media: \(pubCount) lecteur(s) publicitaire(s) ecarte(s)")
            }

            candidates = list
            mediaURL = found
            segmented = (body["segmented"] as? Bool) ?? false
            hasVideo = video
            // Un choix manuel reste valable tant que son flux est encore là.
            if let picked = pickedURL, list.contains(where: { $0.url == picked }) {
                mediaURL = picked
            } else {
                pickedURL = nil
            }
            updateHint()
        default:
            break
        }
    }

    private func updateHint() {
        guard hasVideo else {
            hint = "Aucune vidéo détectée sur cette page."
            return
        }
        guard let media = mediaURL else {
            hint = "Vidéo trouvée. Lance la lecture pour que le flux soit transmis."
            return
        }
        let ads = candidates.filter(\.isAd).count
        let extra = ads > 0 ? " · \(ads) pub\(ads > 1 ? "s" : "") ignorée\(ads > 1 ? "s" : "")" : ""
        hint = segmented
            ? "Flux segmenté (.m3u8 / .mpd) : XGrab ne peut pas l'assembler."
            : "Vidéo détectée : \((media as NSString).lastPathComponent.prefix(46))\(extra)"
    }

    /// Flux que l'utilisateur a choisi manuellement, sinon le meilleur.
    var chosenURL: String? { pickedURL ?? mediaURL }

    /// Une navigation annulee (-999) est normale : elle est remplacee par la
    /// suivante. Seul le dernier echec reel est affiche.
    func report(_ error: Error) {
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }
        hint = "Chargement impossible : \(nsError.localizedDescription)"
    }

    // ---------------------------------------------------------------- download

    /// Lance le telechargement natif de ce que la page expose.
    ///
    /// On reprend le User-Agent et les cookies du WKWebView : sans eux, les
    /// CDN renvoient 403 sur un fichier qu'ils servent pourtant au navigateur.
    func download() {
        CrashLog.step("download: debut, media=\(chosenURL ?? "nil")")
        guard let media = chosenURL, let web = web else {
            CrashLog.step("download: media ou web manquant")
            return
        }
        let referer = shown

        web.evaluateJavaScript("navigator.userAgent") { [weak self] value, _ in
            let agent = (value as? String) ?? ""
            CrashLog.step("download: UA obtenu (\(agent.count) caracteres)")

            web.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                CrashLog.step("download: \(cookies.count) cookie(s) recus")
                let jar = self?.cookieHeader(cookies, for: media) ?? ""

                DispatchQueue.main.async {
                    guard let self = self else { return }
                    CrashLog.step("download: enqueue, jar=\(jar.count) caracteres")
                    guard Downloader.shared.enqueue(
                        url: media,
                        referer: referer,
                        userAgent: agent,
                        cookies: jar
                    ) != nil else {
                        CrashLog.step("download: enqueue a echoue")
                        self.hint = "Lien non téléchargeable"
                        return
                    }
                    CrashLog.step("download: enqueue ok")
                    self.hint = "Téléchargement lancé, vois l'onglet Fichiers"
                }
            }
        }
    }

    /// Ne renvoie que les cookies qui concernent le domaine du media.
    private func cookieHeader(_ cookies: [HTTPCookie], for url: String) -> String {
        CrashLog.step("cookieHeader: \(cookies.count) cookie(s)")
        guard let host = URL(string: url)?.host?.lowercased() else {
            CrashLog.step("cookieHeader: hote introuvable")
            return ""
        }
        return cookies
            .filter { cookie in
                let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return host == domain || host.hasSuffix("." + domain)
            }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    /// Relit l'URL du document. La sonde elle-meme est deja enregistree
    /// comme script de document ; cet appel ne sert qu'a resynchroniser
    /// apres une navigation interne.
    func inject() {
        web?.evaluateJavaScript("window.__xgrabProbe && window.__xgrabProbe();",
                               completionHandler: nil)
    }

    /// Ajoute le script de detection. Identique en esprit a content.js, mais
    /// declenche par l'app au lieu d'etre enregistre par le navigateur.
    /// Sonde de detection, enregistree comme script de document.
    static let probe = """
    (function () {
      if (window.__xgrabProbe) { window.__xgrabProbe(); return; }

      const MEDIA = /\\.(m3u8|mp4|m4v|webm|mov|mkv)(\\?|#|$)/i;
      const SEG = /(videoplayback|\\.mpd|\\.m3u8|migration\\/)/i;
      const recent = [];

      function note(url) {
        if (!url || !MEDIA.test(url)) return;
        const clean = url.split('#')[0];
        const at = recent.findIndex((i) => i.url === clean);
        if (at !== -1) recent.splice(at, 1);
        recent.unshift({ url: clean, at: Date.now() });
        if (recent.length > 12) recent.pop();
      }

      try {
        new PerformanceObserver((list) => {
          for (const e of list.getEntries()) note(e.name);
        }).observe({ type: 'resource', buffered: true });
      } catch (err) {}

      function sourceOf(video) {
        const direct = video.currentSrc || video.src || '';
        if (usable(direct)) return direct.split('#')[0];
        for (const node of video.querySelectorAll('source[src]')) {
          const url = node.getAttribute('src') || '';
          if (usable(url)) return url.split('#')[0];
        }
        // Lecteur MSE : currentSrc vaut "blob:", on reprend alors la derniere
        // URL reelle observee dans les requetes du document.
        const fresh = recent.find((i) => Date.now() - i.at < 45000);
        return fresh ? fresh.url : '';
      }

      // Un blob: n'est pas telechargeable par l'app.
      function usable(u) {
        return !!u && /^https?:\\/\\//i.test(u) && !/^blob:/i.test(u);
      }

      // Marqueurs de publicite dans le chemin de l'URL.
      const AD_PATH = /(^|[\\/_.-])(ad|ads|adserver|adframe|advert|advertising|banner|banners|preroll|midroll|rollover|rollunder|spot|promo|promos|teaser|roomad|sponsor|sponsored|partner|thumb|thumbs)([\\/_.-]|$)/i;

      // Marqueurs dans les attributs des conteneurs.
      const AD_MARK = /(ad-|ads-|ad_|ads_|adbox|adslot|adunit|adframe|advert|banner|preroll|midroll|sponsor|sponsored|partner|commercial|promo)/;

      function adContext(el) {
        let node = el, depth = 0;
        while (node && depth < 6 && node !== document.body) {
          const cls = node.className;
          const sig = ((cls && cls.baseVal !== undefined) ? cls.baseVal : (cls || '')) +
                      ' ' + (node.id || '');
          if (AD_MARK.test(String(sig).toLowerCase())) return true;
          node = node.parentElement;
          depth++;
        }
        return false;
      }

      function describe(video) {
        const url = sourceOf(video);
        const r = video.getBoundingClientRect();
        const area = Math.max(0, r.width) * Math.max(0, r.height);
        let ad = false;
        if (url && AD_PATH.test(url)) ad = true;
        if (adContext(video)) ad = true;
        if (video.loop) ad = true;
        const d = video.duration;
        if (isFinite(d) && d > 0 && d < 30) ad = true;

        let score = area;
        if (ad) score *= 0.05;
        if (video.muted && video.autoplay) score *= 0.5;
        return {
          url: url || '',
          w: Math.round(r.width),
          h: Math.round(r.height),
          ad: ad,
          score: Math.round(score),
        };
      }

      function report() {
        const videos = Array.from(document.querySelectorAll('video'));
        const list = videos.map(describe).filter((d) => d.url);
        list.sort((a, b) => b.score - a.score);

        // On prefere toujours un candidat qui n'est pas une publicite.
        const clean = list.filter((d) => !d.ad);
        const pool = clean.length ? clean : list;
        const best = pool[0] || null;

        window.webkit.messageHandlers.xgrab.postMessage({
          event: 'media',
          media: best ? best.url : null,
          segmented: !!best && SEG.test(best.url),
          hasVideo: videos.length > 0,
          list: list.slice(0, 8),
        });
      }

      window.__xgrabProbe = function () {
        window.webkit.messageHandlers.xgrab.postMessage({ event: 'url', url: location.href });
        report();
      };

      new MutationObserver(function () {
        clearTimeout(window.__xgrabTimer);
        window.__xgrabTimer = setTimeout(report, 400);
      }).observe(document.documentElement, { childList: true, subtree: true });

      // Un flux peut etre injecte par attribut sans changer le DOM : on
      // surveille aussi les attributs src des <video> et <source>.
      new MutationObserver(function (records) {
        for (const r of records) {
          if (r.type === 'attributes') report();
        }
      }).observe(document.documentElement, {
        attributes: true,
        attributeFilter: ['src', 'currentSrc'],
        subtree: true,
      });

      // Le flux n'apparait souvent qu'apres le lancement de la lecture.
      for (const type of ['play', 'playing', 'loadedmetadata', 'canplay',
                          'durationchange', 'progress']) {
        document.addEventListener(type, function () { report(); }, true);
      }
      document.addEventListener('sourcechange', function () { report(); }, true);

      window.__xgrabTimer = setInterval(report, 1500);
      report();
    })();
    """
}