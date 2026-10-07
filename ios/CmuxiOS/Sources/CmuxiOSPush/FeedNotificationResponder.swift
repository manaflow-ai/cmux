public import CmuxFeedPushCore
public import CmuxiOSNotifyCore
import Foundation
public import UserNotifications

/// Performs banner responses (c7-notify.md section 2): an action becomes a
/// C6 feed intent sent under a background task, a tap opens the item. The
/// decision itself is `FeedPushResponse` (pure, tested); this only runs it.
@MainActor
public final class FeedNotificationResponder {
    private let performer: any FeedIntentPerforming
    private let budget = BackgroundTaskBudget(name: "cmux.feed.banner-action")
    /// Opens a feed item in the app.
    public var openItem: ((String) -> Void)?

    public init(performer: any FeedIntentPerforming) {
        self.performer = performer
    }

    /// Reads a response into a Sendable decision (call where it arrives).
    nonisolated public static func decision(for response: UNNotificationResponse) -> FeedPushResponse {
        let content = response.notification.request.content
        return FeedPushResponse(
            actionIdentifier: response.actionIdentifier,
            userText: (response as? UNTextInputNotificationResponse)?.userText,
            categoryIdentifier: content.categoryIdentifier,
            userInfo: content.userInfo)
    }

    public func handle(_ decision: FeedPushResponse) async {
        switch decision {
        case .ignore:
            return
        case .open(let item):
            openItem?(item)
        case .perform(let intent):
            let performer = self.performer
            let outcome = await budget.run {
                do {
                    return BannerActionOutcome(receipt: try await performer.perform(intent.feedIntent, key: intent.intentKey))
                } catch {
                    return BannerActionOutcome(error: error)
                }
            }
            await present(outcome, for: intent.item)
        }
    }

    private func present(_ outcome: BannerActionOutcome, for item: String) async {
        let center = UNUserNotificationCenter.current()
        if outcome.removesBanner { center.removeDeliveredNotifications(withIdentifiers: [item]) }
        switch outcome {
        case .committed:
            return
        case .answeredElsewhere:
            await post(identifier: "cmux.feed.answered-elsewhere.\(item)",
                       title: String(localized: "push.answeredElsewhere.title", defaultValue: "Answered elsewhere", bundle: .module),
                       body: String(localized: "push.answeredElsewhere.body", defaultValue: "Another device answered this first.", bundle: .module))
        case .notSent:
            // Not sent: say so on the lock screen; the item stays open on the owner.
            await post(identifier: "cmux.feed.not-sent",
                       title: String(localized: "push.notSent.title", defaultValue: "Answer not sent", bundle: .module),
                       body: String(localized: "push.notSent.body", defaultValue: "Open cmux to answer.", bundle: .module))
            openItem?(item)
        }
    }

    private func post(identifier: String, title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.interruptionLevel = .passive
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
}
