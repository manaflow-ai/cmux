import CmuxiOSFeatureKit
import SwiftUI

/// Suggestion chips (each sends at once) and Reply (opens the composer).
struct FeedQuestionControls: View {
    let model: FeedCardModel
    let question: FeedQuestion
    let actions: FeedCardActions

    var body: some View {
        FeedFlowLayout {
            ForEach(question.suggestions, id: \.self) { suggestion in
                Button(suggestion) { actions.answer(model.item.id, .text(suggestion)) }
                    .buttonStyle(FeedChipStyle(isSelected: false))
                    .accessibilityIdentifier("feed.suggestion." + suggestion)
            }
            Button {
                actions.compose(.questionReply(itemID: model.item.id, prompt: question.question))
            } label: {
                Label(FeedText.reply, systemImage: "arrowshape.turn.up.left")
            }
            .buttonStyle(FeedButtonStyle(role: .primary))
            .accessibilityIdentifier("feed.action.reply")
        }
        .disabled(!model.canAnswer)
    }
}
