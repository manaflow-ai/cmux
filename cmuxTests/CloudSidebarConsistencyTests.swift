import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Exercises the same accepted graph through sidebar rows, workspace opening and
/// native title reconciliation, without a network connection or live Cloud machine.
@MainActor
@Suite("Cloud sidebar and layout share an authoritative graph")
struct CloudSidebarConsistencyTests {
    private let machine = SurfaceMachineID.cloud("consistency-fixture")

    private func state(revision: Int = 1, generation: String = "fixture", name: String = "GOD WORKSPACE", tabs: [String] = ["a", "b"], named: Bool = true) throws -> CloudVMState {
        let document: [String: Any] = [
            "cursor": ["generation": generation, "revision": String(revision)],
            "workspaces": [["id": "ws_main", "name": name, "index": 0]],
            "screens": [["id": "screen_main", "workspace_id": "ws_main", "layout": [
                "version": 1, "screen_id": "screen_main", "root": [
                    "kind": "leaf", "pane_id": "pane_main", "tab_ids": tabs.map { "tab_" + $0 }
                ]
            ]]],
            "panes": [["id": "pane_main", "screen_id": "screen_main"]],
            "tabs": tabs.enumerated().map { index, key in
                ["id": "tab_" + key, "pane_id": "pane_main", "index": index,
                 "focused": key == "b", "name": named ? "Explicit " + key : "",
                 "content_kind": "terminal", "content_id": "term_" + key] as [String: Any]
            },
            // Inventory order deliberately differs from placement order.
            "terminals": ["b", "a", "c"].map {
                ["id": "term_" + $0, "title": "Process \($0) r\(revision)", "lifecycle": "running"]
            },
            "browsers": [], "agents": []
        ]
        return try #require(CmuxTuiSnapshotParser.state(fromSnapshot: document, machine: machine))
    }

    private func install(_ state: CloudVMState, in catalog: SurfaceCatalog, incremental: Bool = false) {
        let resources = CmuxTuiSnapshotParser.resources(from: state)
        let info = SurfaceMachineInfo(
            id: machine, name: "Fixture", status: "running", image: nil, hasDesktop: false,
            memoryMb: nil, diskMb: nil, linkState: .connected, linkError: nil,
            cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil,
            remoteWorkspaces: state.workspaces.map {
                SurfaceRemoteWorkspace(id: $0.id, name: $0.name, index: $0.index, focused: $0.focused)
            }
        )
        if incremental { catalog.applyCloudStateDelta(state, resources: resources, info: info) }
        else { catalog.replaceCloudState(state, resources: resources, info: info) }
    }

    private func workspaceRows(_ catalog: SurfaceCatalog) -> [CloudTreeNode] {
        CloudTreeNodeBuilder.flattened(CloudTreeNodeBuilder.nodes(
            machines: [], snapshot: catalog.snapshot, localWorkspaces: [], includeLocalMachine: false
        )).filter { $0.structureTag == "workspace" }
    }

    @Test("Create, close, move, restore, reconnect and refresh preserve layout membership and order", arguments: [false, true])
    func layoutParity(incremental: Bool) throws {
        let catalog = SurfaceCatalog()
        let steps: [[String]] = [["a", "b"], ["a", "b", "c"], ["b", "c"], ["c", "b"], ["a", "b"], ["a", "b"]]
        for (offset, tabs) in steps.enumerated() {
            let graph = try state(revision: offset + 1, generation: offset >= 4 ? "restored" : "fixture", tabs: tabs)
            install(graph, in: catalog, incremental: incremental)
            let row = try #require(workspaceRows(catalog).first)
            let group = try catalog.remoteWorkspaceGroup(machine: machine, workspaceID: "ws_main")
            let layout = try #require(CloudWorkspaceLayoutTranslator.projectionLayout(
                snapshot: try #require(graph.snapshotObject()), machine: machine,
                workspaceID: "ws_main", resources: catalog.snapshot.resources
            ))
            let expected = tabs.map { "tab_" + $0 }
            #expect(group.placements.compactMap(\.remoteTabID) == expected)
            #expect(row.dragGroup?.placements == layout.placements)
            #expect(row.children.compactMap { node -> String? in
                if case .terminal(let terminal) = node.kind { return terminal.remoteView?.tabID }
                return nil
            } == expected)
            #expect(row.children.allSatisfy { $0.children.isEmpty })
            #expect(row.searchableTitle == graph.workspaces[0].name)
            #expect(row.children.compactMap { node -> String? in
                if case .terminal(let terminal) = node.kind { return terminal.displayTitle }
                return nil
            } == tabs.map { "Explicit " + $0 })
        }
    }

    @Test("Opening a captured sidebar row uses current membership and current workspace name")
    func openingStaleRow() async throws {
        let catalog = SurfaceCatalog()
        let provider = CloudPlacementTestProvider(machine: machine)
        catalog.register(provider)
        install(try state(tabs: ["a"]), in: catalog)
        let captured = try catalog.remoteWorkspaceGroup(machine: machine, workspaceID: "ws_main")
        install(try state(revision: 2, name: "Renamed", tabs: ["b", "c"]), in: catalog)
        var titles: [String] = []
        let workspaceID = UUID()
        let host = SurfaceCatalog.NewWorkspaceHost(
            create: { title in titles.append(title); return (workspaceID, nil) },
            paneLookup: { _, _ in "pane" }, closeStarter: { _, _ in }
        )
        let opened = try await catalog.projectGroupAsNewLocalWorkspace(
            captured, title: captured.title, focus: false, host: host
        )
        #expect(titles == ["Renamed"])
        #expect(opened.projections.map(\.resource.key) == ["term_b", "term_c"])
        #expect(opened.projections.compactMap(\.remoteTabID) == ["tab_b", "tab_c"])
    }

    @Test("A bound native tab receives canonical names, process titles, and ignores delayed graph callbacks", arguments: [false, true])
    func nativeNameParity(named: Bool) throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelId)
        let catalog = SurfaceCatalog(cloudWorkspaceRenameService: CloudWorkspaceRenameService(environment: .init(
            workspace: { id in manager.workspacesById[id] },
            tabManager: { _ in manager }, workspaces: { manager.tabs }
        )))
        workspace.cloudVMBinding = WorkspaceCloudVMBinding(vmID: machine.rawValue, isBase: false, remoteWorkspaceID: "ws_main")
        let old = try state(tabs: ["a"], named: named)
        install(old, in: catalog)
        catalog.record(SurfaceProjection(
            resource: SurfaceResourceID(machine: machine, kind: .terminal, key: "term_a"),
            workspaceID: workspace.id, panelID: panelID, remoteWorkspaceID: "ws_main", remoteTabID: "tab_a"
        ))
        catalog.reconcileCloudRemoteState(machine: machine, state: old)
        #expect(workspace.title == "GOD WORKSPACE")
        #expect(workspace.panelTitles[panelID] == "Process a r1")
        let new = try state(revision: 2, name: "Current workspace", tabs: ["a"], named: named)
        install(new, in: catalog, incremental: true)
        catalog.reconcileCloudRemoteState(machine: machine, state: new)
        catalog.reconcileCloudRemoteState(machine: machine, state: old)
        #expect(workspace.title == "Current workspace")
        #expect(workspace.panelTitles[panelID] == "Process a r2")
        let nativeTab = try #require(workspace.surfaceIdFromPanelId(panelID))
        let displayed = try #require(workspace.bonsplitController.tab(nativeTab))
        #expect(displayed.title == (named ? "Explicit a" : "Process a r2"))
    }
}
