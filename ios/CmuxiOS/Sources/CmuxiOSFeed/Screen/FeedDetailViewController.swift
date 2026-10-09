import CmuxiOSFeatureKit
import SwiftUI
import UIKit

/// The full item: the expanded card with the same inline controls. The feed
/// screen pushes new models into it on every change.
@MainActor
final class FeedDetailViewController: UIHostingController<FeedDetailView> {
    let itemID: FeedItem.ID

    init(model: FeedCardModel, actions: FeedCardActions) {
        itemID = model.item.id
        super.init(rootView: FeedDetailView(model: model, actions: actions))
        title = model.item.title
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder aDecoder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ model: FeedCardModel) {
        guard model != rootView.model else { return }
        rootView = FeedDetailView(model: model, actions: rootView.actions)
    }
}
