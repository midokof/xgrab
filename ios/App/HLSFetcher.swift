import CommonCrypto
import Foundation

/// Lecture d'un manifeste HLS et dechiffrement de ses segments.
///
/// `AVAssetDownloadURLSession` refuse silencieusement un flux chiffre : le job
/// est cree, `resume()` ne leve aucune erreur, aucun delegate n'est appele et
/// la progression n'arrive jamais. Aucun remede cote Apple.
///
/// On fait donc le travail nous-memes. Deux manieres d'obtenir le plan :
///
///  * `PageScript.hlsPlanner` lit les manifestes **et les cles** depuis le
///    contexte de la page. C'est le seul endroit ou la reponse du CDN est
///    acceptee telle qu'elle, avec les cookies et le `User-Agent` du lecteur.
///    C'est le chemin nominal.
///  * `HLSFetcher.plan` refait le meme travail en Swift, pour le repli : quand
///    la page refuse la requete (CORS), ou quand le script n'a pas reussi.
///
/// Le plan ne contient que des adresses et des cles de 16 octets. Les
/// segments, eux, sont telecharges par `HLSDownloader` : faire transiter
/// des dizaines de Mo par `postMessage` serait le meilleur moyen de tuer le
/// processus de contenu.

enum HLSError: LocalizedError {
    case manifest(String)
    case unsupported(String)
    case badKey
    case keyUnavailable
    case http(Int, String)
    case decrypt(String)
    case assembly
    case cancelled

    var errorDescription: String? {
        switch self {
        case .manifest(let why):
            return "Manifeste illisible : \(why)"
        case .unsupported(let method):
            return "Chiffrement \(method) non pris en charge (seul AES-128 l'est)"
        case .badKey:
            return "Clé de chiffrement illisible"
        case .keyUnavailable:
            return "Clé de chiffrement absente du plan"
        case .http(let status, let name):
            return "HTTP \(status) sur \(name)"
        case .decrypt(let name):
            return "Déchiffrement impossible : \(name)"
        case .assembly:
            return "Assemblage du fichier impossible"
        case .cancelled:
            return "Annulé"
        }
    }
}

// MARK: - Plan

/// Un segment tel qu'il sera demande au reseau.
struct HLSSegment: Sendable {
    let url: URL
    /// Index dans `HLSPlan.keys`, ou -1 si le segment est en clair.
    let keyIndex: Int
    /// Vecteur d'initialisation explicite. `nil` : il se deduit du numero de
    /// sequence, comme le veut la specification quand `IV` est absent.
    let iv: Data?
    let sequence: Int
    /// Plage d'octets a lire dans la ressource, pour un `#EXT-X-BYTERANGE`.
    let range: ClosedRange<Int>?
}

struct HLSPlan: Sendable {
    var manifest: URL
    var variant: URL
    var height: Int
    var duration: Double
    var encrypted: Bool
    /// Une entree par cle distincte du manifeste. Peut etre vide quand la page
    /// n'a pas pu la lire : `HLSDownloader` la telecharge alors lui-meme.
    var keys: [Data]
    var keyUris: [URL]
    var keyMethods: [String]
    var initURL: URL?
    var initRange: ClosedRange<Int>?
    var segments: [HLSSegment]

    /// CommonCrypto ne sait faire qu'AES-128. `SAMPLE-AES` et `cbcs` folate
    /// des segments par exemple, ce qu'iOS refuse aussi bien : inutile
    /// d'ouvrir un fichier qu'on ne saura pas dechiffrer.
    func unsupportedMethod() -> String? {
        keyMethods.first { $0 != "AES-128" && $0 != "NONE" }
    }
}

extension HLSPlan {

