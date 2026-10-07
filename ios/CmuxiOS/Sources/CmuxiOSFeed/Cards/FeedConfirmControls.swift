import CmuxiOSFeatureKit
import SwiftUI

/// The poster's confirm and cancel labels; a destructive confirm is red.
struct FeedConfirmControls: View {
    let model: FeedCardModel
    let confirm: FeedConfirm
    let actions: FeedCardActions

    var body: some View {
        HStack(spacing: 8) {
            Button(confirm.cancelLabel ?? FeedText.cancel) { actions.answer(model.item.id, .confirm(false)) }
                .buttonStyle(FeedButtonStyle())
            Button(confirm.confirmLabel ?? FeedText.confirm) { actions.answer(model.item.id, .confirm(true)) }
                .buttonStyle(FeedButtonStyle(role: confirm.destructive ? .destructive : .primary))
        }
        .disabled(!model.canAnswer)
    }
}
