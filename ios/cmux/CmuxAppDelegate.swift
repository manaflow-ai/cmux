import CMUXMobileCore
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
    /// The app-root analytics emitter, injected by `cmuxApp` at launch.
    @MainActor var analytics: (any AnalyticsEmitting)?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let launchedFromPush = launchOptions?[.remoteNotification] != nil
        // `analytics` is assigned in `cmuxApp.init()` which runs before
        // `didFinishLaunchingWithOptions`, so the emitter is available here.
        analytics?.capture("ios_app_launched", [
            "launch_type": .string("cold"),
            "launched_from": .string(launchedFromPush ? "push" : "normal"),
        ])
        return true
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
        let nsError = error as NSError
        Task { @MainActor in
            analytics?.capture("ios_push_token_registration_failed", [
                "stage": .string("apns"),
                "error_code": .int(nsError.code),
                "error_domain": .string(nsError.domain),
            ])
        }
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
        let appState = await UIApplication.shared.applicationState
        await analytics?.capture("ios_push_tapped", [
            "has_workspace_id": .bool(ids.workspaceId != nil),
            "has_surface_id": .bool(ids.surfaceId != nil),
            "app_state": .string(Self.appStateLabel(appState)),
        ])
        await pushCoordinator?.handleTap(
            workspaceId: ids.workspaceId,
            surfaceId: ids.surfaceId
        )
    }

    @MainActor
    private static func appStateLabel(_ state: UIApplication.State) -> String {
        switch state {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    private nonisolated static func cmuxIDs(
        from userInfo: [AnyHashable: Any]
    ) -> (workspaceId: String?, surfaceId: String?) {
        guard let cmux = userInfo["cmux"] as? [String: Any] else { return (nil, nil) }
        return (cmux["workspaceId"] as? String, cmux["surfaceId"] as? String)
    }
}