    /// Reconstruit le plan emis par `PageScript.hlsPlanner`.
    ///
    /// Les tableaux arrivent en parallele plutot que sous forme d'objets :
    /// un plan de video longue compte plusieurs centaines de segments, et le
    /// passage par `postMessage` coute bien moins en tableaux primitifs.
    init?(message body: [String: Any]) {
        guard let manifestText = body["manifest"] as? String,
              let manifest = URL(string: manifestText),
              let variantText = body["variant"] as? String,
              let variant = URL(string: variantText) else { return nil }

        // `stringList` rend deja un tableau, optionnel ou non : l'ecrire
        // dans un `guard let` ferait echouer la compilation.
        let urls = HLSPlan.stringList(body["urls"])
        guard !urls.isEmpty else { return nil }

        let keyIndexes = HLSPlan.intList(body["key"])
        let ivs = HLSPlan.stringList(body["iv"])
        let seqs = HLSPlan.intList(body["seq"])
        let ranges = HLSPlan.stringList(body["range"])
        let blobs = HLSPlan.stringList(body["keys"])
        let uris = HLSPlan.stringList(body["keyUris"])
        let methods = HLSPlan.stringList(body["keyMethods"])

        // Les trois tableaux de cles sont paralleles et indexes par `key`.
        // Une entree perdue dans l'un decale toutes les suivantes : on
        // dechiffrerait alors avec la mauvaise cle, sans aucun message. Le
        // script garantit l'egalite des longueurs ; on la verifie plutot que
        // de la croire.
        guard blobs.count == uris.count, blobs.count == methods.count,
              uris.allSatisfy({ URL(string: $0) != nil }) else { return nil }

        // Les quatre autres tableaux sont lus par position. Une entree perdue
        // dans l'un decalerait les numeros de segment, les vecteurs
        // d'initialisation et les plages d'octets : le dechiffrement echouerait
        // sans raison lisible. On exige l'egalite plutot que de la supposer.
        guard keyIndexes.count == urls.count, ivs.count == urls.count,
              seqs.count == urls.count, ranges.count == urls.count else { return nil }

        var built: [HLSSegment] = []
        built.reserveCapacity(urls.count)
        for (index, text) in urls.enumerated() {
            guard let url = URL(string: text) else { continue }
            // `value` est un membre statique : dans un `init`, le contexte est
            // l'instance, il faut donc le nommer explicitement.
            let keyIndex = Self.value(keyIndexes, index, -1)
            let iv = HLSCrypto.hex(Self.value(ivs, index, ""))
            let sequence = Self.value(seqs, index, index)
            let range = HLSCrypto.byteRange(Self.value(ranges, index, ""))
            built.append(HLSSegment(url: url, keyIndex: keyIndex, iv: iv,
                                    sequence: sequence, range: range))
        }
        guard !built.isEmpty else { return nil }

        self.manifest = manifest
        self.variant = variant
        height = HLSPlan.int(body["height"])
        duration = (body["duration"] as? NSNumber)?.doubleValue ?? 0
        encrypted = (body["encrypted"] as? Bool) ?? false
        // Une cle non decodable devient une cle vide plutot que de disparaitre :
// `HLSDownloader` la retelechargera, et les index restent alignes.
        keys = blobs.map { Data(base64Encoded: $0) ?? Data() }
        keyUris = uris.compactMap { URL(string: $0) }
        keyMethods = methods

        let initText = (body["initUrl"] as? String) ?? ""
        initURL = initText.isEmpty ? nil : URL(string: initText)
        let initSpan = (body["initRange"] as? String) ?? ""
        initRange = HLSCrypto.byteRange(initSpan)
        segments = built
    }

    /// Les tableaux du script sont paralleles mais de longueurs differentes :
    /// ce radar evite un piege hors de portee.
    private static func value<T>(_ list: [T], _ index: Int, _ fallback: T) -> T {
        index < list.count ? list[index] : fallback
    }

    private static func stringList(_ any: Any?) -> [String] {
        (any as? [Any])?.compactMap { $0 as? String } ?? []
    }

    private static func intList(_ any: Any?) -> [Int] {
        (any as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? []
    }

    private static func int(_ any: Any?) -> Int {
        (any as? NSNumber)?.intValue ?? 0
    }
}

// MARK: - Cookies

struct CookieEntry: Sendable {
    let domain: String
    let pair: String
}

/// En-tete `Cookie` filtre par hote.
///
/// Le manifeste, les segments et la cle vivent rarement sur le meme domaine :
/// un header unique, copie depuis la page, serait rejete par le CDN. On ne
/// renvoie que ce qui concerne l'hote demande.
struct CookieJar: Sendable {
    let entries: [CookieEntry]

