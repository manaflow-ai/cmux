import CmuxiOSOnboardingCore
import SwiftUI

/// A discovered Mac with its Connect button (or progress while connecting).
struct PairCandidateRow: View {
    let candidate: PairingCandidate
    let connecting: Bool
    let onConnect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "laptopcomputer")
                .font(.title3)
                .foregroundStyle(OnboardingColors.secondaryText)
                .accessibilityHidden(true)
            Text(verbatim: candidate.name)
                .font(.body.weight(.medium))
                .foregroundStyle(OnboardingColors.primaryText)
            Spacer(minLength: 8)
            if connecting {
                ProgressView()
                    .accessibilityLabel(OnboardingText.connecting)
            } else {
                Button(OnboardingText.connect, action: onConnect)
                    .buttonStyle(CardButtonStyle(prominent: true))
                    .fixedSize()
                    .accessibilityIdentifier("onboarding.pair.connect")
            }
        }
        .padding(14)
        .background(OnboardingColors.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
