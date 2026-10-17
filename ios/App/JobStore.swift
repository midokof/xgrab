import Foundation

enum JobState: String, Codable {
    case queued
    case running
    case done
    case failed
}

struct Job: Codable, Identifiable, Equatable {
    let id: String
    let url: String
    let referer: String
    var filename: String
    var state: JobState
    var progress: Double
    var bytes: Int64
    var error: String?
    var localPath: String?
    var isHLS: Bool

    var addedAt: Date

    /// Conserves pour pouvoir rejouer la requete : les CDN protegent
    /// souvent le fichier par le User-Agent et les cookies de session.
    var userAgent: String?
    var cookies: String?

    var isActive: Bool { state == .queued || state == .running }
}

/// Liste des telechargements, partagee entre le handler natif et l'interface.
final class JobStore: ObservableObject {
    static let shared = JobStore()

    /// Conteneur partage : l'extension ecrit, l'app affiche.
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.app.xgrab")
    }

    static var storeURL: URL? {
        containerURL?.appendingPathComponent("jobs.json")
    }

    @Published private(set) var jobs: [Job] = []

    private let queue = DispatchQueue(label: "app.xgrab.store")
    private let key = "jobStore.didLoad"

    private init() {
        load()
    }

    // ------------------------------------------------------------- persistance

    private func load() {
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        guard let url = Self.storeURL, let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([Job].self, from: data) {
            publish(decoded)
        }
    }

    private func persist(_ snapshot: [Job]) {
        queue.async {
            guard let url = JobStore.storeURL,
                  let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private func publish(_ value: [Job]) {
        if Thread.isMainThread {
            jobs = value
        } else {
            DispatchQueue.main.async { self.jobs = value }
        }
    }

    // ------------------------------------------------------------------ lecture

    func job(id: String) -> Job? {
        jobs.first { $0.id == id }
    }

    var activeCount: Int {
        jobs.filter(\.isActive).count
    }

    // ------------------------------------------------------------------ ecriture

    @discardableResult
    func enqueue(url: String, referer: String, userAgent: String? = nil, cookies: String? = nil) -> Job {
        let job = Job(
            id: UUID().uuidString,
            url: url,
            referer: referer,
            filename: Downloader.filename(for: url),
            state: .queued,
            progress: 0,
            bytes: 0,
            error: nil,
            localPath: nil,
            isHLS: Downloader.isHLS(url),
            addedAt: Date(),
            userAgent: userAgent,
            cookies: cookies
        )
        apply { $0.insert(job, at: 0) }
        return job
    }

    func update(id: String, _ change: (inout Job) -> Void) {
        apply { list in
            guard let index = list.firstIndex(where: { $0.id == id }) else { return }
            change(&list[index])
        }
    }

    func remove(id: String) {
        apply { list in
            list.removeAll { $0.id == id }
        }
    }

    func removeAll() {
        apply { $0.removeAll() }
    }

    private func apply(_ mutate: (inout [Job]) -> Void) {
        var copy = jobs
        mutate(&copy)
        persist(copy)
        publish(copy)
    }
}