    /// A partir de la liste complete fournie par le `WKWebView`.
    init(cookies: [HTTPCookie]) {
        entries = cookies.map { cookie in
            let domain = cookie.domain
                .lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return CookieEntry(domain: domain, pair: "\(cookie.name)=\(cookie.value)")
        }
    }

    /// A partir d'un header deja plat. Les domaines sont perdus : on ne peut
    /// plus filtrer, donc tout est renvoye. Sert au rejeu d'un job memorise.
    init(header: String?) {
        let raw = header ?? ""
        entries = raw
            .components(separatedBy: ";")
            .compactMap { piece in
                let trimmed = piece.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, trimmed.contains("=") else { return nil }
                return CookieEntry(domain: "", pair: trimmed)
            }
    }

    /// Header complet, sans distinction de domaine : a n'utiliser que pour
    /// memoriser une requete rejouable, jamais pour l'envoyer tel quel.
    var flat: String {
        entries.map(\.pair).joined(separator: "; ")
    }

    func header(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let matched = entries.filter { entry in
            guard !entry.domain.isEmpty else { return true }
            return host == entry.domain || host.hasSuffix("." + entry.domain)
        }
        guard !matched.isEmpty else { return nil }
        return matched.map(\.pair).joined(separator: "; ")
    }
}

// MARK: - Dechiffrement

enum HLSCrypto {

    /// AES-128-CBC, bourrage PKCS#7, conforme a `RFC 8216` section 4.3.2.
    static func decrypt(_ data: Data, key: Data, iv: Data) -> Data? {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128,
              !data.isEmpty else { return nil }

        // `withUnsafeMutableBytes` est `mutating` : la variable est verrouillee
        // pendant toute la closure. Relire `output.count` dedans est un acces
        // qui se chevauche, et le controle d'exclusivite leve une exception au
        // premier segment chiffre. La capacite est donc relevee avant.
        let capacity = data.count + kCCBlockSizeAES128
        var output = Data(count: capacity)
        var moved = 0

        let status: CCCryptorStatus = output.withUnsafeMutableBytes { outRaw in
            data.withUnsafeBytes { inRaw in
                key.withUnsafeBytes { keyRaw in
                    iv.withUnsafeBytes { ivRaw in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyRaw.baseAddress, key.count,
                            ivRaw.baseAddress,
                            inRaw.baseAddress, data.count,
                            outRaw.baseAddress, capacity,
                            &moved
                        )
                    }
                }
            }
        }

        // `kCCSuccess` vient d'une enum anonyme importee en `Int32`. La conversion
        // explicite rend l'intention lisible et survit a un changement
        // d'import du module.
        guard status == CCCryptorStatus(kCCSuccess), moved > 0 else { return nil }
        output.count = moved
        return output
    }

    /// Sans `IV` dans le manifeste, le vecteur est le numero de sequence du
    /// segment, ecrit sur 16 octets en big-endian.
    static func defaultIV(_ sequence: Int) -> Data {
        var iv = Data(repeating: 0, count: kCCBlockSizeAES128)
        var value = UInt64(max(sequence, 0))
        var offset = iv.count - 1
        while offset >= 0 {
            iv[offset] = UInt8(truncatingIfNeeded: value)
            value >>= 8
            offset -= 1
        }
        return iv
    }

