import SwiftUI

/// Step 2: learn by doing. The user answers a real-looking permission
/// request; the terminal reacts and Continue unlocks.
struct ApproveStep: View {
    let model: OnboardingModel
    @State private var choice: ApproveChoice?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        OnboardingStepScaffold(title: OnboardingText.approveTitle, message: OnboardingText.approveBody) {
            VStack(spacing: 14) {
                MiniTerminal {
                    Text(verbatim: "● Editing Sources/Auth/Session.swift")
                        .foregroundStyle(OnboardingColors.secondaryText)
                    if let choice {
                        Text(verbatim: "● \(choice == .allow ? OnboardingText.allowedReceipt : OnboardingText.deniedReceipt) · swift test")
                            .foregroundStyle(OnboardingColors.secondaryText)
                            .transition(.opacity)
                        resultLine(choice)
                            .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 6)))
                    } else {
                        Text(verbatim: "● Waiting for approval")
                            .foregroundStyle(OnboardingColors.waiting)
                    }
                }
                if choice == nil {
                    AgentPermissionCard { answer($0) }
                        .transition(.scale(scale: reduceMotion ? 1 : 0.94).combined(with: .opacity))
                }
            }
        } footer: {
            if choice == nil {
                Text(OnboardingText.approveHint)
                    .font(.footnote)
                    .foregroundStyle(OnboardingColors.secondaryText)
            }
            Button(OnboardingText.continueTitle) { model.advance() }
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .disabled(choice == nil)
                .accessibilityIdentifier("onboarding.continue")
        }
    }

    @ViewBuilder
    private func resultLine(_ choice: ApproveChoice) -> some View {
        switch choice {
        case .allow:
            HStack(spacing: 6) {
                Text(verbatim: "✓").foregroundStyle(OnboardingColors.success)
                Text(OnboardingText.resultAllowed).foregroundStyle(OnboardingColors.primaryText)
            }
        case .deny:
            Text(OnboardingText.resultDenied).foregroundStyle(OnboardingColors.primaryText)
        }
    }

    private func answer(_ answer: ApproveChoice) {
        model.choose(answer.rawValue)
        if answer == .allow { model.haptics.success() }
        withAnimation(OnboardingMotion.structural(OnboardingMotion.collapse)) { choice = answer }
        UIAccessibility.post(notification: .announcement,
                             argument: answer == .allow ? OnboardingText.resultAllowed : OnboardingText.resultDenied)
    }
}
