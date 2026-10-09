import SwiftUI

/// A quiet text button under the primary one.
struct OnboardingSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(OnboardingColors.primaryText)
            .frame(maxWidth: .infinity, minHeight: 44)
            .opacity(isEnabled ? (configuration.isPressed ? 0.5 : 1) : 0.3)
            .contentShape(Rectangle())
    }
}
