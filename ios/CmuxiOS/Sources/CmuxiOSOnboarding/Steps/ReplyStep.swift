import SwiftUI

/// Step 3: the agent asks; a chip becomes the user's reply bubble and the
/// agent continues.
struct ReplyStep: View {
    let model: OnboardingModel
    @State private var choice: ReplyChoice?
    @Namespace private var bubbles
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        OnboardingStepScaffold(title: OnboardingText.replyTitle, message: OnboardingText.replyBody) {
            VStack(alignment: .leading, spacing: 10) {
                Label { Text(verbatim: "Codex · backend") } icon: { Image(systemName: "terminal") }
                    .font(.caption)
                    .foregroundStyle(OnboardingColors.secondaryText)
                ChatBubble(text: OnboardingText.replyQuestion, outgoing: false)
                if let choice {
                    ChatBubble(text: choice.title, outgoing: true)
                        .matchedGeometryEffect(id: choice.id, in: bubbles)
                    ChatBubble(text: choice.followUp, outgoing: false)
                        .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 8)))
                } else {
                    HStack(spacing: 10) {
                        ForEach(ReplyChoice.allCases) { option in
                            Button(option.title) { answer(option) }
                                .buttonStyle(CardButtonStyle(prominent: false))
                                .matchedGeometryEffect(id: option.id, in: bubbles)
                                .accessibilityIdentifier("onboarding.reply.\(option.rawValue)")
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(16)
            .background(OnboardingColors.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        } footer: {
            if choice == nil {
                Text(OnboardingText.replyHint)
                    .font(.footnote)
                    .foregroundStyle(OnboardingColors.secondaryText)
            }
            Button(OnboardingText.continueTitle) { model.advance() }
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .disabled(choice == nil)
                .accessibilityIdentifier("onboarding.continue")
        }
    }

    private func answer(_ option: ReplyChoice) {
        model.choose(option.rawValue)
        withAnimation(OnboardingMotion.structural(OnboardingMotion.appear)) { choice = option }
        UIAccessibility.post(notification: .announcement, argument: option.followUp)
    }
}
