import CmuxiOSOnboardingCore
import SwiftUI

/// Optional step after SSH (lane C12, behind `cloudOnboarding`): create the
/// first Cloud machine through the app's hook, or skip.
struct CloudMachineStep: View {
    let model: OnboardingModel
    @State private var creating = false
    @State private var error: String?

    var body: some View {
        OnboardingStepScaffold(title: CloudStepText.title, message: CloudStepText.body) {
            VStack(spacing: 18) {
                Image(systemName: "cloud")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(OnboardingColors.secondaryText)
                    .accessibilityHidden(true)
                if creating {
                    ProgressView()
                }
                if let error {
                    Text(verbatim: error)
                        .font(.footnote)
                        .foregroundStyle(OnboardingColors.secondaryText)
                        .multilineTextAlignment(.center)
                }
            }
        } footer: {
            Button(CloudStepText.create) { Task { await create() } }
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .disabled(creating || model.dependencies.cloud == nil)
                .accessibilityIdentifier("onboarding.cloud.create")
            Button(OnboardingText.skip) { model.skipStep() }
                .buttonStyle(OnboardingSecondaryButtonStyle())
                .accessibilityIdentifier("onboarding.cloud.skip")
        }
    }

    private func create() async {
        guard let hook = model.dependencies.cloud else { return }
        creating = true
        error = nil
        let outcome = await hook.createFirstMachine()
        creating = false
        switch outcome {
        case .created:
            model.choose("created")
            model.advance()
        case .refused(let message):
            error = message
        }
    }
}
