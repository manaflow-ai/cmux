import CmuxiOSApp
import UIKit

/// The app target's only code: process and scene entry. Everything else lives
/// in the CmuxiOS package (plans/cmux-next/ios-rewrite.md).
@main
final class CmuxAppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        CmuxiOSApplication.prepare()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        CmuxiOSApplication.didRegisterForRemoteNotifications(deviceToken: deviceToken)
    }

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
        // Cold launch from a link or universal link; the router defers it
        // until the account is ready.
        for context in connectionOptions.urlContexts { CmuxiOSApplication.open(context.url) }
        for activity in connectionOptions.userActivities { CmuxiOSApplication.continue(activity) }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts { CmuxiOSApplication.open(context.url) }
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        CmuxiOSApplication.continue(userActivity)
    }
}
