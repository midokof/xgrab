import Foundation

/// File d'attente partage entre l'extension Safari et l'app.
///
/// L'extension ecrit, l'app draine. Chaque bord a sa propre copie du module,
/// donc aucun type Swift n'est partage : uniquement du JSON sur disque.
enum PendingQueue {

    static let filename = "pending.json"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.app.xgrab")
    }

    static var fileURL: URL? {
        containerURL?.appendingPathComponent(filename)
    }

    struct Request: Codable {
        let urls: [String]
        let referer: String
    }

    // ------------------------------------------------------------ cote extension

    static func write(urls: [String], referer: String) -> Bool {
        guard let url = fileURL, !urls.isEmpty else { return false }
        var all = read()

        // Borne de securite : une extension hostile ne doit pas faire
        // grossir ce fichier indefiniment.
        if all.count > 50 {
            all.removeFirst(all.count - 50)
        }
        all.append(Request(urls: urls, referer: referer))

        guard let data = try? JSONEncoder().encode(all) else { return false }
        // Ecriture atomique : l'app ne doit jamais lire un fichier a moitie ecrit.
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    // ------------------------------------------------------------------ commun

    static func read() -> [Request] {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Request].self, from: data)) ?? []
    }

    /// Vide la file et retourne ce qu'il y avait.
    static func drain() -> [Request] {
        guard let url = fileURL else { return [] }
        let pending = read()
        guard !pending.isEmpty else { return [] }
        // On repart d'un fichier vide avant de lancer les telechargements.
        try? Data().write(to: url, options: .atomic)
        return pending
    }
}