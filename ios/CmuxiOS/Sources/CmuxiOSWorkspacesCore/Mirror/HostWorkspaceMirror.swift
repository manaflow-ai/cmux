public import CmuxiOSFeatureKit
public import CmuxMobileWire
import Foundation

/// The confirmed mirror of one host's `workspace:<host>` stream, written
/// only by owner frames (OWNERSHIP-PRINCIPLES "Clients are projections").
/// An event applies only when `seq == mirror.seq + 1`; anything else that is
/// not a duplicate is a gap and the mirror waits for a snapshot.
public struct HostWorkspaceMirror: Sendable {
    /// The owner seq this mirror reflects; nil before the first snapshot.
    public private(set) var seq: UInt64?
    /// True after a gap until the next snapshot.
    public private(set) var needsSnapshot = false
    private(set) var workspaces: [WireWorkspace] = []

    public init() {}

    public var hasSnapshot: Bool { seq != nil }

    /// The confirmed workspaces in the owner's order.
    public func summaries(hostID: HostID) -> [WorkspaceSummary] {
        let projection = WorkspaceProjection(hostID: hostID)
        return workspaces.map(projection.summary)
    }

    /// Replaces the mirror with the owner's state at the snapshot's seq.
    /// A malformed state leaves the mirror unchanged and throws.
    public mutating func apply(_ snapshot: SnapshotFrame) throws {
        let state = try snapshot.state.decode(as: WireWorkspaceState.self)
        // Ids are unique per owner; a duplicate keeps its first copy so rows
        // stay uniquely identified.
        var seen = Set<String>()
        workspaces = state.workspaces.filter { seen.insert($0.id).inserted }.sorted { $0.order < $1.order }
        seq = snapshot.seq
        needsSnapshot = false
    }

    public mutating func apply(_ event: EventFrame) -> MirrorEventResult {
        guard let seq else { return .awaitingSnapshot }
        if event.seq <= seq { return .duplicate }
        if needsSnapshot { return .gap }
        guard event.seq == seq + 1, (try? reduce(event)) != nil else {
            needsSnapshot = true
            return .gap
        }
        self.seq = event.seq
        return .applied
    }

    /// Marks the mirror stale (for example when the owner's socket returns
    /// and the stream must be re-read); rows keep their last state.
    public mutating func invalidate() { needsSnapshot = true }

    // MARK: Reducer

    private mutating func reduce(_ event: EventFrame) throws {
        switch event.op {
        case "workspace.upsert":
            let workspace = try event.params.decode(as: WorkspaceUpsertParams.self).workspace
            if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
                workspaces[index] = workspace
            } else {
                workspaces.append(workspace)
            }
            workspaces.sort { $0.order < $1.order }
        case "workspace.remove":
            let id = try event.params.decode(as: WorkspaceRefParams.self).workspace
            workspaces.removeAll { $0.id == id }
        case "workspace.tab.upsert":
            try upsertTab(event.params.decode(as: TabUpsertParams.self))
        case "workspace.tab.remove":
            let id = try event.params.decode(as: TabRefParams.self).tab
            editTab(id) { _, pane, index in pane.tabs.remove(at: index) }
            // Invariant 2: the owner removes an emptied pane in the same
            // commit; the wire has no pane event, so the mirror drops it.
            for w in workspaces.indices { workspaces[w].panes.removeAll { $0.tabs.isEmpty } }
        case "workspace.status.set":
            let params = try event.params.decode(as: TabStatusParams.self)
            editTab(params.tab) { _, pane, index in
                pane.tabs[index].status = params.status
                pane.tabs[index].unread = params.unread
            }
        case "workspace.preview.set":
            let params = try event.params.decode(as: TabPreviewParams.self)
            editTab(params.tab) { _, pane, index in pane.tabs[index].preview = params.preview }
        default:
            // An op of the family this client does not know (a newer Mac):
            // receivers ignore unknown messages and keep the sequence.
            break
        }
    }

    private mutating func upsertTab(_ params: TabUpsertParams) throws {
        guard let w = workspaces.firstIndex(where: { $0.id == params.workspace }) else {
            throw MirrorInconsistency()
        }
        // A tab moves when it is upserted into another pane (conservation).
        for p in workspaces[w].panes.indices { workspaces[w].panes[p].tabs.removeAll { $0.id == params.tab.id } }
        if let p = workspaces[w].panes.firstIndex(where: { $0.id == params.pane }) {
            let index = min(max(0, params.index), workspaces[w].panes[p].tabs.count)
            workspaces[w].panes[p].tabs.insert(params.tab, at: index)
        } else {
            workspaces[w].panes.append(WirePane(id: params.pane, tabs: [params.tab]))
        }
        workspaces[w].panes.removeAll { $0.tabs.isEmpty }
    }

    /// Runs `edit` on the pane holding tab `id`; an unknown tab is ignored
    /// (the owner may report status for a tab whose upsert this mirror
    /// replaced with a newer snapshot).
    private mutating func editTab(_ id: String, _ edit: (Int, inout WirePane, Int) -> Void) {
        for w in workspaces.indices {
            for p in workspaces[w].panes.indices {
                if let index = workspaces[w].panes[p].tabs.firstIndex(where: { $0.id == id }) {
                    edit(w, &workspaces[w].panes[p], index)
                    return
                }
            }
        }
    }
}
