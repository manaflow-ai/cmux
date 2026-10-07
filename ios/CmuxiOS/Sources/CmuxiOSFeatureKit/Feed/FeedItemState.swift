import Foundation

/// Lifecycle (feed.md 3.6). Answered, cancelled and expired are final.
public enum FeedItemState: String, Hashable, Sendable, CaseIterable {
    case open
    case answered
    case cancelled
    case expired
}
