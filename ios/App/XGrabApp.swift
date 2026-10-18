import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Installe le journal avant tout le reste : une erreur fatale survenue
    /// ensuite laisse une trace de la derniere etape.
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
        Task { @MainActor in
            DownloadEngine.shared.backgroundCompletionHandler = completionHandler
        }
    }
}

@main
struct XGrabApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}