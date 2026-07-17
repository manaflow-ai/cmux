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

    func pane(
        workspace workspaceID: UInt64,
        screen screenID: UInt64,
        pane paneID: UInt64
    ) -> CmuxPane? {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }),
              let screen = workspace.screens.first(where: { $0.id == screenID })
        else { return nil }
        return screen.panes.first(where: { $0.id == paneID && !$0.dead })
    }

    func selectedScreen(selection: CmuxLocalSelection) -> CmuxScreen? {
        workspaces.first(where: { $0.id == selection.workspaceID })?
            .screens.first(where: { $0.id == selection.screenID })
    }

    func visiblePaneSurfaces(selection: CmuxLocalSelection) -> [(pane: UInt64, surface: UInt64)] {
        guard let screen = selectedScreen(selection: selection) else { return [] }
        let layout = CmuxPaneLayoutView(layout: screen.layout, zoomedPane: screen.zoomedPane)
        return layout.paneIDs.compactMap { paneID in
            guard let pane = screen.panes.first(where: { $0.id == paneID && !$0.dead }),
                  let surface = activeSurface(in: pane)?.surface
            else { return nil }
            return (paneID, surface)
        }
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
                    let panes = screen.panes.filter { !$0.dead }.map { pane in
                        let activeTab = pane.tabs.indices.contains(pane.activeTab)
                            ? pane.activeTab
                            : nil
                        return CmuxPaneSnapshot(
                            id: pane.id,
                            activeTab: activeTab,
                            activeSurface: activeSurface(in: pane)?.surface,
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
                    return CmuxScreenSnapshot(
                        id: screen.id,
                        activePane: panes.contains(where: { $0.id == screen.activePane })
                            ? screen.activePane
                            : panes.first?.id,
                        zoomedPane: screen.zoomedPane,
                        layout: CmuxPaneLayoutView(
                            layout: screen.layout,
                            zoomedPane: screen.zoomedPane
                        ),
                        panes: panes
                    )
                }
            )
        }
    }

    private func activeSurface(in screen: CmuxScreen) -> CmuxSurface? {
        guard let pane = activePane(in: screen) else { return nil }
        return activeSurface(in: pane)
    }

    private func activeSurface(in pane: CmuxPane) -> CmuxSurface? {
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
