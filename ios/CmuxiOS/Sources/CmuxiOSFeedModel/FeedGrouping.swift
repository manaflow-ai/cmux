import Foundation

/// How the list groups items (client view state).
public enum FeedGrouping: String, CaseIterable, Hashable, Sendable {
    /// "Needs input" then "Earlier".
    case none
    case workspace
    case agent
}
