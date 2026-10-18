import Foundation

/// Lecture d'un manifeste HLS pour choisir la qualite demandee.
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
enum HLSVariants {

    struct Variant {
        let url: String
        let width: Int
        let height: Int
        let bandwidth: Int
    }

    /// Session separee : une session en arriere-plan ne peut pas executer de
    /// tache de donnees.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    /// Renvoie l'URL effective a telecharger. Si le manifeste ne propose
    /// aucune variante, l'URL d'origine convient.
    static func resolve(master: String,
                        height: Int,
                        referer: String,
                        userAgent: String?,
                        cookies: String?,
                        then: @escaping (String) -> Void) {
        guard height > 0 else {
            then(master)
            return
        }
        guard let parsed = URL(string: master) else {
            then(master)
            return
        }

        var request = URLRequest(url: parsed)
        if !referer.isEmpty { request.setValue(referer, forHTTPHeaderField: "Referer") }
        if let agent = userAgent, !agent.isEmpty { request.setValue(agent, forHTTPHeaderField: "User-Agent") }
        if let jar = cookies, !jar.isEmpty { request.setValue(jar, forHTTPHeaderField: "Cookie") }

        session.dataTask(with: request) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, (200..<300).contains(status),
                  let text = String(data: data, encoding: .utf8) else {
                then(master)
                return
            }
            let found = parse(text, base: parsed)
            guard let pick = closest(found, toHeight: height) else {
                // Manifeste de variante unique : on le telecharge tel quel.
                then(master)
                return
            }
            CrashLog.step("HLS: variante \(pick.height)p sur \(found.count) disponibles")
            then(pick.url)
        }.resume()
    }

    /// Extrait les couples `#EXT-X-STREAM-INF` / URL suivante.
    static func parse(_ text: String, base: URL) -> [Variant] {
        var found: [Variant] = []
        var pending = ""

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                pending = line
                continue
            }
            guard !pending.isEmpty, !line.isEmpty, !line.hasPrefix("#") else { continue }
            let attributes = pending
            pending = ""

            var width = 0, height = 0, bandwidth = 0
            for chunk in attributes.components(separatedBy: ",") {
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

    static func closest(_ variants: [Variant], toHeight target: Int) -> Variant? {
        guard !variants.isEmpty else { return nil }
        guard target > 0 else {
            return variants.max { a, b in (a.height, a.bandwidth) < (b.height, b.bandwidth) }
        }
        return variants.min { a, b in abs(a.height - target) < abs(b.height - target) }
    }
}