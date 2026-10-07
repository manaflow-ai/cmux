import Foundation

/// The list as one value: sections, plus why it is empty.
public struct WorkspaceListSnapshot: Hashable, Sendable {
    public var sections: [WorkspaceListSection]
    public var emptyState: WorkspaceListEmptyState?
    /// Every listed machine is unreachable.
    public var allOffline: Bool

    public var rows: [WorkspaceListRow] { sections.flatMap(\.rows) }
}
