import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Installs only synthetic identities; the hosted test's catalog never connects to a VM.
@MainActor
final class CloudSidebarRenameFixture {
    let catalog: SurfaceCatalog
    let machine: SurfaceMachineID
    let provider: CloudPlacementTestProvider
    let manager: TabManager
    let workspace: Workspace
    let panelID: UUID
    let service: CloudWorkspaceRenameService

    init(manager: TabManager, workspace: Workspace, catalog: SurfaceCatalog) throws {
        self.manager = manager
        self.workspace = workspace
        self.catalog = catalog
        machine = .cloud("rename-fixture-" + UUID().uuidString)
        provider = CloudPlacementTestProvider(machine: machine)
        panelID = try #require(workspace.focusedPanelId)
        service = CloudWorkspaceRenameService(environment: .init(
            workspace: { manager.workspacesById[$0] }, tabManager: { _ in manager }, workspaces: { manager.tabs }
        ))
        catalog.register(provider)
        workspace.cloudVMBinding = WorkspaceCloudVMBinding(vmID: machine.rawValue, isBase: false, remoteWorkspaceID: "ws_main")
        install(try state())
        catalog.record(SurfaceProjection(resource: resourceID, workspaceID: workspace.id,
            panelID: panelID, remoteWorkspaceID: "ws_main", remoteTabID: "tab_main"))
        reconcile()
    }

    var resourceID: SurfaceResourceID { SurfaceResourceID(machine: machine, kind: .terminal, key: "term_main") }

    func state(revision: UInt64 = 1, generation: String = "fixture", name: String? = nil, workspaceName: String = "Fixture workspace") throws -> CloudVMState {
        let document: [String: Any] = [
            "cursor": ["generation": generation, "revision": String(revision)],
            "workspaces": [["id": "ws_main", "name": workspaceName, "index": 0]],
            "screens": [["id": "screen_main", "workspace_id": "ws_main", "layout": [
                "kind": "leaf", "pane_id": "pane_main", "tab_ids": ["tab_main", "tab_other"]]]],
            "panes": [["id": "pane_main", "screen_id": "screen_main"]],
            "tabs": [
                ["id": "tab_main", "pane_id": "pane_main", "index": 0,
                 "name": name ?? "", "content_kind": "terminal", "content_id": "term_main"],
                ["id": "tab_other", "pane_id": "pane_main", "index": 1,
                 "name": "Intentional other label", "content_kind": "terminal", "content_id": "term_other"]],
            "terminals": [["id": "term_main", "title": "terminal", "lifecycle": "running"],
                          ["id": "term_other", "title": "terminal", "lifecycle": "running"]],
            "browsers": [], "agents": []
        ]
        return try #require(CmuxTuiSnapshotParser.state(fromSnapshot: document, machine: machine))
    }

    func install(_ graph: CloudVMState, observation: CloudVMStateObservation = .current) {
        catalog.replaceCloudState(graph, resources: CmuxTuiSnapshotParser.resources(from: graph), info: provider.info, observation: observation)
    }

    func reconcile() {
        if let state = catalog.cloudStates[machine] { service.reconcileRemoteState(machine: machine, state: state, catalog: catalog, observation: catalog.cloudStateObservations[machine] ?? .current) }
    }

    func drain() async throws {
        try await catalog.cloudRenameCoordinator.enqueue(key: .workspace(machine: machine, id: "barrier"), pendingName: "") {}.value
    }

    func assertParity(_ title: String, workspaceName: String = "Fixture workspace") throws {
        let native = try #require(workspace.surfaceIdFromPanelId(panelID))
        #expect(workspace.bonsplitController.tab(native)?.title == title)
        #expect(workspace.panelTitle(panelId: panelID) == title)
        let rows = CloudTreeNodeBuilder.flattened(catalog.sidebarNodes(on: machine))
        let terminals = rows.compactMap { node -> CloudTreeTerminalRow? in
            if case .terminal(let row) = node.kind { return row }; return nil
        }
        #expect(terminals.filter { $0.resource.id == resourceID }.allSatisfy { $0.displayTitle == title })
        #expect(terminals.contains { $0.remoteView?.tabID == "tab_main" })
        #expect(terminals.filter { $0.resource.id.key == "term_other" }.allSatisfy { $0.displayTitle == "Intentional other label" })
        #expect(catalog.cloudStates[machine]?.lookupIndex.tab(id: "tab_main")?.name == title)
        #expect(rows.first { $0.structureTag == "workspace" }?.searchableTitle == workspaceName)
        #expect(catalog.cloudStates[machine]?.tabs.map(\.id) == ["tab_main", "tab_other"])
    }

    func close() {
        provider.beforeMutation = nil
        catalog.unregister(machine: machine)
    }
}
