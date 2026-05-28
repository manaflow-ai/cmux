import UIKit
import BackgroundTasks
import UserNotifications
import CmuxKit

/// UIKit-side glue we can't (yet) express purely in SwiftUI: notification
/// delegate hook, BG task registration, key-command catalog at the responder
/// chain head, and Live Activity push-token forwarding.
///
/// Inherits `UIResponder` (not bare `NSObject`) so the `keyCommands` /
/// `buildMenu(with:)` / `canPerformAction(_:withSender:)` overrides resolve
/// against the real superclass — UIApplicationDelegate is a protocol and
/// provides none of those.
final class CmuxRemoteAppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = NotificationCenterBridge.shared
        NotificationCategories.installAll()
        CmuxRemoteIntentHandlers.install()
        BGScheduler.shared.register()
        return true
    }

    // Multi-scene config — Stage Manager / external display support.
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }

    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .main else { return }
        KeyboardShortcutCatalog.installMenu(into: builder)
    }

    // App-wide key commands appear in the iPad ⌘-discoverability HUD; they
    // route through KeyboardShortcutBus so SwiftUI views can react.
    override var keyCommands: [UIKeyCommand]? {
        KeyboardShortcutCatalog.appLevelCommands()
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if KeyboardShortcutCatalog.handles(action) { return true }
        return super.canPerformAction(action, withSender: sender)
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
}
