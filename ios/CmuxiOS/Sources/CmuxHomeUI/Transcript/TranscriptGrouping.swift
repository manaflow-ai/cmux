import CmuxHomeCore

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
