import CmuxiOSFeatureKit
import SwiftUI

/// Approve, or Request Changes with a comment (composer).
struct FeedPlanControls: View {
    let model: FeedCardModel
    let actions: FeedCardActions

    var body: some View {
        HStack(spacing: 8) {
            Button(FeedText.requestChanges) { actions.compose(.planChanges(itemID: model.item.id)) }
                .buttonStyle(FeedButtonStyle())
            Button(FeedText.approvePlan) { actions.answer(model.item.id, .plan(approved: true, comment: nil)) }
                .buttonStyle(FeedButtonStyle(role: .primary))
        }
        .disabled(!model.canAnswer)
    }
}
