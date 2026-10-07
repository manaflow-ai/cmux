import SwiftUI

/// The Allow / Deny pills on a tour card.
struct CardButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(prominent ? OnboardingColors.paper : OnboardingColors.primaryText)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(prominent ? OnboardingColors.ink : OnboardingColors.fill, in: Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
            .animation(configuration.isPressed ? nil : OnboardingMotion.release, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}
