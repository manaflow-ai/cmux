import Foundation

struct CmuxWorkspaceTree: Decodable, Sendable {
    let workspaces: [CmuxWorkspace]

    func selectedSurface() -> UInt64? {
        guard let workspace = workspaces.first,
              let screen = workspace.screens.first(where: \.active) ?? workspace.screens.first,
              let pane = screen.panes.first(where: { $0.id == screen.activePane })
                ?? screen.panes.first(where: { !$0.dead })
        else {
            return nil
        }

        if pane.tabs.indices.contains(pane.activeTab) {
            let active = pane.tabs[pane.activeTab]
            if active.kind == "pty", !active.dead {
                return active.surface
            }
        }

        return pane.tabs.first(where: { $0.kind == "pty" && !$0.dead })?.surface
    }
}
