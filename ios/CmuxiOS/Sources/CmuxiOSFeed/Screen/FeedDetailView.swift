import SwiftUI

/// The detail screen's content: the expanded card in a scroll view.
struct FeedDetailView: View {
    let model: FeedCardModel
    let actions: FeedCardActions

    var body: some View {
        ScrollView {
            FeedCardView(model: model, actions: actions)
                .padding()
                .frame(maxWidth: 700, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("feed.detail")
    }
}
