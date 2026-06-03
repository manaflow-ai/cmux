#if os(iOS)
import CmuxMobileAuth
import CmuxMobileShell
import CmuxMobileShellModel
import Foundation
import UIKit
import UserNotifications

/// Bridges APNs push between the app-target ``AppDelegate`` and the mobile shell
/// store: drives opt-in registration, hands device tokens to
/// ``NotificationManager``, and routes foreground presentation + taps to the
/// active ``CMUXMobileShellStore`` for "mirror macOS" suppression and deep-link.
///
/// A shared coordinator is the seam between the UIApplication delegate (which
/// must own `UNUserNotificationCenterDelegate`) and the per-scene store.
@MainActor
public final class MobilePushCoordinator {
    // Construction-at-root injection (build at CMUXMobileRootScene, inject into
    // CmuxAppDelegate + WorkspaceViews) is coupled to the auth/push wave: every
    // method here funnels through NotificationManager.shared, which the next step
    // deletes. Invert together with that singleton so push policy is not churned
    // across two waves.
    // TRANSITIONAL — push singleton inverts with the auth/push wave (see above).
    public static let shared = MobilePushCoordinator()

    private weak var store: CMUXMobileShellStore?

    private init() {}

    /// Whether the user has opted into phone notifications.
    public var isEnabled: Bool { NotificationManager.shared.isEnabled }

    /// Point routing at the active store (called by the root view on appear).
    public func bind(store: CMUXMobileShellStore) {
        self.store = store
    }

    /// Install the notification-center delegate and, if already opted in,
    /// re-assert remote registration so a rotated token re-uploads. Call once at
    /// launch from the AppDelegate.
    public func configure(delegate: UNUserNotificationCenterDelegate) {
        UNUserNotificationCenter.current().delegate = delegate
        if isEnabled {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// Opt in: request system authorization, register for remote notifications,
    /// and persist the flag. Returns whether authorization was granted.
    @discardableResult
    public func enable() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else { return false }
        await NotificationManager.shared.setEnabled(true)
        UIApplication.shared.registerForRemoteNotifications()
        return true
    }

    /// Opt out: stop receiving pushes and remove the token server-side.
    public func disable() async {
        await NotificationManager.shared.setEnabled(false)
        UIApplication.shared.unregisterForRemoteNotifications()
    }

    /// Hand a freshly-registered APNs token to the network layer.
    public func handleDeviceToken(_ token: Data) async {
        await NotificationManager.shared.register(deviceToken: token)
    }

    /// Whether to show a banner while the app is foreground. Suppressed when the
    /// user is already viewing the terminal the notification is about. Takes
    /// plain strings (extracted by the AppDelegate) to avoid passing the
    /// non-`Sendable` `userInfo` across the actor boundary.
    public func shouldPresentInForeground(workspaceId: String?, surfaceId: String?) -> Bool {
        guard let store, let workspaceId,
              store.selectedWorkspaceID?.rawValue == workspaceId else {
            return true
        }
        if let surfaceId {
            return store.selectedTerminalID?.rawValue != surfaceId
        }
        return false
    }

    /// Deep-link to the workspace/terminal a tapped notification refers to.
    public func handleTap(workspaceId: String?, surfaceId: String?) {
        guard let store else { return }
        if let workspaceId {
            store.selectedWorkspaceID = MobileWorkspacePreview.ID(rawValue: workspaceId)
        }
        if let surfaceId {
            store.selectTerminal(MobileTerminalPreview.ID(rawValue: surfaceId))
        }
    }
}
#endif
