import SwiftUI

/// The layout every step shares: a visual, a title and message, and a footer
/// pinned above the home indicator. Scrolls at large Dynamic Type sizes.
struct OnboardingStepScaffold<Visual: View, Footer: View>: View {
    let title: String
    let message: String
    @ViewBuilder var visual: Visual
    @ViewBuilder var footer: Footer

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                visual
                VStack(spacing: 10) {
                    Text(title)
                        .font(.title.bold())
                        .foregroundStyle(OnboardingColors.primaryText)
                        .accessibilityAddTraits(.isHeader)
                    Text(message)
                        .font(.body)
                        .foregroundStyle(OnboardingColors.secondaryText)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) { footer }
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .background(OnboardingColors.paper)
        }
    }
}
