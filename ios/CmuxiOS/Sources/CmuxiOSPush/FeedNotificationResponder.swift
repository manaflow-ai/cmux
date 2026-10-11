public import CmuxFeedPushCore
public import Foundation
public import UserNotifications

/// Turns a banner action into `feed.answer` (origin `user`) and a tap into
/// "open this item" (FeedPushResponse decides; this only performs it).
@MainActor
public final class FeedNotificationResponder {
    private let ops: any CloudOpsSending
    private let reader: (any FeedItemReading)?
    /// Opens a feed item in the app.
    public var openItem: ((String) -> Void)?
    /// Shows the approve sheet for an agent's permission request a Mac posted
    /// (cx-aocz), with the scope the banner action asked for.
    public var presentApprove: ((FeedApproveRequest, String) -> Void)?

    public init(ops: any CloudOpsSending, reader: (any FeedItemReading)? = nil) {
        self.ops = ops
        self.reader = reader
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

    private enum ApproveRead { case request(FeedApproveRequest), plain, unknown }

    private static func approveRequest(_ reader: any FeedItemReading, _ item: String) async -> ApproveRead {
        do {
            return try await reader.approveRequest(item: item).map(ApproveRead.request) ?? .plain
        } catch {
            return .unknown
        }
    }

    public func handle(_ decision: FeedPushResponse) async {
        switch decision {
        case .ignore:
            return
        case .open(let item):
            openItem?(item)
        case .send(let key):
            // An allow for an agent's permission request a Mac posted needs the
            // presence-key proof: the banner opens the approve sheet instead,
            // where the person sees what they allow. A deny goes as it is.
            if case .decision(true, let scope) = key.answer, let reader {
                switch await Self.approveRequest(reader, key.item) {
                case .request(let request):
                    if let presentApprove { presentApprove(request, scope ?? "once") } else { openItem?(key.item) }
                    return
                case .unknown:
                    // Not read: never send an unsigned allow that may need a proof.
                    openItem?(key.item)
                    return
                case .plain:
                    break
                }
            }
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
