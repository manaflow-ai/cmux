public import CmuxiOSFeatureKit
import Foundation

/// Badge counts (feed.md 3.7): open requests plus unread notices.
public struct FeedCounts: Hashable, Sendable {
    public var openRequests: Int
    public var unreadNotices: Int

    public init(_ items: [FeedItem]) {
        openRequests = items.filter { $0.isOpenRequest && !$0.isArchived }.count
        unreadNotices = items.filter { !$0.isRequest && !$0.isRead && !$0.isArchived }.count
    }

    public var badge: Int { openRequests + unreadNotices }
}