    /// `0x1a2b...` ou `1a2b...` vers 16 octets.
    static func hex(_ text: String) -> Data? {
        var slice = Substring(text.trimmingCharacters(in: .whitespaces))
        if slice.hasPrefix("0x") || slice.hasPrefix("0X") { slice = slice.dropFirst(2) }
        guard !slice.isEmpty, slice.count % 2 == 0 else { return nil }

        var data = Data(capacity: slice.count / 2)
        var index = slice.startIndex
        while index < slice.endIndex {
            let next = slice.index(index, offsetBy: 2)
            guard let byte = UInt8(slice[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    /// `debut:longueur` vers une plage inclusive, comme l'attend HTTP.
    static func byteRange(_ text: String) -> ClosedRange<Int>? {
        let parts = text.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let start = Int(parts[0]), let length = Int(parts[1]), length > 0 else { return nil }
        return start...(start + length - 1)
    }

    /// Un flux MPEG-2 commence par 0x47 tous les 188 octets. C'est ce test qui
    /// distingue un assemblage a remuxer d'un MP4 fragment deja complet.
    ///
    /// Les boites d'un `.m4s` leve aussi 0x47, mais jamais a ces offsets-la :
    /// la taille d'une boite ne se trouve pas juste.
    static func looksLikeMPEGTS(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(752))
        guard bytes.count >= 376 else { return false }

        var offset = 0
        var hits = 0
        while offset < bytes.count {
            if bytes[offset] != 0x47 { return false }
            hits += 1
            offset += 188
        }
        return hits >= 2
    }
}

// MARK: - Lecture des manifestes

/// Lecteur HLS en Swift : sert de repli quand le script de page n'a pas pu
/// lire les manifestes, et de source de verite pour les cles manquantes.
enum HLSFetcher {

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// Construit le plan complet : variante, cles, segments.
    ///
    /// Les cles ne sont pas telechargees ici : elles sont laissees vides et
    /// `HLSDownloader` les recupere au moment d'en avoir besoin.
    static func plan(manifest: URL,
                     height: Int,
                     referer: String,
                     userAgent: String?,
                     cookies: CookieJar) async throws -> HLSPlan {

        let headers = baseHeaders(referer: referer, userAgent: userAgent)

        var effective = manifest
        var variantHeight = 0
        var media = ""

        let master = try await text(from: manifest, headers: headers, jar: cookies)

        let variants = master.contains("#EXT-X-STREAM-INF")
            ? parseMaster(master, base: manifest) : []

        if !variants.isEmpty, let pick = closest(variants, toHeight: height) {
            CrashLog.step("HLS natif: variante \(pick.height)p sur \(variants.count)")
            effective = pick.url
            variantHeight = pick.height
            media = try await text(from: pick.url, headers: headers, jar: cookies)
        } else if master.contains("#EXTINF") || master.contains("#EXT-X-MAP") {
            // Le manifeste annoncait des variantes sans en lister, ou n'en
            // annoncait pas : c'est un manifeste media. Le script de page
            // degrade exactement ainsi, et les deux doivent produire le meme
            // fichier.
            media = master
        } else {
            throw HLSError.manifest("aucune variante listée")
        }

        let parsed = try parseMedia(media, base: effective)

        var plan = HLSPlan(
            manifest: manifest,
            variant: effective,
            height: variantHeight,
            duration: parsed.duration,
            encrypted: parsed.encrypted,
            keys: Array(repeating: Data(), count: parsed.keys.count),
            keyUris: parsed.keys,
            keyMethods: parsed.keyMethods,
            initURL: parsed.initURL,
            initRange: parsed.initRange,
            segments: parsed.segments
        )
        if let blocked = plan.unsupportedMethod() { throw HLSError.unsupported(blocked) }
        if plan.height == 0 { plan.height = height }
        return plan
    }

    /// Telecharge un segment et renvoie ses octets dechiffres, ou bruts s'il
    /// ne l'est pas.
    static func payload(of segment: HLSSegment,
                        keys: [Data],
                        headers: [String: String],
                        jar: CookieJar) async throws -> Data {
        let raw = try await data(from: segment.url, range: segment.range,
                                 headers: headers, jar: jar)
        guard segment.keyIndex >= 0 else { return raw }

        guard segment.keyIndex < keys.count else { throw HLSError.keyUnavailable }
        let key = keys[segment.keyIndex]
        guard key.count == kCCKeySizeAES128 else { throw HLSError.badKey }

        let iv = segment.iv ?? HLSCrypto.defaultIV(segment.sequence)
        guard iv.count == kCCBlockSizeAES128 else { throw HLSError.badKey }
        guard let clear = HLSCrypto.decrypt(raw, key: key, iv: iv) else {
            throw HLSError.decrypt(segment.url.lastPathComponent)
        }
        return clear
    }

    /// Recupere une cle absente du plan. Le CDN peut exiger le `Referer` de la
    /// page : il est renvoye par l'appelant.
    static func key(from url: URL,
                     headers: [String: String],
                     jar: CookieJar) async throws -> Data {
        let raw = try await data(from: url, range: nil, headers: headers, jar: jar)
        guard raw.count == kCCKeySizeAES128 else {
            throw HLSError.keyUnavailable
        }
        return raw
    }

    // MARK: Reseau

    private static func baseHeaders(referer: String, userAgent: String?) -> [String: String] {
        var headers: [String: String] = [:]
        if let agent = userAgent, !agent.isEmpty { headers["User-Agent"] = agent }
        if !referer.isEmpty { headers["Referer"] = referer }
        return headers
    }

    static func data(from url: URL,
                      range: ClosedRange<Int>?,
                      headers: [String: String],
                      jar: CookieJar? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        // Le manifeste, les segments et la cle n'habitent pas le meme domaine :
        // un header `Cookie` unique serait rejete par le CDN.
        if let cookie = jar?.header(for: url), !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if let range {
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)",
                             forHTTPHeaderField: "Range")
        }

        let (payload, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw HLSError.http(status, url.lastPathComponent)
        }
        return payload
    }

    private static func text(from url: URL,
                             headers: [String: String],
                             jar: CookieJar) async throws -> String {
        let payload = try await data(from: url, range: nil, headers: headers, jar: jar)
        guard let text = String(data: payload, encoding: .utf8) else {
            throw HLSError.manifest("réponse illisible")
        }
        return text
    }

    // MARK: Analyse

    struct Variant: Sendable {
        let url: URL
        let height: Int
        let bandwidth: Int
    }

    /// Resout une reference de manifeste.
    ///
    /// `URL(string:relativeTo:)` refuse certaines references qu'un CDN
    /// produit quand meme : un nom de segment contenant un espace passe par
    /// `%20`, un dièse est un fragment. Sans repli, la liste s'arrete net au
    /// premier segment et le plan revient avec une URL relative.
    static func resolve(_ reference: String, base: URL) -> URL? {
        if let url = URL(string: reference, relativeTo: base)?.absoluteURL {
            return url
        }
        let escaped = reference
            .replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "#", with: "%23")
        return URL(string: escaped, relativeTo: base)?.absoluteURL
    }

