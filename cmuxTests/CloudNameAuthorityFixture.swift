import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class CloudNameAuthorityFixture {
    let catalog: SurfaceCatalog
    let manager: TabManager
    let workspace: Workspace
    let provider: CloudNameAuthorityTestProvider
    let panelID: UUID
    let renameService: CloudWorkspaceRenameService

    init() throws {
        catalog = SurfaceCatalog.shared
        manager = TabManager(autoWelcomeIfNeeded: false)
        workspace = try #require(manager.selectedWorkspace)
        panelID = try #require(workspace.focusedPanelId)
        let owner = manager
        renameService = CloudWorkspaceRenameService(environment: .init(
            workspace: { owner.workspacesById[$0] }, tabManager: { _ in owner }, workspaces: { owner.tabs }
        ))
        provider = try CloudNameAuthorityTestProvider(machine: .cloud("name-fixture-" + UUID().uuidString),
                                                    catalog: catalog, renameService: renameService)
        catalog.register(provider)
        #expect(provider.install(provider.graph))
        workspace.cloudVMBinding = WorkspaceCloudVMBinding(vmID: provider.machine.rawValue, isBase: false, remoteWorkspaceID: "a")
        catalog.record(SurfaceProjection(resource: .init(machine: provider.machine, kind: .terminal, key: "term_a"),
            workspaceID: workspace.id, panelID: panelID, remoteWorkspaceID: "a", remoteTabID: "tab_a"))
        _ = provider.install(provider.graph)
        TerminalController.shared.setActiveTabManager(manager)
    }

    func close() async {
        await provider.receiver.stop()
        TerminalController.shared.setActiveTabManager(nil)
        catalog.endProjections(panelID: panelID, reason: .replaced)
        catalog.unregister(machine: provider.machine)
        for panel in workspace.panels.values { panel.close() }
        manager.tabs = []
    }

    func settle() async throws { try await catalog.cloudRenameCoordinator.waitForPendingRenames(on: provider.machine) }

    func call(_ method: String, extra: [String: Any] = [:]) async throws -> [String: Any] {
        var params: [String: Any] = ["workspace_id": workspace.id.uuidString, "panel_id": panelID.uuidString]
        params.merge(extra) { _, new in new }
        let bytes = try JSONSerialization.data(withJSONObject: ["id": "fixture", "method": method, "params": params])
        let line = try #require(String(data: bytes, encoding: .utf8))
        let response = try #require(await TerminalController.shared.processCommandUsingSocketExecutionPolicyAsync(line))
        let object = try #require(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        #expect(object["ok"] as? Bool == true)
        return try #require(object["result"] as? [String: Any])
    }

    func agentName(_ name: String, context: CloudAgentNameContext? = nil) async throws {
        let captured = context ?? catalog.cloudAgentNameContext(workspaceID: workspace.id, panelID: panelID)
        _ = try await call("surface.sync_codex_native_title", extra: [
            "title": name, "cloud_name_context": (captured?.wire as Any?) ?? NSNull()
        ])
        try await settle()
    }

    func expectParity(_ name: String, workspaceName: String? = nil) throws {
        let native = try #require(workspace.surfaceIdFromPanelId(panelID))
        #expect(workspace.bonsplitController.tab(native)?.title == name)
        let nodes = CloudTreeNodeBuilder.flattened(CloudTreeNodeBuilder.nodes(
            machines: [], snapshot: catalog.snapshot, localWorkspaces: [], includeLocalMachine: false
        ))
        let row = try #require(nodes.first { node in
            if case .terminal(let terminal) = node.kind {
                return terminal.resource.machine == provider.machine && terminal.remoteView?.tabID == "tab_a"
            }
            return false
        })
        #expect(row.searchableTitle == name)
        if let workspaceName {
            #expect(workspace.title == workspaceName)
            #expect(nodes.first { $0.id == CloudTreeNodeBuilder.nodeID(workspace: "a", machine: provider.machine) }?.searchableTitle == workspaceName)
        }
    }
}
