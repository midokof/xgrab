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
    static func popupGuard() -> WKUserScript {
        let source = """
        (function () {
          const deny = function () { return null; };
          try { Object.defineProperty(window, 'open', {
            configurable: false, writable: false, value: deny });
          } catch (e) { window.open = deny; }

          // Certains popunders passent par un iframe nomme.
          try { window.name = ''; } catch (e) {}
          try {
            window.addEventListener('beforeunload', function (e) {
              const to = document.referrer || '';
              if (to && to !== location.href) { /* navigation inter-site refusee */ }
            }, true);
          } catch (e) {}

          // Signale a l'app tout ce qui ressemble a une superposition publicitaire.
          function scan() {
            const nodes = document.querySelectorAll(
              '[class*="popunder"],[id*="popunder"],[class*="onload-modal"],' +
              '[id*="exit-intent"],[class*="exit-intent"]');
            nodes.forEach(function (n) { n.remove(); });
          }
          scan();
          new MutationObserver(scan).observe(
            document.documentElement, { childList: true, subtree: true });
        })();
        """
        return WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }
}