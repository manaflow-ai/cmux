import CmuxHomeCore

/// The message part a tapback reacts to, and the op it sends.
///
/// The op names the message by the owner's id (`TranscriptItem.messageID`),
/// so only a committed, not retracted message with that id gets a picker: a
/// pending send, a refused send or a row without an id gets none (the client
/// never invents ids). Nothing queues, so there is no picker while offline.
struct HomeTapbackTarget: Hashable, Sendable {
    let item: IdempotencyKey
    let message: MessageID
    let conversation: ConversationID
    let partIndex: Int
    /// The tapbacks I already put on this part (shown selected).
    let chosen: Set<Reaction.Tapback>

    init?(item: TranscriptItem, partIndex: Int, conversation: ConversationID, me: ParticipantID, isOnline: Bool) {
        guard isOnline, Self.accepts(item), let message = item.messageID,
              item.parts.indices.contains(partIndex) else { return nil }
        self.item = item.key
        self.message = message
        self.conversation = conversation
        self.partIndex = partIndex
        chosen = Set(item.reactions.compactMap { reaction in
            guard reaction.author == me, reaction.partIndex == partIndex,
                  case .tapback(let tapback) = reaction.kind else { return nil }
            return tapback
        })
    }

    /// Whether a message can take a reaction at all (before a part is known).
    static func accepts(_ item: TranscriptItem) -> Bool {
        item.messageID != nil && item.delivery == .committed && !item.isRetracted
    }

    /// The op for a choice; nil when I already gave that tapback (the owner
    /// keeps one of each, and there is no op that removes one).
    func op(_ tapback: Reaction.Tapback) -> HomeOp? {
        guard !chosen.contains(tapback) else { return nil }
        return .addReaction(message: message, conversation: conversation, reaction: .tapback(tapback), partIndex: partIndex)
    }
}

extension Reaction.Tapback {
    /// The picker's glyph; the same glyphs the render core draws as badges.
    var glyph: String {
        switch self {
        case .love: "\u{2764}\u{FE0F}"
        case .like: "\u{1F44D}"
        case .dislike: "\u{1F44E}"
        case .laugh: "\u{1F602}"
        case .emphasize: "\u{203C}\u{FE0F}"
        case .question: "\u{2753}"
        }
    }

    var accessibilityName: String {
        switch self {
        case .love: HomeText.tapbackLove
        case .like: HomeText.tapbackLike
        case .dislike: HomeText.tapbackDislike
        case .laugh: HomeText.tapbackLaugh
        case .emphasize: HomeText.tapbackEmphasize
        case .question: HomeText.tapbackQuestion
        }
    }
}
