import SwiftUI

/// Fenetre unique. Les deux ecrans restent montes : basculer d'un onglet a
/// l'autre ne deplace pas le `WKWebView` dans la hierarchie, ce qui evite les
/// ecrans blancs.
struct RootView: View {
    enum Tab: String, CaseIterable {
        case browser, files
        var title: String { self == .browser ? "Navigateur" : "Fichiers" }
        var symbol: String { self == .browser ? "safari.fill" : "arrow.down.doc.fill" }
    }

    @StateObject private var browser = BrowserModel()
    @ObservedObject private var store = JobStore.shared
    @State private var tab: Tab = .browser

    var body: some View {
        ZStack(alignment: .bottom) {
            FilesScreen(store: store)
                .opacity(tab == .files ? 1 : 0)
                .allowsHitTesting(tab == .files)

            BrowserScreen(model: browser)
                .opacity(tab == .browser ? 1 : 0)
                .allowsHitTesting(tab == .browser)

            tabBar
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases, id: \.self) { item in
                tabButton(item)
            }
        }
        .padding(5)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.14), radius: 16, y: 6)
        .padding(.horizontal, 60)
        .padding(.bottom, 8)
    }

    private func tabButton(_ item: Tab) -> some View {
        let on = tab == item
        let tint: Color = on ? .white : .secondary
        let count = item == .files ? store.activeCount : 0

        return Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { tab = item }
        } label: {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 4) {
                    Image(systemName: item.symbol)
                        .font(.system(size: 17, weight: .semibold))
                    Text(item.title)
                        .font(.system(size: 10, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(on ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.clear))
                )
                .foregroundStyle(tint)

                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Theme.warning))
                        .offset(x: 6, y: -4)
                }
            }
        }
        .buttonStyle(.plain)
    }
}