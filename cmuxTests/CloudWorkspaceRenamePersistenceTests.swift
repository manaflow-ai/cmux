import CmuxWorkspaces
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct CloudWorkspaceRenamePersistenceTests {
    @Test("Delayed publications cannot undo a completed workspace rename",
          arguments: ["snapshot", "delta", "topology"], ["rename", "restart", "replacement"])
    func renamePersists(path: String, transition: String) throws {
        let machine = SurfaceMachineID.cloud("rename-\(UUID().uuidString)")
        let manager = TabManager(autoWelcomeIfNeeded: false, createInitialWorkspace: false)
        let workspace = Workspace(initialSurface: .cloudVMLoading)
        let otherProjection = Workspace(initialSurface: .cloudVMLoading)
        manager.tabs = [workspace, otherProjection]
        manager.selectedTabId = workspace.id
        for local in manager.tabs {
            local.cloudVMBinding = WorkspaceCloudVMBinding(
                vmID: machine.rawValue, isBase: false, remoteWorkspaceID: "ws_main"
            )
        }
        let catalog = SurfaceCatalog(cloudWorkspaceRenameService: CloudWorkspaceRenameService(
            environment: CloudWorkspaceRenameEnvironment(
                workspace: { manager.workspacesById[$0] },
                tabManager: { manager.workspacesById[$0] == nil ? nil : manager },
                workspaces: { manager.tabs }
            )
        ))
        let links = CloudMachineLinkManager(clientURL: nil, hostThemeColors: { nil })
        let summary = VMSummary(
            id: machine.rawValue, provider: "freestyle", status: "running",
            image: "cmux-devbox", createdAt: 0, base: nil
        )
        let original = CmuxTuiSurfaceProvider(summary: summary, links: links, catalog: catalog)
        catalog.register(original)
        defer {
            original.stop()
            (catalog.provider(for: machine) as? CmuxTuiSurfaceProvider)?.stop()
            catalog.unregister(machine: machine)
            manager.tabs = []
        }
        let previous = try state(machine, name: "Original", revision: 10)
        #expect(original.installSnapshotIfNewer(previous))
        original.publish(previous, ports: [])
        let current: CmuxTuiSurfaceProvider
        if transition == "replacement" {
            current = CmuxTuiSurfaceProvider(summary: summary, links: links, catalog: catalog)
            catalog.register(current)
        } else {
            current = original
        }
        let generation = transition == "restart" ? "daemon-2" : "daemon-1"
        let revision: UInt64 = transition == "restart" ? 1 : 11
        let renamed = try state(machine, name: "Project", revision: revision, generation: generation)
        workspace.setCustomTitle("Project", source: .user)
        #expect(current.installSnapshotIfNewer(renamed))
        current.publish(renamed, ports: [])
        expectName("Project", state: renamed, catalog: catalog, manager: manager)

        // An older event resumes after the rename's forced snapshot has published.
        // Drive the actual publication paths, including resource patches and full rebuilds.
        if path == "snapshot" {
            original.publish(previous, ports: [])
        } else {
            original.publishDelta(
                previous,
                impact: CloudVMStateDeltaImpact(
                    resourceIDs: [SurfaceResourceID(machine: machine, kind: .terminal, key: "term_1")],
                    requiresFullResourceRebuild: path == "topology"
                ),
                ports: [], reconcileTitles: true
            )
        }
        expectName("Project", state: renamed, catalog: catalog, manager: manager)
        for _ in 0..<2 {
            #expect(current.installSnapshotIfNewer(renamed))
            current.publish(renamed, ports: [])
            expectName("Project", state: renamed, catalog: catalog, manager: manager)
        }
        let later = try state(machine, name: "Other client", revision: revision + 1, generation: generation)
        #expect(current.installSnapshotIfNewer(later))
        current.publish(later, ports: [])
        expectName("Other client", state: later, catalog: catalog, manager: manager)
    }

    private func state(
        _ machine: SurfaceMachineID, name: String, revision: UInt64, generation: String = "daemon-1"
    ) throws -> CloudVMState {
        try #require(CmuxTuiSnapshotParser.state(fromSnapshot: [
            "cursor": ["generation": generation, "revision": String(revision)],
            "workspaces": [["id": "ws_main", "name": name]],
            "screens": [["id": "screen_1", "workspace_id": "ws_main"]],
            "panes": [["id": "pane_1", "screen_id": "screen_1"]],
            "tabs": [["id": "tab_1", "pane_id": "pane_1", "content_kind": "terminal", "content_id": "term_1"]],
            "terminals": [["id": "term_1", "tab_id": "tab_1", "title": "bash", "lifecycle": "running"]],
            "browsers": [], "agents": []
        ], machine: machine))
    }

    private func expectName(_ name: String, state: CloudVMState, catalog: SurfaceCatalog, manager: TabManager) {
        #expect(manager.tabs.map(\.customTitle) == [name, name])
        #expect(manager.tabs.allSatisfy { $0.effectiveCustomTitleSource == .remote })
        #expect(manager.selectedTabId == manager.tabs.first?.id)
        #expect(catalog.cloudStates[state.machine] == state)
        #expect(catalog.snapshot.machines.first { $0.id == state.machine }?.remoteWorkspaces?.first?.name == name)
        #expect(catalog.snapshot.resources(on: state.machine).first { $0.kind == .terminal }?.remoteWorkspace?.name == name)
    }
}