    /// `#EXT-X-STREAM-INF:BANDWIDTH=…,RESOLUTION=1280x720` suivi de l'URL,
    /// relative au manifeste.
    static func parseMaster(_ text: String, base: URL) -> [Variant] {
        var found: [Variant] = []
        var pending: [String: String] = [:]

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                // Le deux-points fait partie du nom de la balise. Le laisser
                // dans le corps colle `:` au premier nom d'attribut, et
                // `BANDWIDTH` — qui est justement place en premier — n'est
                // jamais trouve.
                let body = line.dropFirst("#EXT-X-STREAM-INF".count)
                pending = attributes(body.hasPrefix(":") ? String(body.dropFirst()) : String(body))
                continue
            }
            guard !pending.isEmpty, !line.isEmpty, !line.hasPrefix("#") else { continue }
            let declared = pending
            pending = [:]

            guard let url = resolve(line, base: base) else { continue }

            let size = (declared["RESOLUTION"] ?? "").lowercased().split(separator: "x")
            let height = size.count == 2 ? (Int(size[1]) ?? 0) : 0
            let bandwidth = Int(declared["AVERAGE-BANDWIDTH"] ?? declared["BANDWIDTH"] ?? "") ?? 0
            found.append(Variant(url: url, height: height, bandwidth: bandwidth))
        }
        return found
    }

    static func closest(_ variants: [Variant], toHeight target: Int) -> Variant? {
        guard !variants.isEmpty else { return nil }
        if target > 0 {
            return variants.min { abs($0.height - target) < abs($1.height - target) }
        }
        return variants.max { ($0.height, $0.bandwidth) < ($1.height, $1.bandwidth) }
    }

    struct Parsed: Sendable {
        var segments: [HLSSegment] = []
        var keys: [URL] = []
        var keyMethods: [String] = []
        var initURL: URL?
        var initRange: ClosedRange<Int>?
        var duration: Double = 0
        var encrypted = false
    }

    /// Parcours d'un manifeste media.
    ///
    /// Quatre details qui font echouer la plupart des lecteurs :
    /// l'URL d'un segment est relative au **manifeste de variante**, pas au
    /// manifeste maitre ; `#EXTINF:6.006,titre` porte une virgule qu'un
    /// `Double()` brutal refuse ; `EXT-X-BYTERANGE` sans offset explicite
    /// enchaine sur la fin du segment precedent de la meme ressource ; et
    /// `EXT-X-DISCONTINUITY` reinitialise ce curseur.
    static func parseMedia(_ text: String, base: URL) throws -> Parsed {
        var parsed = Parsed()
        var sequence = 0
        var pendingRange = ""
        var cursors: [String: Int] = [:]
        var currentKey = -1
        var currentIV: Data?
        var keySlots: [String: Int] = [:]

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                sequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
                continue
            }
            if line.hasPrefix("#EXT-X-KEY:") {
                let key = attributes(String(line.dropFirst("#EXT-X-KEY:".count)))
                let method = (key["METHOD"] ?? "NONE").uppercased()
                if method == "NONE" {
                    currentKey = -1
                    currentIV = nil
                    continue
                }
                parsed.encrypted = true
                guard let uri = key["URI"], let url = resolve(uri, base: base) else {
                    throw HLSError.manifest("clé sans URI exploitable")
                }
                let identity = url.absoluteString
                if let existing = keySlots[identity] {
                    currentKey = existing
                } else {
                    keySlots[identity] = parsed.keys.count
                    parsed.keys.append(url)
                    parsed.keyMethods.append(method)
                    currentKey = parsed.keys.count - 1
                }
                currentIV = key["IV"].flatMap { HLSCrypto.hex($0) }
                continue
            }
            if line.hasPrefix("#EXT-X-MAP:") {
                let map = attributes(String(line.dropFirst("#EXT-X-MAP:".count)))
                if let uri = map["URI"], let url = resolve(uri, base: base) {
                    parsed.initURL = url
                    parsed.initRange = map["BYTERANGE"].flatMap { HLSCrypto.byteRange($0) }
                }
                continue
            }
            if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingRange = String(line.dropFirst("#EXT-X-BYTERANGE:".count))
                continue
            }
            if line.hasPrefix("#EXTINF:") {
                // La duree s'arrete a la virgule : ce qui suit est un titre
                // libre qui peut contenir n'importe quoi.
                let body = line.dropFirst("#EXTINF:".count)
                let head = body.prefix { $0 != "," }
                parsed.duration += Double(head) ?? 0
                continue
            }
            if line.hasPrefix("#EXT-X-DISCONTINUITY") {
                cursors.removeAll()
                pendingRange = ""
                continue
            }
            if line.hasPrefix("#") { continue }

            guard let url = resolve(line, base: base) else { continue }

            var range: ClosedRange<Int>?
            if !pendingRange.isEmpty {
                let bits = pendingRange.split(separator: "@")
                let length = Int(bits.first ?? "") ?? 0
                let start = bits.count > 1 ? (Int(bits[1]) ?? 0)
                                           : (cursors[url.absoluteString] ?? 0)
                if length > 0 {
                    range = start...(start + length - 1)
                    cursors[url.absoluteString] = start + length
                }
                pendingRange = ""
            }

            parsed.segments.append(HLSSegment(url: url, keyIndex: currentKey,
                                              iv: currentIV, sequence: sequence, range: range))
            sequence += 1
        }

        guard !parsed.segments.isEmpty else {
            throw HLSError.manifest("aucun segment listé")
        }
        return parsed
    }

    /// Analyse une liste d'attributs HLS : `A=1,B="x,y",C=z`.
    ///
    /// Le separateur virgule ne compte pas a l'interieur des guillemets, ce
    /// que les codecs de lecture oublient souvent et qui massacre les
    /// `CODECS="avc1.4d401f,mp4a.40.2"`.
    static func attributes(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        var key = ""
        var value = ""
        var quoted = false
        var readingKey = true

        func flush() {
            let name = key.trimmingCharacters(in: .whitespaces).uppercased()
            if !name.isEmpty { out[name] = value.trimmingCharacters(in: .whitespaces) }
            key = ""
            value = ""
            quoted = false
            readingKey = true
        }

        for character in text {
            if character == "\"" {
                quoted.toggle()
                continue
            }
            if character == ",", !quoted {
                flush()
                continue
            }
            if character == "=", readingKey, !quoted {
                readingKey = false
                continue
            }
            if readingKey { key.append(character) } else { value.append(character) }
        }
        flush()
        return out
    }
}