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
    private struct RenameFailure: Error {}

    @Test("Machine summaries preserve acknowledged names and only known pending workspace overlays")
    func machineSummaryCannotInventWorkspaceRows() throws {
        let machine = SurfaceMachineID.cloud("metadata")
        let catalog = SurfaceCatalog()
        let provider = CloudPlacementTestProvider(machine: machine)
        catalog.register(provider)
        defer { catalog.unregister(machine: machine) }
        let graph = try state(machine, workspace: "Saved name", names: ["Build"], revision: 2)
        let canonicalResources = CmuxTuiSnapshotParser.resources(from: graph)
        let pendingWorkspace = SurfaceRemoteWorkspace(id: "ws_pending", name: "Creating", index: 1, focused: false)
        let pendingResource = SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .terminal, key: "term_pending"),
            title: "bash", detail: nil, lifecycle: .running, agent: nil,
            remoteWorkspace: pendingWorkspace,
            remoteViews: [SurfaceRemoteView(tabID: "tab_pending", workspace: pendingWorkspace)],
            port: nil, url: nil
        )
        catalog.replaceCloudState(graph, resources: canonicalResources + [pendingResource], info: provider.info)
        var stale = provider.info
        stale.remoteWorkspaces = [
            SurfaceRemoteWorkspace(id: "ws_main", name: "Old name", index: 0, focused: true),
            SurfaceRemoteWorkspace(id: "ws_removed", name: "Removed", index: 1, focused: false)
        ]
        catalog.updateMachine(stale, from: provider)
        let canonicalWorkspace = SurfaceRemoteWorkspace(id: "ws_main", name: "Saved name", index: 0, focused: false)
        #expect(catalog.machines[machine]?.remoteWorkspaces == [canonicalWorkspace, pendingWorkspace])
        #expect(catalog.cloudStates[machine] == graph)
        // Once the authoritative resource transaction removes the overlay, a stale
        // summary cannot resurrect either that provisional row or a deleted workspace.
        catalog.replaceCloudState(graph, resources: canonicalResources, info: stale)
        catalog.updateMachine(stale, from: provider)
        #expect(catalog.machines[machine]?.remoteWorkspaces == [canonicalWorkspace])
    }

    @Test("Checkpoint waits for the latest workspace and placement names, including clears")
    func checkpointWaitsForNames() async throws {
        let machine = SurfaceMachineID.cloud("checkpoint")
        let coordinator = CloudRenameCoordinator()
        var persisted = ["workspace": "Old", "build": "Old build", "logs": "Old logs"]
        for (key, name) in [("workspace", "API – 東京 🚀"), ("build", "Build & test"), ("logs", "")] {
            let identity = key == "workspace"
                ? CloudRenameCoordinator.Key.workspace(machine: machine, id: key)
                : CloudRenameCoordinator.Key.tab(machine: machine, id: key)
            coordinator.enqueue(key: identity, pendingName: name) { persisted[key] = name }
        }
        try await coordinator.waitForPendingRenames(on: machine)
        let bytes = try JSONEncoder().encode(persisted)
        let checkpoint = try JSONDecoder().decode([String: String].self, from: bytes)
        #expect(checkpoint == ["workspace": "API – 東京 🚀", "build": "Build & test", "logs": ""])
    }

    @Test("A successful terminal rename cannot hide a failed workspace rename from a checkpoint")
    func checkpointRejectsFailedName() async {
        let machine = SurfaceMachineID.cloud("checkpoint")
        let coordinator = CloudRenameCoordinator()
        let workspace = coordinator.enqueue(key: .workspace(machine: machine, id: "ws"), pendingName: "New") {
            throw RenameFailure()
        }
        let terminal = coordinator.enqueue(key: .tab(machine: machine, id: "tab"), pendingName: "Build") {}
        await #expect(throws: RenameFailure.self) { try await coordinator.waitForPendingRenames(on: machine) }
        _ = await workspace.result
        _ = await terminal.result
    }

    @Test("A corrected name supersedes its failed predecessor and unrelated machines do not block capture")
    func checkpointUsesLatestIntentPerIdentity() async throws {
        let machine = SurfaceMachineID.cloud("checkpoint")
        let coordinator = CloudRenameCoordinator()
        let unrelated = coordinator.enqueue(key: .workspace(machine: .cloud("other"), id: "ws"), pendingName: "Other") {
            throw RenameFailure()
        }
        let first = coordinator.enqueue(key: .workspace(machine: machine, id: "ws"), pendingName: "Failed") {
            throw RenameFailure()
        }
        var savedName = "Old"
        coordinator.enqueue(key: .workspace(machine: machine, id: "ws"), pendingName: "Corrected") { savedName = "Corrected" }
        try await coordinator.waitForPendingRenames(on: machine)
        #expect(savedName == "Corrected")
        _ = await first.result
        _ = await unrelated.result
    }

    @Test("Checkpoint names survive restore, delayed publications, and refresh",
          arguments: ["snapshot", "delta", "topology"], [false, true])
    func restoredNamesSurviveRefresh(path: String, daemonRestarted: Bool) async throws {
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
            catalog.unregister(machine: machine)
            manager.tabs = []
            for panel in source.panels.values { panel.close() }
            for panel in restored.panels.values { panel.close() }
        }
        do {
            let stale = try state(machine, workspace: "Old workspace", names: ["Old build", "Old logs"], revision: 10)
            #expect(provider.installSnapshotIfNewer(stale))
            let generation = daemonRestarted ? "restored-daemon" : "daemon"
            let revision: UInt64 = daemonRestarted ? 1 : 11
            let checkpoint = try state(machine, workspace: try #require(saved.customTitle), names: names,
                                       revision: revision, generation: generation)
            // Cross a real JSON persistence boundary before installing the restored daemon graph.
            let bytes = try JSONSerialization.data(withJSONObject: try #require(checkpoint.snapshotObject()))
            let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let graph = try #require(CmuxTuiSnapshotParser.state(
                fromSnapshot: object, machine: machine
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
        } catch {
            await provider.stop()
            throw error
        }
        await provider.stop()
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
