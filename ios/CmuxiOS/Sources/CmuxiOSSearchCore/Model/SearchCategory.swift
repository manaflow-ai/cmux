/// Result groups, in their fixed tie-break order.
public enum SearchCategory: Int, Hashable, Sendable, CaseIterable, Comparable {
    case actions
    case workspaces
    case tabs
    case feed
    case hosts
    case settings

    public static func < (lhs: SearchCategory, rhs: SearchCategory) -> Bool { lhs.rawValue < rhs.rawValue }
}
