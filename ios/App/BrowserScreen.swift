import SwiftUI
import WebKit

struct BrowserScreen: View {
    @ObservedObject var model: BrowserModel

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            statusBar
            Divider()
            WebSlot(model: model)
            footer.padding(.bottom, 74)
        }
    }

    // ------------------------------------------------------------ barre d'adresse

    private var addressBar: some View {
        HStack(spacing: 8) {
            Button { model.goBack() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .disabled(!model.canGoBack)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                TextField("Collez un lien ici", text: $model.address)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .font(.system(size: 15))

                if model.loading {
                    ProgressView().controlSize(.small)
                } else if !model.address.isEmpty {
                    Button { model.clearAddress() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(model.tracks.isEmpty ? 0 : 0.5),
                                  lineWidth: 2)
            )

            Button { model.reload() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Theme.accent.opacity(0.15)))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .background(.bar)
    }

    // ------------------------------------------------------------------ etat

    private var statusBar: some View {
        HStack(spacing: 6) {
            Text(BrowserModel.buildLabel)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)

            StatusPill(
                title: model.blocking ? "BLOCAGE ON" : "BLOCAGE OFF",
                colour: model.blocking ? Theme.success : .secondary
            )

            let count = model.tracks.count
            StatusPill(
                title: model.seen == 0
                    ? "0 VIDÉO"
                    : "\(count)/\(model.seen) VIDÉO\(model.seen > 1 ? "S" : "")",
                colour: count == 0 ? Theme.warning : Theme.accent
            )

            if model.buttonPlaced {
                StatusPill(title: "BOUTON POSÉ", colour: Theme.success)
            }
            if let failure = model.failure {
                StatusPill(title: "SONDE KO", colour: Theme.danger)
            }

            Spacer()

            Button {
                model.toggleBlocking()
            } label: {
                Text(model.blocking ? "couper" : "activer")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.blocking ? Theme.danger : Theme.success)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.bottom, 5)
        .background(.bar)
    }

    // --------------------------------------------------------------- messages

    @ViewBuilder
    private var footer: some View {
        if let message = model.message {
            HStack(spacing: 8) {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                if model.tracks.count > 1 { picker }
                if let track = model.chosen { downloadButton(track) }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private var picker: some View {
        Menu {
            ForEach(model.tracks) { track in
                Button {
                    model.pickedURL = track.url
                } label: {
                    Label(track.label, systemImage: track.segmented ? "square.stack.3d.up" : "film")
                }
            }
        } label: {
            Text("Choisir")
                .font(.system(size: 11, weight: .bold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Theme.accent.opacity(0.16)))
                .foregroundStyle(Theme.accent)
        }
    }

    private func downloadButton(_ track: Track) -> some View {
        Button {
            model.download(track)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 15))
                Text(track.height > 0 ? "\(track.height)p" : "MP4")
                    .font(.system(size: 13, weight: .bold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Theme.accentGradient))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
}

/// La vue web ne fait qu'h hosting : le `WKWebView` est cree une fois par
/// `BrowserModel` et ne quitte jamais son parent.
private struct WebSlot: UIViewRepresentable {
    @ObservedObject var model: BrowserModel

    func makeUIView(context: Context) -> WKWebView { model.web }
    func updateUIView(_ web: WKWebView, context: Context) {}
}