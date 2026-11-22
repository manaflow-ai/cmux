public import CmuxFeedPushCore
public import Foundation
import UIKit
import UserNotifications

/// Owns this install's push target on the account (UserDO): asks for
/// permission after sign-in, registers the APNs token with
/// `push.target.register` as the signed-in user's install, and removes it as
/// THAT user's install on sign-out (or when the account changes). A removal
/// that does not reach the owner is kept with its user and retried.
@MainActor
public final class PushRegistration {
    public enum State: Hashable, Sendable {
        case idle
        case denied
        case registered
        /// Not sent: the reason.
        case pending(String)
    }

    private struct PendingRemoval: Codable { var token: Data; var user: String }

    public private(set) var state: State = .idle
    private let ops: any CloudOpsSending
    private let topic: String
    private let environment: CloudOp.APNsEnvironment
    private let defaults: UserDefaults
    private var token: Data?
    /// The Stack user whose install registered `token`.
    private var owner: String?
    private static let pendingKey = "cmux.push.pendingRemovals"

    public init(ops: any CloudOpsSending, topic: String, environment: CloudOp.APNsEnvironment,
                defaults: UserDefaults = .standard) {
        self.ops = ops
        self.topic = topic
        self.environment = environment
        self.defaults = defaults
    }

    /// After sign-in of `user`: categories, permission, then an APNs token.
    public func start(for user: String) async {
        owner = user
        await retryPendingRemovals()
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories(FeedPushCategory.notificationCategories)
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else { state = .denied; return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// APNs answered with this install's token.
    public func didRegister(token: Data) async {
        guard let owner else { return }
        self.token = token
        let op = CloudOp.registerPushTarget(token: token, topic: topic, environment: environment,
                                            deviceName: UIDevice.current.name,
                                            idempotencyKey: "push-register-" + UUID().uuidString.lowercased())
        do {
            try await ops.send(op, as: owner)
            state = .registered
        } catch {
            state = .pending("\(error)")
        }
    }

    /// `user` signs out (or another account replaced it): the account stops
    /// pushing to this device. Runs before the identity forgets that user.
    public func signOut(of user: String) async {
        let token = self.token
        if owner == user {
            owner = nil
            self.token = nil
            state = .idle
            UIApplication.shared.unregisterForRemoteNotifications()
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        }
        guard let token else { return }
        var pending = loadPending()
        pending.append(PendingRemoval(token: token, user: user))
        savePending(pending)
        await retryPendingRemovals()
    }

    /// Sends every kept removal as its own user's install.
    public func retryPendingRemovals() async {
        var remaining: [PendingRemoval] = []
        for removal in loadPending() {
            do {
                try await ops.send(.removePushTarget(token: removal.token,
                                                     idempotencyKey: "push-remove-\(removal.user)-\(removal.token.hexString)"),
                                   as: removal.user)
            } catch CloudOpsError.rejected(_, retryable: false) {
                // That account no longer has this target: done.
            } catch {
                remaining.append(removal)
            }
        }
        savePending(remaining)
    }

    private func loadPending() -> [PendingRemoval] {
        defaults.data(forKey: Self.pendingKey).flatMap { try? JSONDecoder().decode([PendingRemoval].self, from: $0) } ?? []
    }

    private func savePending(_ value: [PendingRemoval]) {
        if value.isEmpty { defaults.removeObject(forKey: Self.pendingKey) }
        else { defaults.set(try? JSONEncoder().encode(value), forKey: Self.pendingKey) }
    }
}
