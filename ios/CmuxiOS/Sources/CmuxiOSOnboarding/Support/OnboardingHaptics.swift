import UIKit

/// Onboarding's haptics: light on advance, selection on a chip, success on
/// approve, paired and celebrate, warning on a pairing failure.
@MainActor
final class OnboardingHaptics {
    private let impact = UIImpactFeedbackGenerator(style: .light)
    private let selection = UISelectionFeedbackGenerator()
    private let notification = UINotificationFeedbackGenerator()

    func prepare() {
        impact.prepare()
        selection.prepare()
        notification.prepare()
    }

    func advance() { impact.impactOccurred() }
    func select() { selection.selectionChanged() }
    func success() { notification.notificationOccurred(.success) }
    func warning() { notification.notificationOccurred(.warning) }
}
