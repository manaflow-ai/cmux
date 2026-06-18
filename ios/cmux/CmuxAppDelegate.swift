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
        let request = response.notification.request
        // A swipe/clear of a cmux banner delivers the custom dismiss action
        // (enabled via the `cmux.terminal` category's `.customDismissAction`).
        // Forward it to the Mac so the desktop banner + store entry clear too.
        if response.actionIdentifier == UNNotificationDismissActionIdentifier {
            await pushCoordinator?.handleDismiss(
                notificationId: Self.notificationID(from: request)
            )
            return
        }
        // A tap (default action) deep-links to the workspace/terminal AND marks
        // the notification read on the Mac, mirroring the Mac's own tap path
        // (which opens + marks read). The two compose: deep-link locally, clear
        // on the Mac.
        let ids = Self.cmuxIDs(from: request.content.userInfo)
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
        await pushCoordinator?.handleDismiss(
            notificationId: Self.notificationID(from: request)
        )
    }

    /// Silent dismiss push (the cold lane of Mac→iOS dismiss-sync): the Mac
    /// cleared notifications and sent every registered device a
    /// `content-available` push carrying the dismissed ids (idempotent no-op if
    /// this device already handled the live peer event). The system applies
    /// the authoritative badge from `aps.badge` without waking us; when iOS
    /// grants the background wake — strictly budgeted, a handful per hour at
    /// best — we also remove the matching delivered banners. Anything iOS
    /// defers is healed by the reconcile sweep on the next app open/attach.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        let dismissedIds = Self.dismissedIDs(from: userInfo)
        guard !dismissedIds.isEmpty else { return .noData }
        await pushCoordinator?.handleRemoteDismiss(ids: dismissedIds)
        return .newData
    }

    private nonisolated static func dismissedIDs(from userInfo: [AnyHashable: Any]) -> [String] {
        guard let cmux = userInfo["cmux"] as? [String: Any],
              let ids = cmux["dismissedIds"] as? [String] else {
            return []
        }
        return ids
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
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

    /// The stable Mac-side notification id for a delivered request, or `nil` when
    /// this push does not carry one.
    ///
    /// The `cmux.notificationId` payload key is authoritative: the Mac stamps the
    /// same value as `apns-collapse-id`, so it equals `request.identifier` for a
    /// modern push. We deliberately do NOT fall back to a bare `request.identifier`
    /// when the payload key is absent: a push without `notificationId` (an older
    /// Mac, or any push that omitted it) has an OS-assigned random identifier that
    /// matches no Mac notification, so forwarding it would mark the wrong (or no)
    /// notification read. Returning `nil` degrades cleanly to "no dismiss-sync".
    private nonisolated static func notificationID(from request: UNNotificationRequest) -> String? {
        guard let cmux = request.content.userInfo["cmux"] as? [String: Any],
              let id = (cmux["notificationId"] as? String)?.trimmingCharacters(in: .whitespaces),
              !id.isEmpty else {
            return nil
        }
        return id
    }
}
