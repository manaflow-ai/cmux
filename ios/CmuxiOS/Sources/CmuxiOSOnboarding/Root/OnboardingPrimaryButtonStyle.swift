import SwiftUI

/// Ink on paper (inverted in dark mode), full width, instant press scale.
struct OnboardingPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(OnboardingColors.paper)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 16)
            .background(OnboardingColors.ink, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(isEnabled ? 1 : 0.3)
            .scaleEffect(configuration.isPressed && !reduceMotion ? OnboardingMotion.pressScale : 1)
            .animation(configuration.isPressed ? nil : OnboardingMotion.release, value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}
