import SwiftUI

struct DownloadsView: View {
    @ObservedObject private var store = JobStore.shared
    @State private var showDiagnostic = false

    var body: some View {
        NavigationStack {
            Group {
                if store.jobs.isEmpty {
                    empty
                } else {
                    list
                }
            }
            .navigationTitle("Téléchargements")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showDiagnostic = true
                    } label: {
                        Image(systemName: "stethoscope")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        drainPending()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                if !store.jobs.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Tout effacer", role: .destructive) {
                            for job in store.jobs {
                                Downloader.shared.delete(jobID: job.id)
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showDiagnostic) {
                DiagnosticView()
            }
        }
    }

    /// Recupere les liens laisses par l'extension.
    private func drainPending() {
        for request in PendingQueue.drain() {
            for url in request.urls {
                Downloader.shared.enqueue(url: url, referer: request.referer)
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Aucun téléchargement")
                .font(.headline)
            Text("Le bouton XGrab sur une page vidéo\najoute le lien ici.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var list: some View {
        List {
            ForEach(store.jobs) { job in
                row(job)
            }
        }
    }

    private func row(_ job: Job) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(job.filename)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 8)
                badge(job)
            }

            if job.state == .running || job.state == .queued {
                ProgressView(value: job.progress)
                Text("\(Int(job.progress * 100)) % · \(human(job.bytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = job.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 14) {
                if job.state == .failed {
                    Button("Réessayer") { Downloader.shared.retry(jobID: job.id) }
                        .font(.caption.weight(.semibold))
                    Button("Forcer WebKit") { Downloader.shared.forceWebKit(jobID: job.id) }
                        .font(.caption.weight(.semibold))
                }
                if job.state == .running || job.state == .queued {
                    Button("Annuler") { Downloader.shared.cancel(jobID: job.id) }
                        .font(.caption.weight(.semibold))
                }
                if job.state == .done, let path = job.localPath {
                    ShareLink(item: URL(fileURLWithPath: path)) {
                        Text("Enregistrer dans Fichiers")
                            .font(.caption.weight(.semibold))
                    }
                }
                Spacer()
                Button(role: .destructive) {
                    Downloader.shared.delete(jobID: job.id)
                } label: {
                    Image(systemName: "trash").font(.caption)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
        }
        .padding(.vertical, 4)
    }

    private func badge(_ job: Job) -> some View {
        let label: String
        let colour: Color
        switch job.state {
        case .queued: label = "En attente"; colour = .secondary
        case .running: label = "Téléchargement"; colour = .blue
        case .done: label = "Terminé"; colour = .green
        case .failed: label = "Échec"; colour = .red
        }
        return Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(colour)
    }

    private func human(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 o" }
        let units = ["o", "Ko", "Mo", "Go"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return String(format: "%.1f %@", value, units[unit])
    }
}