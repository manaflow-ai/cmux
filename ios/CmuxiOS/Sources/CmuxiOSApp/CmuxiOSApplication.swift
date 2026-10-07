public import UIKit
import CmuxiOSPlatform

/// Entry points the app target's thin `@main` delegate calls.
@MainActor
public enum CmuxiOSApplication {
    /// Builds the root view controller for a new window scene.
    public static func makeRootViewController() -> UIViewController {
        RootViewController(container: container)
    }

    /// Call from `application(_:didFinishLaunchingWithOptions:)` so the
    /// notification delegate exists before a cold-start banner tap arrives.
    public static func prepare() { _ = container }

    public static func didRegisterForRemoteNotifications(deviceToken: Data) {
        Task { await container.push.didRegister(token: deviceToken) }
    }

    /// A background push (`content-available`): the feed owner's dismiss and
    /// badge (c7-notify.md section 3). Returns whether it carried new data.
    public static func didReceiveRemoteNotification(_ userInfo: [AnyHashable: Any]) async -> Bool {
        await container.remoteNotifications.handle(userInfo)
    }

    /// A URL the scene received (scheme or universal link). Returns false
    /// for links this build does not understand.
    @discardableResult
    public static func open(_ url: URL) -> Bool {
        container.router.open(url) != .unrecognized
    }

    /// A continued user activity (universal links arrive as browsing activities).
    @discardableResult
    public static func `continue`(_ activity: NSUserActivity) -> Bool {
        guard activity.activityType == NSUserActivityTypeBrowsingWeb, let url = activity.webpageURL else { return false }
        return open(url)
    }

    private static let container = AppContainer()
}
