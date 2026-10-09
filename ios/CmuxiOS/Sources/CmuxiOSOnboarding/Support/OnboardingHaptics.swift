import CmuxiOSDesign
import UIKit

/// Onboarding's haptics: light on advance, selection on a chip, success on
/// approve, paired and celebrate, warning on a pairing failure.
@MainActor
final class OnboardingHaptics {
    private let haptics = Haptics()

    func prepare() {}

    func advance() { haptics.play(.lightImpact) }
    func select() { haptics.play(.selection) }
    func success() { haptics.play(.success) }
    func warning() { haptics.play(.warning) }
}
