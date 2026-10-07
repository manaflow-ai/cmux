import SwiftUI

/// Step 1: the live vignette and the two ways in.
struct WelcomeStep: View {
    let model: OnboardingModel

    var body: some View {
        OnboardingStepScaffold(title: OnboardingText.welcomeTitle, message: OnboardingText.welcomeBody) {
            TerminalVignette()
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        } footer: {
            Button(OnboardingText.getStarted) {
                model.choose("getStarted")
                model.advance()
            }
            .buttonStyle(OnboardingPrimaryButtonStyle())
            .accessibilityIdentifier("onboarding.welcome.start")
            Button(OnboardingText.haveAccount) {
                model.choose("haveAccount")
                model.skipIntro()
            }
            .buttonStyle(OnboardingSecondaryButtonStyle())
            .accessibilityIdentifier("onboarding.welcome.haveAccount")
        }
    }
}
