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

    public init(ops: any CloudOpsSending, topic: String, environment: CloudOp.APNsEnvironment) {
        self.ops = ops
        self.topic = topic
        self.environment = environment
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
        self.token = token
        let op = CloudOp.registerPushTarget(token: token, topic: topic, environment: environment,
                                            deviceName: UIDevice.current.name,
                                            idempotencyKey: "push-register-" + UUID().uuidString.lowercased())
        state = await send(op) ? .registered : state
    }

    /// Sign-out: the account stops pushing to this device.
    public func signOut() async {
        guard let token else { return }
        _ = await send(.removePushTarget(token: token, idempotencyKey: "push-remove-" + UUID().uuidString.lowercased()))
        self.token = nil
        state = .idle
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
