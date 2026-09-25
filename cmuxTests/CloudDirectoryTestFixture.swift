import CmuxSurfaceCatalogModel
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Uses the production parser, provider acceptance fence, catalog and workspace projection.
@MainActor
final class CloudDirectoryTestFixture {
    let machine = SurfaceMachineID.cloud("cwd-machine")
    let workspace: Workspace
    let panels: [UUID]
    let catalog: SurfaceCatalog
    let provider: CmuxTuiSurfaceProvider

    init() throws {
        let workspace = Workspace(workingDirectory: "/Users/alice/local-checkout")
        self.workspace = workspace
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        panels = [try #require(workspace.focusedPanelId), try #require(workspace.newTerminalSurface(inPane: pane, focus: false)).id]
        workspace.cloudVMBinding = WorkspaceCloudVMBinding(vmID: machine.rawValue, isBase: false, remoteWorkspaceID: "ws_main")
        workspace.setCustomTitle("My explicit task title")
        catalog = SurfaceCatalog(cloudWorkspaceRenameService: CloudWorkspaceRenameService(
            environment: CloudWorkspaceRenameEnvironment(
                workspace: { $0 == workspace.id ? workspace : nil },
                workspaces: { [workspace] }
            )
        ))
        provider = CmuxTuiSurfaceProvider(
            summary: VMSummary(id: machine.rawValue, provider: "freestyle", status: "running", image: "cmux-devbox", createdAt: 0, base: nil),
            links: CloudMachineLinkManager(clientURL: nil, hostThemeColors: { nil }), catalog: catalog
        )
        catalog.register(provider)
        try install(paths: ["/home/cmux/first", "/home/cmux/second"], revision: 1)
        for (index, panel) in panels.enumerated() {
            catalog.record(SurfaceProjection(
                resource: resourceID(index), workspaceID: workspace.id, panelID: panel,
                remoteWorkspaceID: "ws_main", remoteTabID: "tab_\(index)"
            ))
        }
        provider.publish(try #require(provider.cloudState), ports: [])
    }

    func close() {
        catalog.unregister(machine: machine)
        for panel in workspace.panels.values { panel.close() }
    }

    func resourceID(_ index: Int) -> SurfaceResourceID {
        SurfaceResourceID(machine: machine, kind: .terminal, key: "term_\(index)")
    }

    func state(paths: [String?], revision: UInt64, generation: String = "daemon") throws -> CloudVMState {
        let terminals = paths.enumerated().map { index, path -> [String: Any] in
            ["id": "term_\(index)", "title": "bash", "cwd": path as Any? ?? NSNull(), "lifecycle": "running"]
        }
        return try #require(CmuxTuiSnapshotParser.state(fromSnapshot: [
            "cursor": ["generation": generation, "revision": String(revision)],
            "workspaces": [["id": "ws_main", "name": "Remote name", "focused": true]],
            "screens": [["id": "screen", "workspace_id": "ws_main"]],
            "panes": [["id": "pane", "screen_id": "screen"]],
            "tabs": paths.indices.map { index -> [String: Any] in
                ["id": "tab_\(index)", "pane_id": "pane", "content_kind": "terminal", "content_id": "term_\(index)", "focused": index == 0]
            },
            "terminals": terminals, "browsers": [], "agents": []
        ], machine: machine))
    }

    @discardableResult
    func install(paths: [String?], revision: UInt64, generation: String = "daemon") throws -> CloudVMState {
        let state = try state(paths: paths, revision: revision, generation: generation)
        #expect(provider.installSnapshotIfNewer(state))
        provider.publish(state, ports: [])
        return state
    }

    func changeDirectory(_ path: String?, terminal: Int) throws {
        let current = try #require(provider.cloudState)
        let cursor = try #require(current.cursor)
        let nextCursor = CloudVMCursor(generation: cursor.generation, revision: cursor.revision + 1)
        let delta = try JSONSerialization.data(withJSONObject: ["changes": [[
            "kind": "upsert", "resource": "terminal", "id": "term_\(terminal)",
            "value": ["id": "term_\(terminal)", "title": "bash", "cwd": path as Any? ?? NSNull(), "lifecycle": "running"]
        ]]])
        let application = try #require(CmuxTuiSnapshotParser.applyingWithImpact(deltaPayload: delta, cursor: nextCursor, to: current))
        #expect(application.state.workspaces == current.workspaces)
        #expect(application.state.tabs == current.tabs)
        #expect(provider.installSnapshotIfNewer(application.state))
        provider.publishDelta(application.state, impact: application.impact, ports: [], reconcileTitles: false)
    }

    func sidebar() throws -> SidebarWorkspaceSnapshotBuilder.Snapshot {
        let name = "cloud-cwd-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        return SidebarWorkspaceSnapshotFactory(
            workspace: workspace, settings: SidebarTabItemSettingsSnapshot(defaults: defaults), showsAgentActivity: false
        ).makeSnapshot()
    }

    func sidebarText() throws -> String {
        let snapshot = try sidebar()
        return (snapshot.compactDirectoryCandidates + snapshot.branchDirectoryLines.flatMap(\.directoryCandidates)).joined(separator: "\n")
    }
}
