public import CmuxiOSFeatureKit
import Foundation

/// One list section: its kind and item ids in display order.
public struct FeedSection: Hashable, Sendable, Identifiable {
    public var kind: FeedSectionKind
    public var itemIDs: [FeedItem.ID]

    public init(kind: FeedSectionKind, itemIDs: [FeedItem.ID]) {
        self.kind = kind
        self.itemIDs = itemIDs
    }

    /// Stable id for the diffable snapshot.
    public var id: String {
        switch kind {
        case .needsInput: "needs-input"
        case .earlier: "earlier"
        case .workspace(let id, _): "ws:" + (id ?? "-")
        case .agent(let agent): "agent:" + (agent ?? "-")
        }
    }
}
