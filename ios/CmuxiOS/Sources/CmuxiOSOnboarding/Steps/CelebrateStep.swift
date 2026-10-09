import SwiftUI

/// Step 10: the first-success moment.
struct CelebrateStep: View {
    let model: OnboardingModel
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        OnboardingStepScaffold(title: title, message: message) {
            ZStack {
                CelebrationBurst()
                    .frame(width: 320, height: 260)
                Circle()
                    .fill(OnboardingColors.surface)
                    .frame(width: 120, height: 120)
                Image(systemName: "checkmark")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundStyle(OnboardingColors.success)
                    .scaleEffect(shown || reduceMotion ? 1 : 0.6)
                    .opacity(shown ? 1 : 0)
            }
            .frame(height: 220)
            .accessibilityHidden(true)
            .onAppear {
                withAnimation(OnboardingMotion.structural(OnboardingMotion.appear)) { shown = true }
            }
        } footer: {
            Button(model.mode == .replay ? OnboardingText.done : OnboardingText.openCmux) { model.advance() }
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .accessibilityIdentifier("onboarding.finish")
        }
    }

    private var connected: Bool { model.pairedMacName != nil || model.flow.context.hasTrustedMac }

    private var title: String {
        connected ? OnboardingText.celebratePairedTitle : OnboardingText.celebrateTitle
    }

    private var message: String {
        if model.mode == .replay { return OnboardingText.celebrateReplayBody }
        if let name = model.pairedMacName { return OnboardingText.celebratePairedBody(name) }
        return connected ? OnboardingText.celebrateReadyBody : OnboardingText.celebrateBody
    }
}
