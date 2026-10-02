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
                // Not sent (offline, or no install principal yet): show the item instead.
                openItem?(key.item)
            }
        }
    }
}
