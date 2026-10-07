import CmuxiOSFeedModel
import UIKit

/// Haptic feedback for intent outcomes and selections.
@MainActor
struct FeedHaptics {
    private let notification = UINotificationFeedbackGenerator()
    private let selection = UISelectionFeedbackGenerator()

    func prepare() {
        notification.prepare()
    }

    func selectionChanged() {
        selection.selectionChanged()
    }

    func outcome(_ outcome: FeedIntentOutcome) {
        switch outcome {
        case .committed(let intent):
            if case .answer = intent { notification.notificationOccurred(.success) }
            if case .decline = intent { notification.notificationOccurred(.success) }
        case .refused:
            notification.notificationOccurred(.warning)
        case .notSent:
            notification.notificationOccurred(.error)
        }
    }
}
