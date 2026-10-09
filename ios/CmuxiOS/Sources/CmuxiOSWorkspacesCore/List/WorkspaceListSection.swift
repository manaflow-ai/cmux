public import CmuxiOSFeatureKit

/// A list section. The first section of a machine carries its header;
/// later sections of the same machine carry only a title (Pinned, a group
/// name, Workspaces).
public struct WorkspaceListSection: Identifiable, Hashable, Sendable {
    /// `host:<id>/<part>` or `flat`.
    public var id: String
    public var hostID: HostID?
    public var machine: WorkspaceMachineHeader?
    public var kind: WorkspaceListSectionKind
    public var rows: [WorkspaceListRow]
    /// A group collapsed on this phone: `rows` is empty, `memberCount` says
    /// how many it holds.
    public var isCollapsed: Bool = false
    /// Workspaces in the section, listed or collapsed.
    public var memberCount: Int = 0
    /// What the host accepts (Rename Group needs `.renameGroup`).
    public var capabilities: WorkspaceCapabilities = []
    public var isReachable: Bool = false
}
