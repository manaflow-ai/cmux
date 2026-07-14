import Foundation

struct CmuxWorkspaceTree: Decodable, Sendable {
    let workspaces: [CmuxWorkspace]

    func selectedSurface() -> UInt64? {
        guard let workspace = workspaces.first(where: \.active) ?? workspaces.first,
              let screen = workspace.screens.first(where: \.active) ?? workspace.screens.first
        else { return nil }
        return activeSurface(in: screen)?.surface
    }

    func surface(workspace workspaceID: UInt64, screen screenID: UInt64) -> UInt64? {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }),
              let screen = workspace.screens.first(where: { $0.id == screenID })
        else { return nil }
        return activeSurface(in: screen)?.surface
    }

    func pane(workspace workspaceID: UInt64, screen screenID: UInt64) -> CmuxPane? {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }),
              let screen = workspace.screens.first(where: { $0.id == screenID })
        else { return nil }
        return activePane(in: screen)
    }

    func location(of surface: UInt64) -> (workspace: UInt64, screen: UInt64)? {
        for workspace in workspaces {
            for screen in workspace.screens where screen.panes.contains(where: {
                $0.tabs.contains(where: { $0.surface == surface })
            }) {
                return (workspace.id, screen.id)
            }
        }
        return nil
    }

    func snapshots(selection: CmuxLocalSelection) -> [CmuxWorkspaceSnapshot] {
        workspaces.map { workspace in
            let displayScreen: CmuxScreen?
            if workspace.id == selection.workspaceID {
                displayScreen = workspace.screens.first(where: { $0.id == selection.screenID })
            } else {
                displayScreen = workspace.screens.first(where: \.active) ?? workspace.screens.first
            }
            let title = displayScreen.flatMap(activeSurface(in:))?.title
            return CmuxWorkspaceSnapshot(
                id: workspace.id,
                name: workspace.name,
                subtitle: title?.isEmpty == false ? title : nil,
                screens: workspace.screens.map { screen in
                    guard let pane = activePane(in: screen) else {
                        return CmuxScreenSnapshot(
                            id: screen.id,
                            pane: nil,
                            activeTab: nil,
                            tabs: []
                        )
                    }
                    let activeTab = pane.tabs.indices.contains(pane.activeTab)
                        ? pane.activeTab
                        : nil
                    return CmuxScreenSnapshot(
                        id: screen.id,
                        pane: pane.id,
                        activeTab: activeTab,
                        tabs: pane.tabs.map { tab in
                            let name = tab.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                            let title = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
                            return CmuxTabSnapshot(
                                surface: tab.surface,
                                label: name?.isEmpty == false ? name : (title.isEmpty ? nil : title)
                            )
                        }
                    )
                }
            )
        }
    }

    private func activeSurface(in screen: CmuxScreen) -> CmuxSurface? {
        guard let pane = activePane(in: screen) else { return nil }
        if pane.tabs.indices.contains(pane.activeTab) {
            let active = pane.tabs[pane.activeTab]
            if active.kind == "pty", !active.dead {
                return active
            }
        }
        return pane.tabs.first(where: { $0.kind == "pty" && !$0.dead })
    }

    private func activePane(in screen: CmuxScreen) -> CmuxPane? {
        screen.panes.first(where: { $0.id == screen.activePane })
            ?? screen.panes.first(where: { !$0.dead })
    }
}
