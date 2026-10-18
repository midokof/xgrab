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
///  * un correctif de `fetch` / `XMLHttpRequest` qui refuse les régies.
enum AdBlocker {

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
    static func installNative(into controller: WKUserContentController) {
        guard let url = Bundle.main.url(forResource: "blockerList", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = String(data: data, encoding: .utf8) else {
            CrashLog.step("AdBlocker: blockerList.json introuvable")
            return
        }

        let identifier = "app.xgrab.blocker"
        let store = WKContentRuleListStore.default()

        // Un identifiant déjà occupé par un contenu différent fait échouer le
        // stockage : on efface d'abord.
        store.removeContentRuleList(forIdentifier: identifier) { _ in
            store.compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: json
            ) { list, error in
                guard let list = list else {
                    CrashLog.step("AdBlocker: natif indisponible, JS actif \(error?.localizedDescription ?? "")")
                    return
                }
                DispatchQueue.main.async {
                    controller.add(list)
                    CrashLog.step("AdBlocker: liste native installee")
                }
            }
        }
    }

    // MARK: - Couche JavaScript

    private static let hostsLiteral = hosts
        .map { $0.replacingOccurrences(of: ".", with: "\\.") }
        .joined(separator: "|")

    private static let selectorsLiteral = selectors.joined(separator: ",")

    /// Script principal : bloque les régies, les scripts publicitaires et les
    /// popups. Injecté à chaque document, avant son analyse.
    static func blocker() -> WKUserScript {
        let source = """
        (function () {
          var HOSTS = new RegExp('(^|\\\\.)($hostsLiteral)(:|$)|($hostsLiteral)', 'i');
          var CSS = '$selectorsLiteral';

          // 1. Feuille de style : masque les encarts sans passer par le
          //    bloqueur natif, qui n'est pas toujours disponible.
          var stylePending = false;
          function injectStyle() {
            if (document.getElementById('xgrab-block')) return true;
            var root = document.head || document.documentElement;
            if (!root) {
              // Tres tot dans le document, aucun noeud racine : on retente
              // au prochain tick plutot que d'abandonner le script.
              if (!stylePending) {
                stylePending = true;
                setTimeout(function () { stylePending = false; injectStyle(); }, 50);
              }
              return false;
            }
            var style = document.createElement('style');
            style.id = 'xgrab-block';
            style.textContent = CSS + '{display:none !important;}';
            root.appendChild(style);
            return true;
          }

          // 2. Scripts publicitaires retirés dès leur insertion : retirer un
          //    <script> déjà dans le DOM annule son chargement.
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
              setTimeout(watch, 50);
              return;
            }
            new MutationObserver(function (records) {
              for (var i = 0; i < records.length; i++) {
                audit(records[i].addedNodes);
              }
            }).observe(root, { childList: true, subtree: true });
          }

          // 3. Requêtes réseau vers les régies : refusées avant l'envoi.
          function guard(method, url) {
            try { return HOSTS.test(String(url)); } catch (e) { return false; }
          }

          var realFetch = window.fetch;
          if (realFetch) {
            window.fetch = function (input, init) {
              var url = (input && input.url) ? input.url : input;
              if (guard('fetch', url)) {
                return Promise.reject(new Error('XGrab: regie bloquee'));
              }
              return realFetch.apply(this, arguments);
            };
          }

          var realOpen = XMLHttpRequest.prototype.open;
          if (realOpen) {
            XMLHttpRequest.prototype.open = function (method, url) {
              if (guard(method, url)) {
                try { this.abort(); } catch (e) {}
                return;
              }
              return realOpen.apply(this, arguments);
            };
          }

          // 4. Popups et popunders.
          try {
            Object.defineProperty(window, 'open', {
              configurable: false, writable: false,
              value: function () { return null; }
            });
          } catch (e) { window.open = function () { return null; }; }
          try { window.name = ''; } catch (e) {}

          var OVERLAYS = '[class*="popunder"],[id*="popunder"],' +
                         '[class*="onload-modal"],[class*="exit-intent"],' +
                         '[id*="exit-intent"],[id*="popup-overlay"],' +
                         '[id*="modal-overlay"],[id*="interstitial"]';
          setInterval(function () {
            if (!document.querySelectorAll) return;
            var nodes = document.querySelectorAll(OVERLAYS);
            for (var i = 0; i < nodes.length; i++) nodes[i].remove();
          }, 2000);

          watch();
          document.addEventListener('DOMContentLoaded', function () {
            injectStyle();
            watch();
          }, false);
        })();
        """

        return WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }
}