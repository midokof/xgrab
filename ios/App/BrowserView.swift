import SwiftUI
import WebKit

/// Navigateur integre. C'est la meme technique qu'Aloha : l'app rend la page
/// elle-meme, injecte du JavaScript, recupere l'URL brute du media et la
/// telecharge. Aucune extension Safari n'est requise.
struct BrowserView: View {
    @StateObject private var model = BrowserModel()

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider()
            WebViewRepresentable(model: model)
        }
        .overlay(alignment: .bottomTrailing) {
            if model.mediaURL != nil {
                Button {
                    model.download()
                } label: {
                    Label("Télécharger", systemImage: "arrow.down.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Capsule().fill(Color.accentColor))
                        .foregroundStyle(.white)
                        .shadow(radius: 6)
                }
                .padding(20)
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    // ------------------------------------------------------------- barre du haut

    private var bar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    model.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!model.canGoBack)

                TextField("Adresse ou lien", text: $model.address)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .onSubmit { model.load(model.address) }

                if model.loading {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        model.load(model.address)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .font(.system(size: 15))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if let hint = model.hint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
            }
        }
        .background(.bar)
    }
}

// MARK: - Vue WKWebView

private struct WebViewRepresentable: UIViewRepresentable {
    @ObservedObject var model: BrowserModel

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(context.coordinator, name: "xgrab")

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        context.coordinator.web = web
        // attach() lance deja le premier chargement : un second load()
        // annulerait le premier et provoquerait une erreur -999.
        model.attach(web)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.model = model
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var model: BrowserModel
        weak var web: WKWebView?

        init(model: BrowserModel) { self.model = model }

        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "xgrab" else { return }
            let body = message.body as? [String: Any] ?? [:]
            model.absorb(body)
        }

        func webView(_ web: WKWebView, didStartProvisionalNavigation nav: WKNavigation!) {
            model.loading = true
        }

        func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) {
            model.loading = false
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

    /// URL de media trouvee sur la page courante.
    @Published private(set) var mediaURL: String?
    @Published private(set) var segmented = false

    private weak var web: WKWebView?
    private var shown = ""
    private var hasMedia = false

    private static let startPage = "https://duckduckgo.com"

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
        hasMedia = false
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
            mediaURL = body["media"] as? String
            segmented = (body["segmented"] as? Bool) ?? false
            hasMedia = mediaURL != nil
            updateHint()
        default:
            break
        }
    }

    private func updateHint() {
        guard let media = mediaURL else {
            hint = "Aucun media detecte sur cette page."
            return
        }
        hint = segmented
            ? "Flux segmenté : XGrab transmettra la page, pas le fichier."
            : "Media détecté : \((media as NSString).lastPathComponent.prefix(60))"
    }

    /// Une navigation annulee (-999) est normale : elle est remplacee par la
    /// suivante. Seul le dernier echec reel est affiche.
    func report(_ error: Error) {
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }
        hint = "Chargement impossible : \(nsError.localizedDescription)"
    }

    // ---------------------------------------------------------------- injection

    /// Lance le telechargement natif de ce que la page expose.
    ///
    /// On reprend le User-Agent et les cookies du WKWebView : sans eux, les
    /// CDN renvoient 403 sur un fichier qu'ils servent pourtant au navigateur.
    func download() {
        CrashLog.step("download: debut, media=\(mediaURL ?? "nil")")
        guard let media = mediaURL, let web = web else {
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
                        self.hint = "Lien non telechargeable"
                        return
                    }
                    CrashLog.step("download: enqueue ok")
                    self.hint = self.segmented
                        ? "Page transmise au PC si un serveur est configure"
                        : "Ajouté à l'onglet Fichiers"
                }
            }
        }
    }

    /// Ne renvoie que les cookies qui concernent le domaine du media.
    private func cookieHeader(_ cookies: [HTTPCookie], for url: String) -> String {
        guard let host = URL(string: url)?.host?.lowercased() else { return "" }
        return cookies
            .filter { cookie in
                let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return host == domain || host.hasSuffix("." + domain)
            }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    func inject() {
        web?.evaluateJavaScript(Self.probe, completionHandler: nil)
    }

    /// Ajoute le script de detection. Identique en esprit a content.js, mais
    /// declenche par l'app au lieu d'etre enregistre par le navigateur.
    private static let probe = """
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
        if (direct && /^https?:\\/\\//i.test(direct)) return direct;
        for (const node of video.querySelectorAll('source[src]')) {
          const url = node.getAttribute('src') || '';
          if (/^https?:\\/\\//i.test(url)) return url;
        }
        const fresh = recent.find((i) => Date.now() - i.at < 45000);
        return fresh ? fresh.url : '';
      }

      function best() {
        const videos = Array.from(document.querySelectorAll('video'));
        if (!videos.length) return null;
        const visible = videos.filter((v) => {
          const b = v.getBoundingClientRect();
          return b.width > 60 && b.height > 40;
        });
        const list = visible.length ? visible : videos;
        list.sort((a, b) => {
          const x = a.getBoundingClientRect(), y = b.getBoundingClientRect();
          return y.width * y.height - x.width * x.height;
        });
        return list[0];
      }

      function report() {
        const video = best();
        let media = video ? sourceOf(video) : '';
        const segmented = !!media && SEG.test(media);
        // On renvoie l'URL reelle du flux, pas l'adresse de la page : le
        // telechargeur natif sait traiter un m3u8, il ne sait pas analyser
        // du HTML.
        window.webkit.messageHandlers.xgrab.postMessage({
          event: 'media',
          media: media || null,
          segmented: segmented,
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

      document.addEventListener('play', function () { report(); }, true);
      window.__xgrabTimer = setInterval(report, 1500);
      report();
    })();
    """
}
