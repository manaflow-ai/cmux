import CmuxiOSOnboardingCore
import SwiftUI

/// Step 7: priming before the local network prompt.
struct LocalNetworkStep: View {
    let model: OnboardingModel

    var body: some View {
        OnboardingStepScaffold(title: OnboardingText.localNetworkTitle, message: OnboardingText.localNetworkBody) {
            HStack(spacing: 16) {
                Image(systemName: "iphone")
                Image(systemName: "ellipsis")
                    .font(.title3)
                    .foregroundStyle(OnboardingColors.tertiaryText)
                Image(systemName: "wifi")
                Image(systemName: "ellipsis")
                    .font(.title3)
                    .foregroundStyle(OnboardingColors.tertiaryText)
                Image(systemName: "laptopcomputer")
            }
            .font(.system(size: 40, weight: .light))
            .foregroundStyle(OnboardingColors.secondaryText)
            .padding(.vertical, 32)
            .accessibilityHidden(true)
        } footer: {
            Button(OnboardingText.allowLocalNetwork) {
                Task { _ = await model.request(.localNetwork) }
            }
            .buttonStyle(OnboardingPrimaryButtonStyle())
            .disabled(model.requesting != nil)
            .accessibilityIdentifier("onboarding.localNetwork.allow")
            Button(OnboardingText.notNow) { model.skipStep() }
                .buttonStyle(OnboardingSecondaryButtonStyle())
                .accessibilityIdentifier("onboarding.localNetwork.notNow")
        }
    }
}
