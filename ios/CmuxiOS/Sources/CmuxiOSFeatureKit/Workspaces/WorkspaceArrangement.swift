import Foundation

/// One host's workspaces with the arrangement intents applied the way the
/// owner applies them (the E3 ops). The intent log overlays with it and
/// the mock source commits with it, so both match the Mac's result.
public struct WorkspaceArrangement: Hashable, Sendable {
    public var workspaces: [WorkspaceSummary]
    public var groups: [WorkspaceGroup]

    public init(workspaces: [WorkspaceSummary], groups: [WorkspaceGroup]) {
        self.workspaces = workspaces
        self.groups = groups
    }

    /// Files `id` in `placement` at `index` among that section's other
    /// members (clamped; an empty section keeps the workspace's place), then
    /// renumbers the host order. Unknown workspaces are left alone.
    public mutating func move(_ id: WorkspaceSummary.ID, to placement: WorkspaceGroupPlacement, index: Int) {
        var ordered = workspaces.sorted { $0.order != $1.order ? $0.order < $1.order : $0.id < $1.id }
        guard let old = ordered.firstIndex(where: { $0.id == id }) else { return }
        var moving = ordered.remove(at: old)
        switch placement {
        case .keep: break
        case .ungrouped: moving.group = nil
        case .group(let groupID): moving.group = group(groupID) ?? WorkspaceGroup(id: groupID, name: groupID)
        }
        let members = ordered.indices.filter { ordered[$0].group?.id == moving.group?.id }
        let position: Int
        if members.isEmpty {
            position = min(old, ordered.count)
        } else if index < members.count {
            position = members[max(0, index)]
        } else {
            position = members[members.count - 1] + 1
        }
        ordered.insert(moving, at: position)
        for i in ordered.indices { ordered[i].order = i }
        workspaces = ordered
    }

    /// Renames the group record and every member's copy of it.
    public mutating func renameGroup(_ groupID: WorkspaceGroup.ID, to name: String) {
        for i in groups.indices where groups[i].id == groupID { groups[i].name = name }
        for i in workspaces.indices where workspaces[i].group?.id == groupID { workspaces[i].group?.name = name }
    }

    public mutating func customize(_ id: WorkspaceSummary.ID, color: WorkspaceLookChange, icon: WorkspaceLookChange) {
        guard let i = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[i].color = color.applied(to: workspaces[i].color)
        workspaces[i].icon = icon.applied(to: workspaces[i].icon)
    }

    /// A group by id: a listed group, else the copy a member carries.
    public func group(_ id: WorkspaceGroup.ID) -> WorkspaceGroup? {
        groups.first { $0.id == id } ?? workspaces.lazy.compactMap(\.group).first { $0.id == id }
    }
}
