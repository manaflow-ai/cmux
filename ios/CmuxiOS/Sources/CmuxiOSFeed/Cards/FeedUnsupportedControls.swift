import CmuxiOSFeatureKit
import SwiftUI

/// A request the phone cannot answer: says where to answer it; Decline stays.
struct FeedUnsupportedControls: View {
    let model: FeedCardModel
    let needsMac: Bool
    let actions: FeedCardActions

    var body: some View {
        HStack(spacing: 8) {
            Label(needsMac ? FeedText.answerOnMac : FeedText.openOnMac, systemImage: "desktopcomputer")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(FeedText.decline) { actions.decline(model.item.id) }
                .buttonStyle(FeedButtonStyle(role: .destructive))
                .disabled(!model.canDecline)
        }
    }
}
