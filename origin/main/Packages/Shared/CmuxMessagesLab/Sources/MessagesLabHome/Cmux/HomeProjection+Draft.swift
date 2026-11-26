import CmuxHomeCore
import Foundation

/// The agent's running reply on screen: MessagesLab's own received bubble,
/// aliased to the reply's key (`turn`), so the posted reply lands in it.
struct ShownDraft: Equatable {
    var turn: IdempotencyKey
    var author: ParticipantID
    var id: ID
    var text: String
    /// A draft that no longer extends the shown text gets a new bubble id.
    var generation = 0
}

/// What `ProjectionCore.draft` asks of the projection store.
struct DraftStep {
    var actions: [Action] = []
    /// The posted reply replaces its draft's text (final Markdown) in place.
    var rebuild = false
    var isEmpty: Bool { actions.isEmpty && !rebuild }
}

/// HomeStore.drafts through MessagesLab's bubble path (cx-k1uj): the first
/// text `.receive`s the agent's bubble (the typing dots turn into it), more
/// text `.appendText`s in place, the posted reply (same key) takes the
/// bubble's id and its final content, and a draft that ends without a reply
/// `.delete`s its bubble. A draft of an ended turn never reaches here
/// (HomeStore drops it), so a posted reply never gets its draft back.
extension ProjectionCore {
    /// The authors whose running reply shows (their typing dots stay off,
    /// also in the step that turns the dots into the bubble).
    func draftAuthors(_ want: HomeTurnDraft?) -> Set<ParticipantID> {
        guard let want, Self.visibleText(want) != nil else { return [] }
        return [want.participant]
    }

    /// True when `draft(_:state:)` would act.
    func draftDiffers(_ want: HomeTurnDraft?) -> Bool {
        let visible = want.flatMap { Self.visibleText($0) == nil ? nil : $0 }
        return visible?.turn != shownDraft?.turn || visible.map(\.text) != shownDraft.map(\.text)
    }

    mutating func draft(_ want: HomeTurnDraft?, state: AppState) -> DraftStep {
        var step = DraftStep()
        if let live = shownDraft, want?.turn != live.turn {
            shownDraft = nil
            if shown.contains(where: { $0.key == live.turn }) {
                step.rebuild = true
            } else {
                aliases[live.turn] = nil
                step.actions.append(.delete(live.id))
            }
        }
        // A reply already posted (a page brought it first) keeps its bubble until the draft ends.
        guard let want, let text = Self.visibleText(want), !shown.contains(where: { $0.key == want.turn }) else {
            return step
        }
        if var live = shownDraft {
            guard text != live.text else { return step }
            if text.hasPrefix(live.text) {
                step.actions.append(.appendText(live.id, String(text.dropFirst(live.text.count))))
            } else {
                step.actions.append(.delete(live.id))
                live.generation += 1
                live.id = Self.bubbleID(want.turn, generation: live.generation)
                aliases[want.turn] = live.id
                step.actions.append(.receive(bubble(want, text: text)))
            }
            live.text = text
            shownDraft = live
            return step
        }
        // An older window shows: the bubble comes with the posted reply at the newest.
        guard state.atNewest else { return step }
        let id = Self.bubbleID(want.turn, generation: 0)
        aliases[want.turn] = id
        shownDraft = ShownDraft(turn: want.turn, author: want.participant, id: id, text: text)
        step.actions.append(.receive(bubble(want, text: text)))
        return step
    }

    /// The draft's text, nil while it is only whitespace.
    private static func visibleText(_ draft: HomeTurnDraft) -> String? {
        let text = draft.text
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    private static func bubbleID(_ turn: IdempotencyKey, generation: Int) -> ID {
        "\(HomeMapping.rowSafe(turn.rawValue))~draft\(generation)"
    }

    /// The bubble the posted reply will be: the same mapping as a committed agent message.
    private func bubble(_ draft: HomeTurnDraft, text: String) -> Message {
        let item = TranscriptItem(key: draft.turn, seq: nil, author: draft.participant, parts: [.text(text)],
                                  createdAt: Date(), delivery: .committed)
        return HomeMapping.message(item, aliases: aliases, me: me, summary: summary, media: media, links: links)
    }
}
