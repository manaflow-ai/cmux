import CNAppShell
import UIKit

/// UIKit entry point: the shell's scene delegate owns the window and its root
/// hosting controller (status bar style, URL contexts, foreground events).
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default", sessionRole: session.role)
        configuration.delegateClass = CmuxNextSceneDelegate.self
        return configuration
    }
}
