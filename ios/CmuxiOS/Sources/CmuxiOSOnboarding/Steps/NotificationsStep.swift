import CmuxiOSOnboardingCore
import SwiftUI

/// Step 5: priming before the system notifications prompt.
struct NotificationsStep: View {
    let model: OnboardingModel
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        OnboardingStepScaffold(title: OnboardingText.notificationsTitle, message: OnboardingText.notificationsBody) {
            ZStack {
                NotificationPreviewCard()
                    .scaleEffect(0.92)
                    .offset(y: 14)
                    .opacity(0.45)
                    .accessibilityHidden(true)
                NotificationPreviewCard()
                    .offset(y: shown || reduceMotion ? 0 : -16)
                    .opacity(shown ? 1 : 0)
            }
            .padding(.vertical, 24)
            .onAppear {
                withAnimation(OnboardingMotion.structural(OnboardingMotion.appear)) { shown = true }
            }
        } footer: {
            Button(OnboardingText.enableNotifications) {
                Task { _ = await model.request(.notifications) }
            }
            .buttonStyle(OnboardingPrimaryButtonStyle())
            .disabled(model.requesting != nil)
            .accessibilityIdentifier("onboarding.notifications.enable")
            Button(OnboardingText.notNow) { model.skipStep() }
                .buttonStyle(OnboardingSecondaryButtonStyle())
                .accessibilityIdentifier("onboarding.notifications.notNow")
        }
    }
}
