import SwiftUI

/// Step 4: the kept sign-in, embedded. Auth reports success to the model,
/// which advances on its own.
struct SignInStep: View {
    let model: OnboardingModel

    var body: some View {
        VStack(spacing: 8) {
            Text(OnboardingText.signInTitle)
                .font(.title.bold())
                .foregroundStyle(OnboardingColors.primaryText)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("onboarding.signIn.title")
            Text(OnboardingText.signInBody)
                .font(.body)
                .foregroundStyle(OnboardingColors.secondaryText)
            SignInHost(make: model.dependencies.signIn)
                .frame(maxWidth: 520)
        }
        .multilineTextAlignment(.center)
        .padding(.top, 16)
        .padding(.horizontal, 8)
    }
}
