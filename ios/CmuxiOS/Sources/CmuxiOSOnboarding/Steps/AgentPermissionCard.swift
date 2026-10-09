import SwiftUI

/// A permission request as the Feed shows it, answerable inline.
struct AgentPermissionCard: View {
    let onAnswer: (ApproveChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label { Text(verbatim: "Claude Code · cmux") } icon: { Image(systemName: "terminal") }
                .font(.caption)
                .foregroundStyle(OnboardingColors.secondaryText)
            Text(OnboardingText.approveCardTitle)
                .font(.headline)
                .foregroundStyle(OnboardingColors.primaryText)
            Text(OnboardingText.approveCardBody)
                .font(.subheadline)
                .foregroundStyle(OnboardingColors.secondaryText)
            HStack(spacing: 10) {
                Button(OnboardingText.deny) { onAnswer(.deny) }
                    .buttonStyle(CardButtonStyle(prominent: false))
                    .accessibilityIdentifier("onboarding.approve.deny")
                Button(OnboardingText.allow) { onAnswer(.allow) }
                    .buttonStyle(CardButtonStyle(prominent: true))
                    .accessibilityIdentifier("onboarding.approve.allow")
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OnboardingColors.raisedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.1), radius: 10, y: 3)
        .accessibilityElement(children: .contain)
    }
}
