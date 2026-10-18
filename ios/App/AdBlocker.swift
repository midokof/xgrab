import WebKit

/// Blocage des publicités et des popups.
///
/// Le bloqueur natif `WKContentRuleList` n'est qu'un accélérateur : sur une
/// app non signée, `WKContentRuleListStore` échoue régulièrement
/// (`WKErrorDomain error 6`, *storeFailed*). Comme la page resterait alors
/// entièrement dégagée, la couche qui porte réellement le blocage est en
/// JavaScript : elle est injectée à chaque navigation et ne dépend d'aucun
/// stockage.
///
/// Trois couches indépendantes :
///  * une feuille de style qui masque les conteneurs d'encarts ;
///  * un observateur qui retire les `<script>` publicitaires à l'insertion ;
///  * un nettoyage périodique des superpositions de type popunder.
enum AdBlocker {

    /// Interrupteur utilisateur. Un bloqueur peut casser un site : il faut
    /// pouvoir le couper sur place.
    static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "blocker.on") == nil { return true }
            return UserDefaults.standard.bool(forKey: "blocker.on")
        }
        set { UserDefaults.standard.set(newValue, forKey: "blocker.on") }
    }

    // MARK: - Hôtes publicitaires

    private static let hosts = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com",
        "google-analytics.com", "googletagmanager.com", "adservice.google",
        "adnxs.com", "rubiconproject.com", "pubmatic.com", "openx.net",
        "criteo.com", "criteo.net", "taboola.com", "outbrain.com",
        "adroll.com", "sharethrough.com", "indexww.com", "casalemedia.com",
        "33across.com", "smartadserver.com", "teads.tv", "imasdk.googleapis.com",
        "adsystem.com", "amazon-adsystem.com", "yieldmo.com", "zedo.com",
        "popads.net", "propellerads.com", "mgid.com", "adcash.com",
        "exoclick.com", "juicyads.com", "hilltopads.net", "adsterra.com",
        "onclickalgo.com", "poperblock.com", "adskeeper.com", "revcontent.com",
        "adiquity.com", "bidswitch.net", "contextweb.com", "gumgum.com",
        "adform.net", "districtm.io", "mediance.com", "media.net",
        "sonobi.com", "spotxchange.com", "undertone.com",
    ]

    /// Sélecteurs des conteneurs d'encarts. Volontairement stricts : aucun
    /// sélecteur générique (`div`, `.container`) ne doit masquer un lecteur.
    private static let selectors = [
        "iframe[id^=\"aswift_\"]",
        "iframe[src*=\"doubleclick\"]",
        "iframe[src*=\"googlesyndication\"]",
        "[id^=\"div-gpt-ad\"]",
        "[id^=\"ad-slot\"]",
        "[id^=\"ad_\"]",
        "[id^=\"ad-\"]",
        "[id^=\"banner\"]",
        "[id^=\"ads-\"]",
        "[id*=\"ad-container\"]",
        "[id*=\"ad-wrapper\"]",
        "[id*=\"adbanner\"]",
        "[id*=\"adbox\"]",
        "[id*=\"popunder\"]",
        "[id*=\"popup-overlay\"]",
        "[id*=\"modal-overlay\"]",
        "[id*=\"interstitial\"]",
        "[class^=\"ad-\"]",
        "[class^=\"ad_\"]",
        "[class^=\"ads-\"]",
        "[class^=\"advert\"]",
        "[class*=\"ad-container\"]",
        "[class*=\"ad-wrapper\"]",
        "[class*=\"ad-slot\"]",
        "[class*=\"ad-placement\"]",
        "[class*=\"adsbygoogle\"]",
        "[class*=\"banner-ad\"]",
        "[class*=\"popup-under\"]",
        "[class*=\"popunder\"]",
        "[class*=\"interstitial\"]",
        "[class*=\"sticky-footer\"]",
        "[class*=\"consent-overlay\"]",
        "[class*=\"onload-modal\"]",
        "[class*=\"exit-intent\"]",
    ]

    // MARK: - Bloqueur natif (optionnel)

    /// Tente d'installer la liste de règles native. En cas d'échec, la couche
    /// JavaScript prend le relais : le blocage n'est jamais absent.
    static func installNative(into controller: WKUserContentController,
                               then: @escaping (String) -> Void) {
        guard let url = Bundle.main.url(forResource: "blockerList", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = String(data: data, encoding: .utf8) else {
            CrashLog.step("AdBlocker: blockerList.json introuvable")
            return
        }

        let identifier = "app.xgrab.blocker"

        // `default()` est optionnel : sur une app non signee, il peut etre
        // nil. Dans ce cas la couche JavaScript assure le blocage seule.
        guard let store = WKContentRuleListStore.default() else {
            CrashLog.step("AdBlocker: store indisponible, JS actif")
            DispatchQueue.main.async { then("JS") }
            return
        }

        // Un identifiant déjà occupé par un contenu différent fait échouer le
        // stockage : on efface d'abord.
        store.removeContentRuleList(forIdentifier: identifier) { _ in
            store.compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: json
            ) { list, error in
                guard let list = list else {
                    let ns = error as NSError?
                    CrashLog.step("AdBlocker: natif KO domaine=\(ns?.domain ?? "?") code=\(ns?.code ?? -1)")
                    DispatchQueue.main.async { then("JS") }
                    return
                }
                DispatchQueue.main.async {
                    controller.add(list)
                    CrashLog.step("AdBlocker: liste native installee")
                    then("natif")
                }
            }
        }
    }

    // MARK: - Couche JavaScript

    private static let hostsLiteral = hosts
        .map { $0.replacingOccurrences(of: ".", with: "\\.") }
        .joined(separator: "|")

    private static let selectorsLiteral = selectors.joined(separator: ",")

    /// Script de blocage, volontairement minimal.
    ///
    /// Aucun correctif de `fetch`, de `XMLHttpRequest` ni de `window.open` :
    /// ces trois noms sont verifies par les scripts anti-publicite. Des qu'ils
    /// detectent la modification, ils couvrent la page et interdisent le
    /// defilement — le bloqueur devient alors pire que les pubs.
    ///
    /// Ce qui reste est invisible a une detection : une feuille de style, le
    /// retrait de noeuds publicitaires a leur insertion, et le nettoyage des
    /// superpositions. Les popups, eux, sont bloques nativement par
    /// `WKUIDelegate.createWebViewWith`, sans trace visible par la page.
    static func blocker() -> WKUserScript {
        let source = """
        (function () {
          var HOSTS = new RegExp('(^|\\\\.)($hostsLiteral)(:|$)|($hostsLiteral)', 'i');
          var CSS = '$selectorsLiteral';

          function injectStyle() {
            if (document.getElementById('xgrab-block')) return;
            var root = document.head || document.documentElement;
            if (!root) return;
            var style = document.createElement('style');
            style.id = 'xgrab-block';
            style.textContent = CSS + '{display:none !important;}';
            root.appendChild(style);
          }

          // Retirer un <script> deja insere annule son chargement.
          function audit(nodes) {
            for (var i = 0; i < nodes.length; i++) {
              var node = nodes[i];
              if (!node || node.nodeType !== 1) continue;
              var tag = node.tagName;
              if (tag !== 'SCRIPT' && tag !== 'IFRAME') continue;
              var src = node.src || node.getAttribute('src') || '';
              if (src && HOSTS.test(src)) node.remove();
            }
          }

          function watch() {
            injectStyle();
            var root = document.documentElement;
            if (!root) {
              setTimeout(watch, 40);
              return;
            }
            new MutationObserver(function (records) {
              for (var i = 0; i < records.length; i++) audit(records[i].addedNodes);
            }).observe(root, { childList: true, subtree: true });
          }

          var OVERLAYS = '[class*="popunder"],[id*="popunder"],' +
                         '[class*="onload-modal"],[id*="popup-overlay"],' +
                         '[id*="modal-overlay"]';
          setInterval(function () {
            try {
              var nodes = document.querySelectorAll(OVERLAYS);
              for (var i = 0; i < nodes.length; i++) nodes[i].remove();
            } catch (e) {}
          }, 2000);

          watch();
          document.addEventListener('DOMContentLoaded', injectStyle, false);
        })();
        """

        return WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }
}