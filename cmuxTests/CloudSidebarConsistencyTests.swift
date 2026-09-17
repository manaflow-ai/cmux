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
            let snapshot = try #require(graph.snapshotObject())
            let layout = try #require(CloudWorkspaceLayoutTranslator.projectionLayout(
                snapshot: snapshot, machine: machine,
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

    @Test("Opening a tab selection does not expand it to the entire Cloud workspace")
    func selectedTabsRemainASelection() async throws {
        let catalog = SurfaceCatalog()
        catalog.register(CloudPlacementTestProvider(machine: machine))
        install(try state(), in: catalog)
        let all = try catalog.remoteWorkspaceGroup(machine: machine, workspaceID: "ws_main")
        let selection = SurfaceResourceGroup(title: "Selection", placements: [all.placements[0]], remoteWorkspaceID: "ws_main")
        let workspaceID = UUID()
        let host = SurfaceCatalog.NewWorkspaceHost(
            create: { _ in (workspaceID, nil) }, paneLookup: { _, _ in "pane" }, closeStarter: { _, _ in }
        )
        let opened = try await catalog.projectGroupAsNewLocalWorkspace(selection, title: selection.title, focus: false, host: host)
        #expect(opened.projections.map(\.resource.key) == ["term_a"])
    }

    @Test("A browser-only workspace has the same row and layout membership")
    func browserOnlyWorkspace() throws {
        let catalog = SurfaceCatalog()
        var document = try #require(state(tabs: ["a"]).snapshotObject())
        document["tabs"] = [["id": "tab_a", "pane_id": "pane_main", "content_kind": "browser", "content_id": "browser_a"]]
        document["browsers"] = [["id": "browser_a", "tab_id": "tab_a", "title": "Docs", "url": "https://cmux.com/docs"]]
        let graph = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: document, machine: machine))
        install(graph, in: catalog)
        let row = try #require(workspaceRows(catalog).first)
        #expect(row.dragGroup?.placements == catalog.cloudWorkspaceLayout(machine: machine, workspaceID: "ws_main")?.placements)
        #expect(row.children.count == 1)
    }

    @Test("User intents keep the accepted graph visible until their writes are acknowledged")
    func synchronousUserIntent() async throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelId)
        let service = CloudWorkspaceRenameService(environment: .init(
            workspace: { manager.workspacesById[$0] }, tabManager: { _ in manager }, workspaces: { manager.tabs }
        ))
        let catalog = SurfaceCatalog(cloudWorkspaceRenameService: service)
        let provider = CloudPlacementTestProvider(machine: machine)
        catalog.register(provider)
        let graph = try state(tabs: ["a"])
        install(graph, in: catalog)
        workspace.cloudVMBinding = WorkspaceCloudVMBinding(vmID: machine.rawValue, isBase: false, remoteWorkspaceID: "ws_main")
        let resource = try #require(catalog.resources[SurfaceResourceID(machine: machine, kind: .terminal, key: "term_a")])
        catalog.record(SurfaceProjection(resource: resource.id, workspaceID: workspace.id, panelID: panelID, remoteWorkspaceID: "ws_main", remoteTabID: "tab_a"))
        #expect(catalog.submitCloudWorkspaceRename(workspace: workspace, title: "User workspace", source: .user) == true)
        #expect(catalog.submitCloudPanelRename(workspace: workspace, panelID: panelID, title: "User terminal", source: .user) == true)
        #expect(catalog.cloudRenameCoordinator.pendingName(for: .workspace(machine: machine, id: "ws_main")) == "User workspace")
        #expect(catalog.cloudRenameCoordinator.pendingName(for: .tab(machine: machine, id: "tab_a")) == "User terminal")
        catalog.reconcileCloudRemoteState(machine: machine, state: graph)
        #expect(workspace.title == "GOD WORKSPACE")
        #expect(workspace.panelCustomTitles[panelID] == "Explicit a")
        // A barrier in the same lane completes both writes without a sleep.
        try await catalog.cloudRenameCoordinator.enqueue(key: .workspace(machine: machine, id: "barrier"), pendingName: "") {}.value
        #expect(provider.workspaceRenames == ["User workspace"])
        #expect(provider.tabRenames == ["User terminal"])
    }

    @Test("The terminal inventory reflects a common explicit name without conflating different aliases")
    func inventoryNameParity() throws {
        let graph = try state(tabs: ["a"])
        var resource = try #require(CmuxTuiSnapshotParser.resources(from: graph).first { $0.id.key == "term_a" })
        let row = CloudTreeTerminalRow(resource: resource, isOpen: false)
        #expect(row.displayTitle == "Explicit a")
        var other = try #require(resource.remoteViews?.first)
        other.tabID = "other_view"
        other.name = "Another explicit name"
        resource.remoteViews?.append(other)
        #expect(CloudTreeTerminalRow(resource: resource, isOpen: false).displayTitle == "Process a r1")
        #expect(CloudTreeTerminalRow(resource: resource, isOpen: false, remoteView: other).displayTitle == "Another explicit name")
        resource.title = ""
        resource.remoteViews = []
        #expect(CloudTreeTerminalRow(resource: resource, isOpen: false).displayTitle == resource.cloudProcessDisplayTitle)
    }

    @Test("Several remote screens use one ordering in the tree and native layout")
    func multipleScreensUseTheSameProjection() throws {
        let catalog = SurfaceCatalog()
        var document = try #require(state().snapshotObject())
        document["screens"] = [
            ["id": "screen_main", "workspace_id": "ws_main", "index": 0, "focused": false,
             "layout": ["kind": "leaf", "pane_id": "pane_main", "tab_ids": ["tab_a"]]],
            ["id": "screen_other", "workspace_id": "ws_main", "index": 1, "focused": true,
             "layout": ["kind": "leaf", "pane_id": "pane_other", "tab_ids": ["tab_b"]]]
        ]
        document["panes"] = [["id": "pane_main", "screen_id": "screen_main"], ["id": "pane_other", "screen_id": "screen_other"]]
        var tabs = try #require(document["tabs"] as? [[String: Any]])
        tabs[1]["pane_id"] = "pane_other"
        document["tabs"] = tabs
        let graph = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: document, machine: machine))
        install(graph, in: catalog)
        let row = try #require(workspaceRows(catalog).first)
        let layout = try #require(catalog.cloudWorkspaceLayout(machine: machine, workspaceID: "ws_main"))
        #expect(row.dragGroup?.placements == layout.placements)
        #expect(layout.placements.compactMap(\.remoteTabID) == ["tab_a", "tab_b"])
        guard case .split(.right, _, _, _) = layout else { Issue.record("Each screen retains a pane"); return }
    }

    @Test("A user title equal to the daemon name keeps user ownership")
    func equalUserNamesRemainUserOwned() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelId)
        let catalog = SurfaceCatalog(cloudWorkspaceRenameService: CloudWorkspaceRenameService(environment: .init(
            workspace: { id in manager.workspacesById[id] }, tabManager: { _ in manager }, workspaces: { manager.tabs }
        )))
        workspace.cloudVMBinding = WorkspaceCloudVMBinding(vmID: machine.rawValue, isBase: false, remoteWorkspaceID: "ws_main")
        let graph = try state(tabs: ["a"])
        install(graph, in: catalog)
        catalog.record(SurfaceProjection(resource: SurfaceResourceID(machine: machine, kind: .terminal, key: "term_a"),
            workspaceID: workspace.id, panelID: panelID, remoteWorkspaceID: "ws_main", remoteTabID: "tab_a"))
        _ = manager.setCustomTitle(tabId: workspace.id, title: "GOD WORKSPACE", propagateToCloud: false)
        _ = workspace.setPanelCustomTitle(panelId: panelID, title: "Explicit a", propagateToCloud: false)
        catalog.reconcileCloudRemoteState(machine: machine, state: graph)
        #expect(workspace.effectiveCustomTitleSource == .user)
        #expect(workspace.panelCustomTitleSources[panelID] == .user)
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
