import SwiftUI

struct DownloadsView: View {
    @ObservedObject private var store = JobStore.shared
    @State private var showDiagnostic = false

    private var active: [Job] { store.jobs.filter { $0.state == .running || $0.state == .queued } }
    private var finished: [Job] { store.jobs.filter { $0.state == .done } }
    private var failed: [Job] { store.jobs.filter { $0.state == .failed } }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                header

                if store.jobs.isEmpty {
                    empty
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            if !active.isEmpty { section("En cours", items: active) }
                            if !failed.isEmpty { section("Échecs", items: failed) }
                            if !finished.isEmpty { section("Terminés", items: finished) }
                        }
                        .padding(.horizontal, Theme.gutter)
                        .padding(.bottom, 90)
                    }
                }
            }
        }
        .sheet(isPresented: $showDiagnostic) { DiagnosticView() }
    }

    // --------------------------------------------------------------- en-tete

    private var header: some View {
        ScreenHeader(title: "Fichiers", subtitle: summary) {
            Menu {
                Button {
                    store.reload()
                } label: {
                    Label("Actualiser", systemImage: "arrow.clockwise")
                }
                Button {
                    showDiagnostic = true
                } label: {
                    Label("Diagnostic", systemImage: "stethoscope")
                }
                if !store.jobs.isEmpty {
                    Divider()
                    Button(role: .destructive) {
                        for job in store.jobs { Downloader.shared.delete(jobID: job.id) }
                    } label: {
                        Label("Tout effacer", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white)
            }
        }
    }

    private var summary: String {
        let build = BrowserModel.buildLabel
        guard !store.jobs.isEmpty else { return "\(build) · Aucun téléchargement" }
        let done = finished.count
        let bytes = finished.reduce(Int64(0)) { $0 + $1.bytes }
        if active.isEmpty && failed.isEmpty {
            return "\(build) · \(done) fichier\(done > 1 ? "s" : "") · \(human(bytes))"
        }
        var parts: [String] = [build]
        if !active.isEmpty { parts.append("\(active.count) en cours") }
        if done > 0 { parts.append("\(done) terminé\(done > 1 ? "s" : "")") }
        if !failed.isEmpty { parts.append("\(failed.count) échec\(failed.count > 1 ? "s" : "")") }
        return parts.joined(separator: " · ")
    }

    // ---------------------------------------------------------------- corps

    @ViewBuilder
    private func section(_ title: String, items: [Job]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).sectionLabel()
            ForEach(items) { job in card(job) }
        }
    }

    private func card(_ job: Job) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                icon(job)
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.filename)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let error = job.error {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.danger)
                            .lineLimit(3)
                    } else if job.state == .done {
                        Text(human(job.bytes))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                badge(job)
            }

            if job.state == .running || job.state == .queued {
                ProgressTrack(value: job.progress)
                Text("\(Int(job.progress * 100)) % · \(human(job.bytes))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if job.state != .running && job.state != .queued {
                actions(job)
            }
        }
        .cardSurface()
    }

    private func icon(_ job: Job) -> some View {
        Image(systemName: symbol(job))
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(gradient(job)))
    }

    private func gradient(_ job: Job) -> LinearGradient {
        switch job.state {
        case .queued: LinearGradient(colors: [.gray, .gray.opacity(0.7)], startPoint: .top, endPoint: .bottom)
        case .running: Theme.accentGradient
        case .done: LinearGradient(colors: [Theme.success, Theme.success.opacity(0.7)], startPoint: .top, endPoint: .bottom)
        case .failed: LinearGradient(colors: [Theme.danger, Theme.danger.opacity(0.7)], startPoint: .top, endPoint: .bottom)
        }
    }

    private func symbol(_ job: Job) -> String {
        switch job.state {
        case .queued: "clock"
        case .running: "arrow.down"
        case .done: "checkmark"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func badge(_ job: Job) -> some View {
        switch job.state {
        case .queued: StatusPill(title: "EN ATTENTE", colour: .secondary)
        case .running: StatusPill(title: "\(Int(job.progress * 100))%", colour: Theme.accent)
        case .done: StatusPill(title: "TERMINÉ", colour: Theme.success)
        case .failed: StatusPill(title: "ÉCHEC", colour: Theme.danger)
        }
    }

    @ViewBuilder
    private func actions(_ job: Job) -> some View {
        HStack(spacing: 8) {
            if job.state == .failed {
                Button { Downloader.shared.retry(jobID: job.id) } label: {
                    chip("Réessayer", "arrow.clockwise", Theme.accent)
                }
                Button { Downloader.shared.forceWebKit(jobID: job.id) } label: {
                    chip("WebKit", "safari", Theme.warning)
                }
            }
            if job.state == .done, let path = job.localPath {
                ShareLink(item: URL(fileURLWithPath: path)) {
                    chip("Enregistrer", "square.and.arrow.down", Theme.success)
                }
            }
            if job.state == .running || job.state == .queued {
                Button { Downloader.shared.cancel(jobID: job.id) } label: {
                    chip("Annuler", "xmark", .secondary)
                }
            }
            Spacer()
            Button { Downloader.shared.delete(jobID: job.id) } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.danger)
            }
            .buttonStyle(.plain)
        }
    }

    private func chip(_ title: String, _ symbol: String, _ colour: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold))
            Text(title).font(.system(size: 11, weight: .bold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(colour.opacity(0.14)))
        .foregroundStyle(colour)
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 46))
                .foregroundStyle(Theme.accent.opacity(0.35))
            Text("Aucun téléchargement")
                .font(.system(size: 17, weight: .bold, design: .rounded))
            Text("Ouvre l'onglet Navigateur,\ncolle un lien et appuie sur Télécharger.")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
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