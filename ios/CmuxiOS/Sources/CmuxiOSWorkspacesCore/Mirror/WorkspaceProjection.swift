import CmuxiOSFeatureKit
import Foundation

/// Maps the owner's wire state to the seam's value types: status and unread
/// roll up over the tabs, the preview comes from the most severe tab that
/// has one.
struct WorkspaceProjection {
    let hostID: HostID

    func summary(_ wire: WireWorkspace) -> WorkspaceSummary {
        let panes = wire.panes.map { pane in
            WorkspacePane(id: pane.id, surfaces: pane.tabs.map(surface))
        }
        let surfaces = panes.flatMap(\.surfaces)
        let status = surfaces.map(\.status).max { $0.severity < $1.severity } ?? .idle
        let previewSource = surfaces
            .filter { $0.preview?.isEmpty == false }
            .max { $0.status.severity < $1.status.severity }
        return WorkspaceSummary(
            id: wire.id, hostID: hostID, title: wire.name, status: status,
            paneCount: panes.count, unreadCount: surfaces.reduce(0) { $0 + $1.unreadCount },
            lastActivity: wire.activityAt.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) },
            panes: panes, preview: previewSource?.preview, isPinned: wire.pinned ?? false,
            group: wire.group.map { WorkspaceGroup(id: $0.id, name: $0.name) }, color: wire.color,
            order: wire.order)
    }

    private func surface(_ tab: WireTab) -> WorkspaceSurface {
        WorkspaceSurface(
            id: tab.id, kind: WorkspaceSurfaceKind(wire: tab.kind), title: tab.title, terminalID: tab.terminal,
            url: tab.url.flatMap(URL.init(string:)), status: WorkspaceStatus(wire: tab.status),
            unreadCount: max(0, tab.unread ?? 0), preview: tab.preview)
    }
}
