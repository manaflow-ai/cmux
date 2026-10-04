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
}
