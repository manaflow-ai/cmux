import CmuxHomeCore
import UIKit

/// One transcript row ready to draw: the store's item plus the grouping
/// decisions (author name on the first bubble of a run, avatar on the last).
struct TranscriptDisplayItem: Hashable, Sendable {
    var item: TranscriptItem
    var isOutgoing: Bool
    var author: Participant?
    var showsAuthorName: Bool
    var showsAvatar: Bool
    /// Reserve the avatar column (incoming bubbles in groups).
    var reservesAvatarSpace: Bool
    /// True when the previous bubble has another author (a larger gap above).
    var startsRun: Bool
    var isLastOutgoing: Bool

    var key: IdempotencyKey { item.key }
}

/// What a transcript renderer draws and reports. The interim renderer in
/// this module implements it; the shared rendering core can replace it
/// without touching the conversation screen, the store or the composer.
@MainActor
protocol TranscriptPresenting: AnyObject {
    /// The renderer's root view; the conversation screen sizes and places it.
    var view: UIView { get }
    var delegate: (any TranscriptPresenterDelegate)? { get set }
    /// True while the newest message is (nearly) visible.
    var isNearBottom: Bool { get }

    /// Shows the transcript. Items keep their ids across pending and
    /// committed states, so a renderer updates them in place.
    func show(_ items: [TranscriptDisplayItem], typingNames: [String], hasOlder: Bool)
    /// Scrolls so the message is visible. False when it is not loaded.
    @discardableResult
    func scroll(to key: IdempotencyKey, animated: Bool) -> Bool
    func scrollToBottom(animated: Bool)
}

@MainActor
protocol TranscriptPresenterDelegate: AnyObject {
    /// The user scrolled near the oldest loaded message.
    func transcriptNeedsOlderMessages()
    func transcriptRetry(_ key: IdempotencyKey)
    func transcriptDiscard(_ key: IdempotencyKey)
}

/// Pure derivation of display items from store items.
enum TranscriptGrouping {
    static func items(_ items: [TranscriptItem], me: ParticipantID, isGroup: Bool,
                      participant: (ParticipantID) -> Participant?) -> [TranscriptDisplayItem] {
        let lastOutgoing = items.lastIndex { $0.author == me }
        return items.indices.map { index in
            let item = items[index]
            let outgoing = item.author == me
            let previous = index > 0 ? items[index - 1].author : nil
            let next = index + 1 < items.count ? items[index + 1].author : nil
            let startsRun = previous != item.author
            let endsRun = next != item.author
            let incomingInGroup = isGroup && !outgoing
            return TranscriptDisplayItem(
                item: item,
                isOutgoing: outgoing,
                author: participant(item.author),
                showsAuthorName: incomingInGroup && startsRun,
                showsAvatar: incomingInGroup && endsRun,
                reservesAvatarSpace: incomingInGroup,
                startsRun: startsRun,
                isLastOutgoing: index == lastOutgoing
            )
        }
    }

    /// Committed messages from others that appeared at the end since the
    /// previous render, for VoiceOver announcements.
    static func newIncoming(previous: [TranscriptDisplayItem], current: [TranscriptDisplayItem]) -> [TranscriptDisplayItem] {
        guard let lastPrevious = previous.last?.key,
              let start = current.lastIndex(where: { $0.key == lastPrevious }) else { return [] }
        return current[(start + 1)...].filter { !$0.isOutgoing && $0.item.delivery == .committed }
    }
}
