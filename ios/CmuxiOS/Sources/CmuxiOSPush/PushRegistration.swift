public import CmuxFeedPushCore
public import Foundation
import UIKit
import UserNotifications

/// Owns this install's push target on the account (UserDO): asks for
/// permission after sign-in, registers the APNs token with
/// `push.target.register`, and removes it on sign-out. The owner keeps one
/// target per install; registering again replaces it.
@MainActor
public final class PushRegistration {
    public enum State: Hashable, Sendable {
        case idle
        case denied
        case registered
        /// Not sent: the reason (for example no install principal yet).
        case pending(String)
    }

    public private(set) var state: State = .idle
    private let ops: any CloudOpsSending
    private let topic: String
    private let environment: CloudOp.APNsEnvironment
    private var token: Data?
    private let defaults: UserDefaults
    /// A token whose removal did not reach the owner yet (sign-out while
    /// offline): retried at launch and before the next register, so a signed-out
    /// account never keeps pushing to this phone.
    private static let pendingRemovalKey = "cmux.push.pendingRemoval"

    public init(ops: any CloudOpsSending, topic: String, environment: CloudOp.APNsEnvironment,
                defaults: UserDefaults = .standard) {
        self.ops = ops
        self.topic = topic
        self.environment = environment
        self.defaults = defaults
        Task { await self.retryPendingRemoval() }
    }

    /// After sign-in: register the categories, ask once, then ask APNs for a token.
    public func start() async {
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories(FeedPushCategory.notificationCategories)
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else { state = .denied; return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// APNs answered with this install's token.
    public func didRegister(token: Data) async {
        await retryPendingRemoval()
        self.token = token
        let op = CloudOp.registerPushTarget(token: token, topic: topic, environment: environment,
                                            deviceName: UIDevice.current.name,
                                            idempotencyKey: "push-register-" + UUID().uuidString.lowercased())
        if await send(op) { state = .registered }
    }

    /// Sign-out: the account stops pushing to this device.
    public func signOut() async {
        // Take the token before any await: a sign-in during the removal must
        // not have its new token cleared by this sign-out.
        guard let token else { return }
        self.token = nil
        state = .idle
        UIApplication.shared.unregisterForRemoteNotifications()
        defaults.set(token, forKey: Self.pendingRemovalKey)
        await retryPendingRemoval()
    }

    private func retryPendingRemoval() async {
        guard let pending = defaults.data(forKey: Self.pendingRemovalKey) else { return }
        do {
            try await ops.send(.removePushTarget(token: pending, idempotencyKey: "push-remove-" + pending.hexString))
            defaults.removeObject(forKey: Self.pendingRemovalKey)
        } catch CloudOpsError.rejected(_, retryable: false) {
            // The owner no longer has this target: nothing left to remove.
            defaults.removeObject(forKey: Self.pendingRemovalKey)
        } catch {
            // Kept; retried at the next launch or registration.
        }
    }

    private func send(_ op: CloudOp) async -> Bool {
        do {
            try await ops.send(op)
            return true
        } catch CloudOpsError.installTokenUnavailable {
            state = .pending("no install principal yet")
        } catch {
            state = .pending("\(error)")
        }
        return false
    }
}
