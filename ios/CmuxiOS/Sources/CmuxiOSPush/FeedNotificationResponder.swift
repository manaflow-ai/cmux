public import CmuxFeedPushCore
public import Foundation
public import UserNotifications

/// Turns a banner action into `feed.answer` (origin `user`) and a tap into
/// "open this item" (FeedPushResponse decides; this only performs it).
@MainActor
public final class FeedNotificationResponder {
    private let ops: any CloudOpsSending
    /// Opens a feed item in the app.
    public var openItem: ((String) -> Void)?

    public init(ops: any CloudOpsSending) {
        self.ops = ops
    }

    /// Reads a response into a Sendable decision (call where it arrives).
    nonisolated public static func decision(for response: UNNotificationResponse) -> FeedPushResponse {
        FeedPushResponse(
            actionIdentifier: response.actionIdentifier,
            userText: (response as? UNTextInputNotificationResponse)?.userText,
            userInfo: response.notification.request.content.userInfo)
    }

    private static func postNotSent() async {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "push.notSent.title", defaultValue: "Answer not sent", bundle: .module)
        content.body = String(localized: "push.notSent.body", defaultValue: "Open cmux to answer.", bundle: .module)
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "cmux.feed.not-sent", content: content, trigger: nil))
    }

    public func handle(_ decision: FeedPushResponse) async {
        switch decision {
        case .ignore:
            return
        case .open(let item):
            openItem?(item)
        case .send(let key):
            do {
                try await ops.send(key.op)
            } catch {
                // Not sent: say so on the lock screen; the item stays open on the owner.
                await Self.postNotSent()
                openItem?(key.item)
            }
        }
    }
}
