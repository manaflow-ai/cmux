import Foundation

/// The list as one value: sections, plus why it is empty.
public struct WorkspaceListSnapshot: Hashable, Sendable {
    public var sections: [WorkspaceListSection]
    public var emptyState: WorkspaceListEmptyState?
    /// Every listed machine is unreachable.
    public var allOffline: Bool

    public init(sections: [WorkspaceListSection], emptyState: WorkspaceListEmptyState?, allOffline: Bool) {
        self.sections = sections
        self.emptyState = emptyState
        self.allOffline = allOffline
    }

    public var rows: [WorkspaceListRow] { sections.flatMap(\.rows) }
}
