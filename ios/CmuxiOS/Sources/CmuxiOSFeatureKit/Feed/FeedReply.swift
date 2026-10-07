import Foundation

/// An inline answer to a feed item.
public enum FeedReply: Hashable, Sendable {
    case allow
    case deny
    case approvePlan
    case rejectPlan(feedback: String?)
    case choose(option: String)
    case text(String)
}
