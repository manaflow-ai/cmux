import SwiftUI

/// A thin capsule filled to the current step of the steps that apply.
struct OnboardingProgressBar: View {
    let position: (index: Int, total: Int)

    var body: some View {
        let fraction = position.total > 0 ? CGFloat(position.index + 1) / CGFloat(position.total) : 0
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(OnboardingColors.track)
                Capsule().fill(OnboardingColors.ink)
                    .frame(width: max(6, proxy.size.width * fraction))
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel(OnboardingText.progress(position.index + 1, position.total))
        .accessibilityIdentifier("onboarding.progress")
    }
}
