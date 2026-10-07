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
}
