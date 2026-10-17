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

    var body: some Scene {
        WindowGroup {
            TabView {
                DownloadsView()
                    .tabItem { Label("Fichiers", systemImage: "arrow.down.circle") }

                BrowserView()
                    .tabItem { Label("Navigateur", systemImage: "safari") }

                ContentView()
                    .tabItem { Label("PC", systemImage: "desktopcomputer") }
            }
            .onAppear { drainPending() }
        }
    }

    /// L'extension depose les liens dans le conteneur partage ; on les recupere
    /// des que l'app est affichee.
    private func drainPending() {
        CrashLog.step("drainPending")
        for request in PendingQueue.drain() {
            for url in request.urls {
                Downloader.shared.enqueue(url: url, referer: request.referer)
            }
        }
    }
}