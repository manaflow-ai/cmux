public import CmuxiOSFeatureKit
import CmuxiOSFeedModel

/// Reconciles what iOS shows with the feed owner's mirror when the app comes
/// to the front (c7-notify.md section 3): the badge is the owner's count, and
/// a delivered feed banner whose item no longer needs the user goes.
public struct FeedNotificationReconciler: Hashable, Sendable {
    /// Open requests plus unread notices (C6's `FeedCounts`, feed.md 3.7).
    public let badge: Int
    private let wanted: Set<FeedItem.ID>

    public init(items: [FeedItem]) {
        badge = FeedCounts(items).badge
        wanted = Set(items.filter(Self.needsUser).map(\.id))
    }

    /// Whether an item still deserves its banner: an open request, or an
    /// unread notice that is not archived.
    public static func needsUser(_ item: FeedItem) -> Bool {
        if item.isRequest { return item.isOpenRequest }
        return !item.isRead && !item.isArchived
    }

    /// Delivered notification identifiers to remove. Only feed banners
    /// (`fi_` ids, the owner's collapse id) are touched; an item missing from
    /// the mirror was pruned or expired, so its banner goes too.
    public func staleIdentifiers(delivered: [String]) -> [String] {
        delivered.filter { $0.hasPrefix("fi_") && !wanted.contains($0) }
    }
}
