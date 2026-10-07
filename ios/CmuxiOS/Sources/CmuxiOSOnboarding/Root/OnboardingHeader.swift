import CmuxiOSOnboardingCore
import SwiftUI

/// Back, the progress bar, and Skip (tour pages and the install step) or
/// Close (replay).
struct OnboardingHeader: View {
    let model: OnboardingModel

    var body: some View {
        HStack(spacing: 12) {
            Button {
                model.back()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .opacity(model.flow.canGoBack ? 1 : 0)
            .disabled(!model.flow.canGoBack)
            .accessibilityLabel(OnboardingText.back)
            .accessibilityHidden(!model.flow.canGoBack)
            .accessibilityIdentifier("onboarding.back")

            OnboardingProgressBar(position: model.flow.position)

            trailing
                .frame(minWidth: 44, minHeight: 44)
        }
        .foregroundStyle(OnboardingColors.primaryText)
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private var trailing: some View {
        if model.mode == .replay {
            Button(OnboardingText.close) { model.close() }
                .accessibilityIdentifier("onboarding.close")
        } else if model.flow.canSkipIntro {
            Button(OnboardingText.skip) {
                model.choose("skipIntro")
                model.skipIntro()
            }
            .accessibilityIdentifier("onboarding.skip")
        } else if model.flow.current == .installMac {
            Button(OnboardingText.skip) { model.skipStep() }
                .accessibilityIdentifier("onboarding.skip")
        } else {
            Color.clear.frame(width: 44, height: 44)
        }
    }
}
