public import CmuxiOSFeatureKit

/// Turns a drop in the list into the owner's `move` intent (pure).
///
/// The list hides pinned workspaces from their group's section and may hide
/// collapsed ones, while the owner's index counts every member of the
/// destination section. So the drop is described by the visible row it
/// landed before (`before`, nil = the end of the section) and resolved
/// against the host's full order here.
public struct WorkspaceReorder: Sendable {
    public var host: HostWorkspaces

    public init(host: HostWorkspaces) { self.host = host }

    /// Whether the list may offer reordering at all with these preferences.
    public static func isAvailable(_ preferences: WorkspaceViewPreferences) -> Bool {
        preferences.grouping == .byMachine && preferences.sort == .ownerOrder && preferences.filter == .all
    }

    /// Whether `workspace` may be dragged: a reachable host that accepts
    /// moves, and not a pinned workspace (pins order themselves).
    public func canMove(_ workspace: WorkspaceSummary.ID) -> Bool {
        guard host.isReachable, host.capabilities.contains(.move),
              let summary = host.workspaces.first(where: { $0.id == workspace }) else { return false }
        return !summary.isPinned
    }

    /// The intent for dropping `workspace` into `target` right before
    /// `before`; nil when nothing would change or the drop is not allowed.
    public func intent(moving workspace: WorkspaceSummary.ID, to target: WorkspaceDropTarget,
                       before: WorkspaceSummary.ID?) -> WorkspaceIntent? {
        guard canMove(workspace), let moving = host.workspaces.first(where: { $0.id == workspace }) else { return nil }
        let destination: String?
        switch target {
        case .ungrouped: destination = nil
        case .group(let id):
            guard host.groups.contains(where: { $0.id == id }) || host.workspaces.contains(where: { $0.group?.id == id }) else {
                return nil
            }
            destination = id
        }
        let members = host.workspaces.sorted { $0.order != $1.order ? $0.order < $1.order : $0.id < $1.id }
            .filter { $0.id != workspace && $0.group?.id == destination }
        let index: Int
        if let before, let position = members.firstIndex(where: { $0.id == before }) {
            index = position
        } else {
            index = members.count
        }
        let placement: WorkspaceGroupPlacement
        if moving.group?.id == destination {
            // Same section: a no-op when it lands where it already is.
            let current = host.workspaces.sorted { $0.order != $1.order ? $0.order < $1.order : $0.id < $1.id }
                .filter { $0.group?.id == destination }
            if let old = current.firstIndex(where: { $0.id == workspace }), old == index { return nil }
            placement = .keep
        } else {
            placement = destination.map(WorkspaceGroupPlacement.group) ?? .ungrouped
        }
        return .move(workspaceID: workspace, group: placement, index: index)
    }
}
