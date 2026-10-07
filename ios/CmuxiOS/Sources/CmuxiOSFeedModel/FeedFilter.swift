public import CmuxiOSFeatureKit
import Foundation

/// The list filter (client view state). Archived and snoozed items never show.
public enum FeedFilter: String, CaseIterable, Hashable, Sendable {
    case needsInput
    case unread
    case all

    public func includes(_ item: FeedItem) -> Bool {
        guard !item.isArchived, !item.isSnoozed else { return false }
        switch self {
        case .needsInput: return item.isOpenRequest
        case .unread: return !item.isRead || item.isOpenRequest
        case .all: return true
        }
    }
}
