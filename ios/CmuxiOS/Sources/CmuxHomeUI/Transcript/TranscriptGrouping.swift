import CmuxHomeCore

extension Array where Element == TranscriptItem {
    /// Display items: author name on the first bubble of a run and the
    /// avatar on the last, both only for incoming bubbles in groups.
    func displayItems(me: ParticipantID, isGroup: Bool,
                      participant: (ParticipantID) -> Participant?) -> [TranscriptDisplayItem] {
        let lastOutgoing = lastIndex { $0.author == me }
        return indices.map { index in
            let item = self[index]
            let outgoing = item.author == me
            let previous = index > 0 ? self[index - 1].author : nil
            let next = index + 1 < count ? self[index + 1].author : nil
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
}

extension Array where Element == TranscriptDisplayItem {
    /// Committed messages from others that appeared at the end since
    /// `previous` was shown, for VoiceOver announcements.
    func newIncoming(since previous: [TranscriptDisplayItem]) -> [TranscriptDisplayItem] {
        guard let lastPrevious = previous.last?.key,
              let start = lastIndex(where: { $0.key == lastPrevious }) else { return [] }
        return self[(start + 1)...].filter { !$0.isOutgoing && $0.item.delivery == .committed }
    }
}
