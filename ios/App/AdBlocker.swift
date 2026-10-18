import WebKit

/// Blocage des publicités et des popups.
///
/// Deux mécanismes complémentaires :
///  * une liste de règles WebKit (`blockerList.json`) qui intercepte les
///    requêtes vers les régies publicitaires et masque les conteneurs d'encarts ;
///  * un script qui neutralise `window.open`, utilisé par les popunders.
enum AdBlocker {

    private static let identifier = "app.xgrab.blocker"

    private static var cached: WKContentRuleList?
    private static var waiting: [(WKContentRuleList?) -> Void] = []
    private static var started = false

    /// Compile la liste une seule fois puis la reutilise.
    static func ruleList(_ completion: @escaping (WKContentRuleList?) -> Void) {
        if let cached {
            completion(cached)
            return
        }
        waiting.append(completion)
        guard !started else { return }
        started = true

        guard let url = Bundle.main.url(forResource: "blockerList", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = String(data: data, encoding: .utf8) else {
            CrashLog.step("AdBlocker: blockerList.json introuvable")
            flush(nil)
            return
        }

        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: identifier,
            encodedContentRuleList: json
        ) { list, error in
            if let error {
                CrashLog.step("AdBlocker: compilation echouee \(error.localizedDescription)")
            } else if let list {
                CrashLog.step("AdBlocker: liste compilee")
                cached = list
            }
            flush(list)
        }
    }

    private static func flush(_ list: WKContentRuleList?) {
        let handlers = waiting
        waiting = []
        for handler in handlers { handler(list) }
    }

    /// Empêche les pages d'ouvrir une fenêtre secondaire.
    ///
    /// Le nettoyage des popunders est volontairement limité : un
    /// `MutationObserver` qui interroge tout le document a chaque mutation
    /// sature le thread principal des pages vidéo et gèle la détection.
    static func popupGuard() -> WKUserScript {
        let source = """
        (function () {
          try {
            Object.defineProperty(window, 'open', {
              configurable: false, writable: false, value: function () { return null; }
            });
          } catch (e) { window.open = function () { return null; }; }

          try { window.name = ''; } catch (e) {}

          var SELECTOR = '[class*="popunder"],[id*="popunder"],[class*="exit-intent"],' +
                         '[id*="exit-intent"],[class*="onload-modal"]';
          var armed = true;

          function sweep() {
            if (!armed) return;
            var nodes = document.querySelectorAll(SELECTOR);
            for (var i = 0; i < nodes.length; i++) nodes[i].remove();
          }

          // Balayage espace : au plus une fois toutes les 1500 ms, et
          // uniquement si la page a encore des popunders a retirer.
          setInterval(function () {
            if (!armed) return;
            if (document.querySelector(SELECTOR)) sweep();
          }, 1500);

          window.addEventListener('load', function () {
            setTimeout(function () { armed = false; }, 30000);
          });
        })();
        """
        return WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }

    /// Nettoyage JavaScript de secours, utilisé seulement si la liste de
    /// regles n'a pas compile. Plus modeste que le bloqueur natif : il
    /// n'agit que sur les overlays-HTML, pas sur les requetes reseau.
    static func fallbackCleaner() -> WKUserScript {
        let source = """
        (function () {
          var SELECTOR = 'iframe[src*="doubleclick"],iframe[src*="googlesyndication"],' +
                         '[id^="div-gpt-ad"],[class*="adsbygoogle"],[class*="popunder"]';
          setInterval(function () {
            var nodes = document.querySelectorAll(SELECTOR);
            for (var i = 0; i < nodes.length; i++) nodes[i].remove();
          }, 2000);
        })();
        """
        return WKUserScript(
            source: source,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
    }
}