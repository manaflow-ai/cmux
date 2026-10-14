import CNAppShell
import UIKit

/// UIKit entry point: the shell's scene delegate owns the window and its root
/// hosting controller (status bar style, URL contexts, foreground events).
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Upgrades from the SwiftUI-lifecycle builds restore a scene session
        // that names SwiftUI's scene delegate; adopt it instead of a black window.
        CmuxNextSceneDelegate.adoptScenesWithForeignDelegates()
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default", sessionRole: session.role)
        configuration.delegateClass = CmuxNextSceneDelegate.self
        return configuration
    }
}
