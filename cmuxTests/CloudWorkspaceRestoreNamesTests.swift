import CmuxWorkspaces
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct CloudWorkspaceRestoreNamesTests {
    @Test("Checkpoint names survive restore, delayed publications, and refresh",
          arguments: ["snapshot", "delta", "topology"], [false, true])
    func restoredNamesSurviveRefresh(path: String, daemonRestarted: Bool) throws {
        let machine = SurfaceMachineID.cloud("restore-\(UUID().uuidString)")
        let manager = TabManager(autoWelcomeIfNeeded: false, createInitialWorkspace: false)
        let source = Workspace()
        let pane = try #require(source.bonsplitController.allPaneIds.first)
        let first = try #require(source.focusedPanelId)
        let second = try #require(source.newTerminalSurface(inPane: pane, focus: false)).id
        source.cloudVMBinding = WorkspaceCloudVMBinding(
            vmID: machine.rawValue, isBase: false, remoteWorkspaceID: "ws_main"
        )
        source.setCustomTitle("API – 東京 🚀")
        source.setPanelCustomTitle(panelId: first, title: "Build & test", propagateToCloud: false)
        source.setPanelCustomTitle(panelId: second, title: "Logs / 本番", propagateToCloud: false)
        let saved = try roundTrip(source.sessionSnapshot(includeScrollback: false))
        let restored = Workspace()
        let panelMap = restored.restoreSessionSnapshot(saved)
        manager.tabs = [restored]
        manager.selectedTabId = restored.id
        let restoredPanels = try [first, second].map { try #require(panelMap[$0]) }
        let names = ["Build & test", "Logs / 本番"]
        expectNames(saved.customTitle, names, workspace: restored, panels: restoredPanels)

        let catalog = SurfaceCatalog(cloudWorkspaceRenameService: CloudWorkspaceRenameService(
            environment: CloudWorkspaceRenameEnvironment(
                workspace: { manager.workspacesById[$0] },
                tabManager: { manager.workspacesById[$0] == nil ? nil : manager },
                workspaces: { manager.tabs }
            )
        ))
        let provider = CmuxTuiSurfaceProvider(
            summary: VMSummary(id: machine.rawValue, provider: "freestyle", status: "running",
                               image: "cmux-devbox", createdAt: 0, base: nil),
            links: CloudMachineLinkManager(clientURL: nil, hostThemeColors: { nil }), catalog: catalog
        )
        catalog.register(provider)
        defer {
            provider.stop()
            catalog.unregister(machine: machine)
            manager.tabs = []
            for panel in source.panels.values { panel.close() }
            for panel in restored.panels.values { panel.close() }
        }
        let stale = try state(machine, workspace: "Old workspace", names: ["Old build", "Old logs"], revision: 10)
        #expect(provider.installSnapshotIfNewer(stale))
        let generation = daemonRestarted ? "restored-daemon" : "daemon"
        let revision: UInt64 = daemonRestarted ? 1 : 11
        let checkpoint = try state(machine, workspace: try #require(saved.customTitle), names: names,
                                   revision: revision, generation: generation)
        // Cross a real JSON persistence boundary before installing the restored daemon graph.
        let bytes = try JSONSerialization.data(withJSONObject: try #require(checkpoint.snapshotObject()))
        let graph = try #require(CmuxTuiSnapshotParser.state(
            fromSnapshot: try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any]), machine: machine
        ))
        #expect(provider.installSnapshotIfNewer(graph))
        provider.publish(graph, ports: [])
        for (index, panel) in restoredPanels.enumerated() {
            catalog.record(SurfaceProjection(
                resource: SurfaceResourceID(machine: machine, kind: .terminal, key: "term_\(index)"),
                workspaceID: restored.id, panelID: panel, remoteWorkspaceID: "ws_main", remoteTabID: "tab_\(index)"
            ))
        }
        provider.publish(graph, ports: [])
        expectNames(saved.customTitle, names, workspace: restored, panels: restoredPanels)

        // A callback that installed its old graph before restore resumes after a link await.
        if path == "snapshot" {
            provider.publish(stale, ports: [])
        } else {
            provider.publishDelta(stale, impact: CloudVMStateDeltaImpact(
                resourceIDs: Set((0..<2).map { SurfaceResourceID(machine: machine, kind: .terminal, key: "term_\($0)") }),
                requiresFullResourceRebuild: path == "topology"
            ), ports: [], reconcileTitles: true)
        }
        #expect(catalog.cloudStates[machine] == graph)
        expectNames(saved.customTitle, names, workspace: restored, panels: restoredPanels)
        let resaved = try roundTrip(restored.sessionSnapshot(includeScrollback: false))
        #expect(resaved.customTitle == saved.customTitle)
        #expect(restoredPanels.map { id in resaved.panels.first { $0.id == id }?.customTitle } == names)
        for _ in 0..<2 {
            #expect(provider.installSnapshotIfNewer(graph))
            provider.publish(graph, ports: [])
            expectNames(saved.customTitle, names, workspace: restored, panels: restoredPanels)
        }
        // The restored snapshot must not pin names against a later deliberate remote edit or clear.
        let later = try state(machine, workspace: "Other client", names: ["New build", nil],
                              revision: revision + 1, generation: generation)
        #expect(provider.installSnapshotIfNewer(later))
        provider.publish(later, ports: [])
        expectNames("Other client", ["New build", nil], workspace: restored, panels: restoredPanels)
        #expect(manager.selectedTabId == restored.id)
    }

    private func roundTrip(_ snapshot: SessionWorkspaceSnapshot) throws -> SessionWorkspaceSnapshot {
        try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: JSONEncoder().encode(snapshot))
    }

    private func expectNames(_ title: String?, _ names: [String?], workspace: Workspace, panels: [UUID]) {
        #expect(workspace.customTitle == title)
        #expect(panels.map { workspace.panelCustomTitles[$0] } == names)
        for (panel, name) in zip(panels, names) where name != nil {
            #expect(workspace.panelTitle(panelId: panel) == name)
        }
    }

    private func state(_ machine: SurfaceMachineID, workspace: String, names: [String?],
                       revision: UInt64, generation: String = "daemon") throws -> CloudVMState {
        try #require(CmuxTuiSnapshotParser.state(fromSnapshot: [
            "cursor": ["generation": generation, "revision": String(revision)],
            "workspaces": [["id": "ws_main", "name": workspace]],
            "screens": [["id": "screen", "workspace_id": "ws_main"]],
            "panes": [["id": "pane", "screen_id": "screen"]],
            "tabs": names.enumerated().map { index, name -> [String: Any] in
                ["id": "tab_\(index)", "pane_id": "pane", "content_kind": "terminal",
                 "content_id": "term_\(index)", "name": name as Any? ?? NSNull()]
            },
            "terminals": names.indices.map { ["id": "term_\($0)", "title": "bash", "lifecycle": "running"] },
            "browsers": [], "agents": []
        ], machine: machine))
    }
}
