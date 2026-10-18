import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Installe le journal de crash avant tout le reste : une erreur
    /// fatale survenue ensuite laisse une trace de la derniere etape.
    override init() {
        super.init()
        CrashLog.install()
        CrashLog.step("demarrage de l'app")
    }

    /// iOS reveille le processus quand une session en arriere-plan finit :
    /// sans ce relais, l'app serait tuee avant d'avoir range les fichiers.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        Downloader.shared.backgroundCompletionHandler = completionHandler
    }
}

@main
struct XGrabApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var tab: Tab = .browser

    enum Tab: String, CaseIterable {
        case browser, files

        var title: String {
            switch self {
            case .browser: return "Navigateur"
            case .files: return "Fichiers"
            }
        }

        var symbol: String {
            switch self {
            case .browser: return "safari.fill"
            case .files: return "arrow.down.doc.fill"
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ZStack(alignment: .bottom) {
                // Le navigateur occupe tout l'ecran : la barre se pose par-dessus.
                Group {
                    switch tab {
                    case .browser: BrowserView()
                    case .files: DownloadsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                tabBar
                    .padding(.horizontal, 60)
                    .padding(.bottom, 8)
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases, id: \.rawValue) { item in
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                        tab = item
                    }
                } label: {
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
                            .fill(tab == item ? Theme.accentGradient : Color.clear)
                    )
                    .foregroundStyle(tab == item ? .white : .secondary)
                    .shadow(color: Theme.accent.opacity(tab == item ? 0.35 : 0), radius: 8, y: 4)
                }
                .buttonStyle(.plain)
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
    }
}