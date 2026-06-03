#if os(iOS)
import CmuxAuthRuntime
import CmuxMobileShell
import CmuxMobileShellModel
import Foundation
import Observation
import UIKit
import UserNotifications

/// Bridges APNs push between the app-target `AppDelegate` and the mobile shell
/// store: drives opt-in registration, hands device tokens to the injected
/// ``CmuxAuthRuntime/PushRegistrationService``, and routes foreground
/// presentation + taps to the active ``CMUXMobileShellStore`` for "mirror macOS"
/// suppression and deep-link.
///
/// The coordinator is the seam between the `UIApplicationDelegate` (which must
/// own `UNUserNotificationCenterDelegate`) and the per-scene store. Constructed
/// once at the composition root with an injected push-registration service and
/// injected into the SwiftUI environment + the app delegate; no singleton.
@MainActor
@Observable
public final class MobilePushCoordinator {
    private let registration: any PushRegistering
    // UserDefaults is Apple-documented thread-safe; a synchronous read mirrors
    // the opt-in flag for the menu UI without awaiting the actor service.
    private nonisolated(unsafe) let defaults: UserDefaults
    private static let enabledKey = "cmux.notifications.pushEnabled"

    @ObservationIgnored private weak var store: CMUXMobileShellStore?

    /// Creates a push coordinator.
    /// - Parameters:
    ///   - registration: The injected push-registration service.
    ///   - defaults: The store backing the opt-in flag (must match the suite the
    ///     registration service uses). Defaults to `.standard`.
    public init(registration: any PushRegistering, defaults: UserDefaults = .standard) {
        self.registration = registration
        self.defaults = defaults
    }

    /// Whether the user has opted into phone notifications (synchronous mirror).
    public var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    /// Point routing at the active store (called by the root view on appear).
    public func bind(store: CMUXMobileShellStore) {
        self.store = store
    }

    /// Install the notification-center delegate and, if already opted in,
    /// re-assert remote registration so a rotated token re-uploads. Call once at
    /// launch from the AppDelegate.
    public func configure(delegate: any UNUserNotificationCenterDelegate) {
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
        await registration.setEnabled(true)
        UIApplication.shared.registerForRemoteNotifications()
        return true
    }

    /// Opt out: stop receiving pushes and remove the token server-side.
    public func disable() async {
        await registration.setEnabled(false)
        UIApplication.shared.unregisterForRemoteNotifications()
    }

    /// Hand a freshly-registered APNs token to the network layer.
    public func handleDeviceToken(_ token: Data) async {
        await registration.register(deviceToken: token)
    }

    /// Re-upload the cached token when possible (e.g. after sign-in).
    public func syncTokenIfPossible() async {
        await registration.syncTokenIfPossible()
    }

    /// Remove the cached token from the server (on sign-out).
    public func unregisterFromServer() async {
        await registration.unregisterFromServer()
    }

    /// Whether to show a banner while the app is foreground. Suppressed when the
    /// user is already viewing the terminal the notification is about.
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
