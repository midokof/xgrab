import Foundation

enum JobState: String, Codable {
    case queued, running, done, failed
}

struct Job: Codable, Identifiable {
    let id: String
    var url: String
    var referer: String
    var filename: String
    var state: JobState
    var progress: Double
    var bytes: Int64
    var error: String?
    var localPath: String?

    /// Hauteur demandee au clic, sert a nommer le fichier et a choisir la
    /// variante HLS.
    var height: Int?

    /// Conserves pour rejouer la requete : les CDN protegent le fichier par
    /// l'User-Agent et les cookies de session.
    var userAgent: String?
    var cookies: String?

    var isActive: Bool { state == .queued || state == .running }
    var isSegmented: Bool { DownloadEngine.isHLS(url) }
}

/// Liste des telechargements.
///
/// Un seul point de verite : le moteur de telechargement y ecrit, l'interface
/// y lit. Aucun second stockage, donc aucune desynchronisation possible.
@MainActor
final class JobStore: ObservableObject {
    static let shared = JobStore()

    @Published private(set) var jobs: [Job] = []

    private var fileURL: URL? {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("jobs.json")
    }

    private init() { load() }

    // ------------------------------------------------------------- persistance

    private func load() {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([Job].self, from: data) {
            // Un telechargement interrompu par la fermeture de l'app n'a pas
            // de raison d'echouer silencieusement : il est repris.
            jobs = decoded.map { job in
                var copy = job
                if copy.isActive { copy.state = .queued; copy.progress = 0 }
                return copy
            }
        }
    }

    private func persist() {
        guard let url = fileURL,
              let data = try? JSONEncoder().encode(jobs) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // ------------------------------------------------------------------- api

    func job(id: String) -> Job? { jobs.first { $0.id == id } }

    var activeCount: Int { jobs.filter(\.isActive).count }

    @discardableResult
    func add(url: String,
             referer: String,
             userAgent: String?,
             cookies: String?,
             filename: String,
             height: Int?) -> Job {
        let job = Job(
            id: UUID().uuidString,
            url: url,
            referer: referer,
            filename: filename,
            state: .queued,
            progress: 0,
            bytes: 0,
            error: nil,
            localPath: nil,
            height: height,
            userAgent: userAgent,
            cookies: cookies
        )
        jobs.insert(job, at: 0)
        persist()
        return job
    }

    func update(id: String, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
        persist()
    }

    func remove(id: String) {
        jobs.removeAll { $0.id == id }
        persist()
    }

    func removeAll() {
        jobs.removeAll()
        persist()
    }
}