import UIKit
import UserNotifications
import cmuxFeature

/// App delegate for APNs: installs the notification-center delegate, forwards
/// registered device tokens to the injected push coordinator, and routes
/// foreground presentation + taps. All push policy lives in
/// ``MobilePushCoordinator``, constructed at the app composition root and
/// injected here by `cmuxApp`.
final class CmuxAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// The app-root push coordinator, injected by `cmuxApp` at launch.
    @MainActor var pushCoordinator: MobilePushCoordinator?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in await pushCoordinator?.handleDeviceToken(deviceToken) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NSLog("cmux.push registration failed: %@", error.localizedDescription)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let ids = Self.cmuxIDs(from: notification.request.content.userInfo)
        let present = await pushCoordinator?.shouldPresentInForeground(
            workspaceId: ids.workspaceId,
            surfaceId: ids.surfaceId
        ) ?? true
        return present ? [.banner, .sound, .badge] : []
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let ids = Self.cmuxIDs(from: response.notification.request.content.userInfo)
        await pushCoordinator?.handleTap(
            workspaceId: ids.workspaceId,
            surfaceId: ids.surfaceId
        )
    }

    private nonisolated static func cmuxIDs(
        from userInfo: [AnyHashable: Any]
    ) -> (workspaceId: String?, surfaceId: String?) {
        guard let cmux = userInfo["cmux"] as? [String: Any] else { return (nil, nil) }
        return (cmux["workspaceId"] as? String, cmux["surfaceId"] as? String)
    }
}
