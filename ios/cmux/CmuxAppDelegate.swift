import CmuxiOSApp
import UIKit

/// The app target's only code: process and scene entry. Everything else lives
/// in the CmuxiOS package (plans/cmux-next/ios-rewrite.md).
@main
final class CmuxAppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = CmuxSceneDelegate.self
        return configuration
    }
}

final class CmuxSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = CmuxiOSApplication.makeRootViewController()
        window.makeKeyAndVisible()
        self.window = window
    }
}
