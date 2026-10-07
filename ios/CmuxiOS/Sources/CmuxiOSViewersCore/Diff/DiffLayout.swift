/// How a diff is laid out.
public enum DiffLayout: String, Hashable, Sendable, CaseIterable {
    /// One column, removals above additions.
    case unified
    /// Old on the left, new on the right; paired lines share a row.
    case split
}
