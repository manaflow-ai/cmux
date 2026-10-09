import CmuxiOSDesign
import CmuxiOSFeedModel
import UIKit

/// Haptic feedback for intent outcomes and selections.
@MainActor
struct FeedHaptics {
    private let haptics = Haptics()

    func prepare() {}

    func selectionChanged() {
        haptics.play(.selection)
    }

    func outcome(_ outcome: FeedIntentOutcome) {
        switch outcome {
        case .committed(let intent):
            if case .answer = intent { haptics.play(.success) }
            if case .decline = intent { haptics.play(.success) }
        case .refused:
            haptics.play(.warning)
        case .notSent:
            haptics.play(.error)
        }
    }
}
