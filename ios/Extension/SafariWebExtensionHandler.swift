import SafariServices
import os.log

/* Le pont entre le service worker de l'extension Safari et l'app conteneur.
 *
 * Le service worker demande ici l'adresse du PC et le jeton partages, saisis
 * dans l'interface SwiftUI et conserves dans le groupe d'apps partage.
 */

let log = OSLog(subsystem: "com.xgrab.app", category: "bridge")

final class Bridge {
    static let shared = Bridge()

    private let defaults = UserDefaults(suiteName: "group.app.xgrab")

    private init() {}

    var host: String { (defaults?.string(forKey: "host") ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    var port: Int { defaults?.integer(forKey: "port") ?? 38471 }
    var token: String { defaults?.string(forKey: "token") ?? "" }
    var listening: Bool { defaults?.bool(forKey: "listening") ?? true }
}

class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    func beginRequest(with context: NSExtensionContext) {
        let request = context.inputItems.first as? NSExtensionItem
        let message = request?.userInfo?[SFExtensionMessageKey] as? [String: Any] ?? [:]
        let type = message["type"] as? String ?? ""

        var response: [String: Any]

        switch type {
        case "xgrab-config":
            let bridge = Bridge.shared
            response = [
                "ok": true,
                "host": bridge.host,
                "port": bridge.port,
                "token": bridge.token,
            ]
            os_log("config demandee : %{public}@:%d", log: log, type: .debug, bridge.host, bridge.port)

        case "xgrab-add":
            // L'extension et l'app sont deux modules distincts : le handler
            // ne peut pas appeler le telechargeur. On ecrit la demande dans
            // le conteneur partage, l'app la draine a son activation.
            let urls = message["urls"] as? [String] ?? []
            let referer = message["referer"] as? String ?? ""
            let ok = PendingQueue.write(urls: urls, referer: referer)
            response = ["ok": ok, "added": urls.count, "started": true]
            os_log("%d lien(s) en attente (ecriture=%@)", log: log, type: .debug,
                   urls.count, ok ? "oui" : "non")

        case "xgrab-save":
            if let host = message["host"] as? String,
               let port = message["port"] as? Int,
               let token = message["token"] as? String {
                Bridge.shared.save(host: host, port: port, token: token)
                response = ["ok": true]
            } else {
                response = ["ok": false, "error": "champs manquants"]
            }

        default:
            response = ["ok": false, "error": "type inconnu : \(type)"]
        }

        let item = NSExtensionItem()
        item.userInfo = [SFExtensionMessageKey: response]
        context.completeRequest(returningItems: [item], completionHandler: nil)
    }
}

extension Bridge {
    func save(host: String, port: Int, token: String) {
        defaults?.set(host.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "host")
        defaults?.set(port, forKey: "port")
        defaults?.set(token, forKey: "token")
    }
}