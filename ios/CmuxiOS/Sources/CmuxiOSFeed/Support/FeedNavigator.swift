import CmuxiOSFeatureKit
import Foundation

/// Opens a feed item from outside the Feed tab (a push tap). A request made
/// before the screen exists is parked and delivered when it attaches.
@MainActor
public final class FeedNavigator {
    private var handler: ((FeedItem.ID) -> Void)?
    private var parked: FeedItem.ID?

    public init() {}

    public func open(_ itemID: FeedItem.ID) {
        if let handler { handler(itemID) } else { parked = itemID }
    }

    func attach(_ handler: @escaping (FeedItem.ID) -> Void) {
        self.handler = handler
        if let parked {
            self.parked = nil
            handler(parked)
        }
    }

    func detach() { handler = nil }
}
