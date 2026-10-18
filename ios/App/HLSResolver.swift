import Foundation

/// Choisit la variante HLS correspondant a la resolution en cours de lecture.
///
/// Un manifeste maitre liste les qualites disponibles :
///
///     #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
///     360/index.m3u8
///     #EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1280x720
///     720/index.m3u8
///
/// `AVAssetDownloadURLSession` choisirait la meilleure qualite, pas celle que
/// l'utilisateur regarde. On lit donc le manifeste et on retient la variante
/// dont la hauteur est la plus proche de celle affichee par la balise video.
enum HLSResolver {

    struct Variant {
        let url: String
        let width: Int
        let height: Int
        let bandwidth: Int
    }

    enum Failure: LocalizedError {
        case badURL
        case unreachable(Int)
        case notAMaster

        var errorDescription: String? {
            switch self {
            case .badURL: return "URL de flux invalide"
            case .unreachable(let code): return "Manifeste inaccessible (\(code))"
            case .notAMaster: return "Le flux ne propose pas de choix de qualité"
            }
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        // Une session en arriere-plan ne peut pas faire de tache de donnees.
        return URLSession(configuration: config)
    }()

    /// Liste les variantes d'un manifeste maitre. Une liste vide signifie que
    /// l'URL designe deja une variante unique : elle convient telle quelle.
    static func variants(
        of url: String,
        referer: String,
        userAgent: String?,
        cookies: String?,
        completion: @escaping ([Variant]) -> Void
    ) {
        guard let parsed = URL(string: url) else {
            completion([])
            return
        }

        var request = URLRequest(url: parsed)
        if !referer.isEmpty { request.setValue(referer, forHTTPHeaderField: "Referer") }
        if let agent = userAgent, !agent.isEmpty { request.setValue(agent, forHTTPHeaderField: "User-Agent") }
        if let jar = cookies, !jar.isEmpty { request.setValue(jar, forHTTPHeaderField: "Cookie") }

        session.dataTask(with: request) { data, response, _ in
            guard let data,
                  let status = (response as? HTTPURLResponse)?.statusCode,
                  (200..<300).contains(status),
                  let text = String(data: data, encoding: .utf8) else {
                completion([])
                return
            }
            completion(parse(text, base: parsed))
        }.resume()
    }

    /// Extrait les couples `#EXT-X-STREAM-INF` / URL suivante.
    static func parse(_ text: String, base: URL) -> [Variant] {
        var found: [Variant] = []
        var pending = ""
        let lines = text.components(separatedBy: .newlines)

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                pending = line
                continue
            }
            guard !pending.isEmpty, !line.isEmpty, !line.hasPrefix("#") else { continue }
            pending = ""

            var width = 0, height = 0, bandwidth = 0
            for chunk in pending.components(separatedBy: ",") {
                let pair = chunk.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                let key = pair[0].trimmingCharacters(in: .whitespaces).uppercased()
                let value = pair[1].trimmingCharacters(in: .whitespaces)
                switch key {
                case "RESOLUTION":
                    let parts = value.lowercased().split(separator: "x")
                    if parts.count == 2 {
                        width = Int(parts[0]) ?? 0
                        height = Int(parts[1]) ?? 0
                    }
                case "BANDWIDTH":
                    bandwidth = Int(value) ?? 0
                default:
                    continue
                }
            }

            // Les variantes sont relatives au manifeste.
            let resolved = URL(string: line, relativeTo: base)?.absoluteString ?? line
            found.append(Variant(url: resolved, width: width, height: height, bandwidth: bandwidth))
        }
        return found
    }

    /// Variante la plus proche de la hauteur demandee. A defaut de cible, on
    /// prend la plus haute qualite disponible.
    static func closest(_ variants: [Variant], toHeight target: Int) -> Variant? {
        guard !variants.isEmpty else { return nil }
        if target <= 0 {
            return variants.max { a, b in
                (a.height, a.bandwidth) < (b.height, b.bandwidth)
            }
        }
        return variants.min { a, b in
            abs(a.height - target) < abs(b.height - target)
        }
    }

    /// Resolution d'URL complete pour une hauteur donnee.
    static func url(
        for master: String,
        height: Int,
        referer: String,
        userAgent: String?,
        cookies: String?,
        completion: @escaping (String) -> Void
    ) {
        guard height > 0 else {
            completion(master)
            return
        }
        variants(of: master, referer: referer, userAgent: userAgent, cookies: cookies) { list in
            // Liste vide : le manifeste est deja une variante unique.
            guard let pick = closest(list, toHeight: height) else {
                completion(master)
                return
            }
            completion(pick.url)
        }
    }
}