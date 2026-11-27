import CmuxHomeCore

/// What the conversation screen shows when the owner refuses an op the
/// transcript sent (HomeStoreBinding.onRefusal; message sends are excluded
/// there, their draft comes back instead).
struct HomeRefusalAlert: Equatable {
    var title: String
    var message: String

    init(intent: HomeIntent, rejection: HomeRejection) {
        if case .addReaction = intent.op {
            title = HomeText.tapbackFailedTitle
        } else {
            title = HomeText.actionFailedTitle
        }
        message = HomeText.explanation(for: rejection)
    }

    /// An op that ran out of resends with no answer (HomeStoreBinding.onUnanswered):
    /// it may not have gone through. One line, no refusal reason.
    init(unanswered intent: HomeIntent) {
        title = HomeText.unansweredTitle
        message = ""
    }
}
