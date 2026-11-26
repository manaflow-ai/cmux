import Foundation

// HomeStore's conversation hooks: the views that hear refusals and
// unanswered ops for a conversation. HomeConversationHookRegistry owns them.
extension HomeStore {
    // MARK: Conversation hooks

    /// A view of `hooks.conversation` hears that conversation's refusals and
    /// unanswered ops nobody awaits until `unregister`, or until it is freed
    /// (the store holds it weakly). Registering it again does nothing.
    public func register(_ hooks: HomeConversationHooks) {
        hookRegistry.register(hooks)
    }

    /// The view stopped: it hears nothing more. Unregistering hooks that are
    /// not registered does nothing.
    public func unregister(_ hooks: HomeConversationHooks) {
        hookRegistry.unregister(hooks)
    }

    /// Drops the entries of `conversation`'s hooks that were freed without
    /// `unregister` (a binding's deinit calls it).
    public func pruneHooks(for conversation: ConversationID) {
        hookRegistry.prune(conversation)
    }

    /// A refusal nobody awaits: each live view of its conversation hears it
    /// once; with none, `onRefusal` does.
    func reportRefusal(_ intent: HomeIntent, _ rejection: HomeRejection) {
        let live = hookRegistry.liveHooks(for: intent)
        guard !live.isEmpty else { onRefusal?(intent, rejection); return }
        for hooks in live { hooks.onRefusal(intent, rejection) }
    }

    /// An op that ran out of resends: each live view of its conversation
    /// hears it once; with none, `onUnanswered` does.
    func reportUnanswered(_ intent: HomeIntent) {
        let live = hookRegistry.liveHooks(for: intent)
        guard !live.isEmpty else { onUnanswered?(intent); return }
        for hooks in live { hooks.onUnanswered(intent) }
    }

    /// Hook entries the store holds now, live or freed and not yet pruned (tests).
    var registeredHookCount: Int { hookRegistry.count }
}
