import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cloud sidebar surface lifecycle")
struct CloudSidebarSurfaceRegressionTests {
    private let machine = SurfaceMachineID.cloud("sidebar-vm")

    private func nodes(link: SurfaceLinkState?, desktop: Bool = true) -> [CloudTreeNode] {
        let row = MachineSnapshot(
            id: machine.rawValue, provider: "freestyle", image: "desktop",
            isDesktop: desktop, activity: .ready, createdAt: nil, label: nil
        )
        let info = link.map {
            SurfaceMachineInfo(
                id: machine, name: machine.rawValue, status: "running", image: "desktop",
                hasDesktop: desktop, memoryMb: nil, diskMb: nil, linkState: $0,
                linkError: $0 == .error ? "Connection failed" : nil,
                cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil
            )
        }
        return CloudTreeNodeBuilder.flattened(CloudTreeNodeBuilder.nodes(
            machines: [row],
            snapshot: SurfaceCatalogSnapshot(machines: info.map { [$0] } ?? [], resources: [], projections: []),
            localWorkspaces: [], includeLocalMachine: false
        ))
    }

    @Test("Fleet discovery never leaves a childless machine before registration")
    func awaitingProviderHasLoadingRow() {
        #expect(nodes(link: nil).contains {
            if case .placeholder(_, let value) = $0.kind { return value.style == .connecting }
            return false
        })
    }

    @Test("Desktop capability remains visible before the terminal snapshot", arguments: [SurfaceLinkState.connecting, .error, .asleep, .connected])
    func desktopBeforeSessionSnapshot(link: SurfaceLinkState) {
        #expect(nodes(link: link).contains {
            if case .display(let resource, _, _) = $0.kind { return resource.id.key == SurfaceResourceID.desktopDisplayKey }
            return false
        })
    }

    @Test("Ports distinguish loading, error, asleep, and a successful empty scan", arguments: [SurfaceLinkState.connecting, .error, .asleep, .connected])
    func emptyPortsStayVisible(link: SurfaceLinkState) throws {
        let group = try #require(nodes(link: link, desktop: false).first {
            if case .portsGroup = $0.kind { return true }
            return false
        })
        #expect(group.children.count == 1)
        guard case .placeholder(_, let value) = group.children[0].kind else {
            Issue.record("Ports must explain why there are no rows")
            return
        }
        if link == .connecting { #expect(value.style == .connecting) }
        if link == .error { #expect(value.style == .error) }
    }

    @Test("VPN guidance attaches only to the successful empty Ports projection")
    func vpnGuidanceTargetsSuccessfulEmptyState() throws {
        let empty = try #require(nodes(link: .connected, desktop: false).first {
            if case .placeholder = $0.kind { return $0.id.hasSuffix("/ports/status") }
            return false
        })
        #expect(empty.isPortsEmptyPlaceholder)

        let failed = try #require(nodes(link: .error, desktop: false).first {
            if case .placeholder = $0.kind { return $0.id.hasSuffix("/ports/status") }
            return false
        })
        #expect(!failed.isPortsEmptyPlaceholder)
    }

    @Test("Shell-only machines do not invent a desktop")
    func noDesktopForBaseMachine() {
        #expect(!nodes(link: .connected, desktop: false).contains {
            if case .display = $0.kind { return true }
            return false
        })
    }

    @Test("Cloud workspaces disappear on the last terminal move or close and return on creation", arguments: [false, true])
    @MainActor
    func workspaceVisibilityFollowsDaemonChanges(incremental: Bool) throws {
        let catalog = SurfaceCatalog()
        let provider = CloudPlacementTestProvider(machine: machine)
        catalog.register(provider)
        let initial = try visibilityState()
        publishVisibility(initial, to: catalog, incremental: false)
        #expect(workspaceIDs(catalog.snapshot) == ["ws_side"])

        // Repro: the focused, empty workspace acquires a terminal, which then
        // moves into another workspace while the original daemon record survives.
        try updateVisibility([
            ["kind": "upsert", "resource": "tab", "id": "tab_new", "value": terminalTab(pane: "pane_main")],
            ["kind": "upsert", "resource": "terminal", "id": "term_new", "value": [
                "id": "term_new", "title": "New shell", "lifecycle": "running"
            ]]
        ], in: catalog, incremental: incremental)
        #expect(workspaceIDs(catalog.snapshot) == ["ws_main", "ws_side"])
        let created = catalog.snapshot
        let localWorkspace = UUID()
        let terminalID = SurfaceResourceID(machine: machine, kind: .terminal, key: "term_new")
        catalog.record(SurfaceProjection(
            resource: terminalID, workspaceID: localWorkspace, panelID: UUID(),
            remoteWorkspaceID: "ws_main", remoteTabID: "tab_new"
        ))
        let openRow = try #require(workspaceRows(catalog.snapshot).first { $0.searchableTitle == "main" })
        guard case .workspace(_, let workspace, let count, _, let openIn) = openRow.kind else {
            Issue.record("Expected the created workspace row")
            return
        }
        #expect(workspace.focused && count == 1 && openIn == localWorkspace)

        try updateVisibility([
            ["kind": "upsert", "resource": "tab", "id": "tab_new", "value": terminalTab(pane: "pane_side")]
        ], in: catalog, incremental: incremental)
        #expect(workspaceIDs(catalog.snapshot) == ["ws_side"], "stale local projections and daemon focus cannot keep an empty row")
        #expect(CloudTreeNodeBuilder.structureSignature(visibilityNodes(created)) !=
            CloudTreeNodeBuilder.structureSignature(visibilityNodes(catalog.snapshot)))
        #expect(catalog.cloudStates[machine]?.workspaces.first?.focused == true)
        #expect(CloudTreeNodeBuilder.lookupRemoteWorkspace("ws_main", on: machine, snapshot: catalog.snapshot) ==
            .found(workspace, .none))

        try updateVisibility([
            ["kind": "delete", "resource": "tab", "id": "tab_existing"],
            ["kind": "delete", "resource": "terminal", "id": "term_existing"]
        ], in: catalog, incremental: incremental)
        #expect(workspaceIDs(catalog.snapshot) == ["ws_side"], "removing one of two terminals keeps the workspace")
        try updateVisibility([
            ["kind": "delete", "resource": "tab", "id": "tab_new"]
        ], in: catalog, incremental: incremental)
        #expect(workspaceRows(catalog.snapshot).isEmpty)
        #expect(catalog.resources[terminalID]?.remoteViews == [])
        #expect(CloudTreeNodeBuilder.flattened(visibilityNodes(catalog.snapshot)).contains {
            $0.id == CloudTreeNodeBuilder.nodeID(resource: terminalID)
        }, "detaching a terminal preserves its process in the machine pool")
        #expect(catalog.cloudStates[machine]?.workspaces.count == 2)
        #expect(CloudTreeNodeBuilder.flattened(visibilityNodes(catalog.snapshot)).contains {
            $0.id == CloudTreeNodeBuilder.nodeID(workspacesPlaceholder: machine)
        })

        try updateVisibility([
            ["kind": "upsert", "resource": "tab", "id": "tab_new", "value": terminalTab(pane: "pane_main")]
        ], in: catalog, incremental: incremental)
        #expect(workspaceIDs(catalog.snapshot) == ["ws_main"])
        let returned = try #require(catalog.resources[terminalID])
        // Terminal kill and accepted create receipts update resources before the
        // next complete graph; both must update visibility without a fleet poll.
        catalog.remove(terminalID, from: provider)
        #expect(catalog.resources[terminalID] == nil)
        #expect(workspaceRows(catalog.snapshot).isEmpty)
        catalog.upsert(returned, from: provider)
        #expect(workspaceIDs(catalog.snapshot) == ["ws_main"])
        publishVisibility(try #require(catalog.cloudStates[machine]), to: catalog, incremental: false)
        #expect(workspaceIDs(catalog.snapshot) == ["ws_main"], "a full refresh agrees with the event stream")
    }

    @Test("Visibility preserves workspace metadata and nonterminal content")
    @MainActor
    func nonterminalWorkspacesKeepVisiblePersistentState() throws {
        let catalog = SurfaceCatalog()
        var document = try #require(visibilityState().snapshotObject())
        document["terminals"] = [] as [[String: Any]]
        document["tabs"] = [
            ["id": "tab_docs", "pane_id": "pane_main", "content_kind": "browser", "content_id": "docs"],
            ["id": "tab_desktop", "pane_id": "pane_side", "content_kind": "display", "content_id": "display:1"]
        ]
        document["browsers"] = [["id": "docs", "tab_id": "tab_docs", "title": "Docs", "url": "https://cmux.com/docs"]]
        let state = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: document, machine: machine))
        publishVisibility(state, to: catalog, incremental: false)
        let before = catalog.snapshot
        #expect(workspaceIDs(catalog.snapshot) == ["ws_main", "ws_side"])
        #expect(catalog.snapshot == before && catalog.cloudStates[machine] == state, "visibility never deletes persistent state")
        #expect(try catalog.remoteWorkspaceGroup(machine: machine, workspaceID: "ws_main").placements.count == 1)
        #expect(try catalog.remoteWorkspaceGroup(machine: machine, workspaceID: "ws_side").placements.count == 1)
    }

    @Test("Workspace visibility counts retained and legacy terminal placements", arguments: [
        SurfaceLifecycle.launching, .running, .exited, .unavailable
    ])
    @MainActor
    func retainedAndLegacyTerminalsRemainVisible(lifecycle: SurfaceLifecycle) throws {
        let catalog = SurfaceCatalog()
        let provider = CloudPlacementTestProvider(machine: machine)
        catalog.register(provider)
        publishVisibility(try visibilityState(), to: catalog, incremental: false)
        var terminal = try #require(catalog.snapshot.resources.first { $0.kind == .terminal })
        terminal.lifecycle = lifecycle
        terminal.remoteViews = nil
        catalog.upsert(terminal, from: provider)
        #expect(workspaceIDs(catalog.snapshot) == ["ws_side"], "retained terminal output is valid workspace content")
        terminal.remoteViews = []
        catalog.upsert(terminal, from: provider)
        #expect(catalog.resources[terminal.id]?.remoteViews == [])
        #expect(workspaceRows(catalog.snapshot).isEmpty, "explicit detachment overrides a legacy workspace hint")
    }

    private func visibilityState() throws -> CloudVMState {
        let ids = ["main", "side"]
        let document: [String: Any] = [
            "cursor": ["generation": "visibility", "revision": "1"],
            "workspaces": ids.enumerated().map {
                ["id": "ws_\($0.element)", "name": $0.element, "index": $0.offset, "focused": $0.offset == 0] as [String: Any]
            },
            "screens": ids.map { ["id": "screen_\($0)", "workspace_id": "ws_\($0)"] },
            "panes": ids.map { ["id": "pane_\($0)", "screen_id": "screen_\($0)"] },
            "tabs": [["id": "tab_existing", "pane_id": "pane_side", "content_kind": "terminal", "content_id": "term_existing"]],
            "terminals": [["id": "term_existing", "title": "Existing shell", "lifecycle": "running"]],
            "browsers": [], "agents": []
        ]
        return try #require(CmuxTuiSnapshotParser.state(fromSnapshot: document, machine: machine))
    }

    private func terminalTab(pane: String) -> [String: Any] {
        ["id": "tab_new", "pane_id": pane, "content_kind": "terminal", "content_id": "term_new"]
    }

    @MainActor
    private func updateVisibility(_ changes: [[String: Any]], in catalog: SurfaceCatalog, incremental: Bool) throws {
        let previous = try #require(catalog.cloudStates[machine])
        let cursor = try #require(previous.cursor)
        let next = CloudVMCursor(generation: cursor.generation, revision: cursor.revision + 1)
        let delta: [String: Any] = [
            "kind": "delta", "previous_revision": String(cursor.revision), "revision": String(next.revision),
            "changes": changes
        ]
        let state = try #require(CmuxTuiSnapshotParser.applying(
            deltaPayload: JSONSerialization.data(withJSONObject: delta), cursor: next, to: previous
        ))
        publishVisibility(state, to: catalog, incremental: incremental)
    }

    @MainActor
    private func publishVisibility(_ state: CloudVMState, to catalog: SurfaceCatalog, incremental: Bool) {
        let info = SurfaceMachineInfo(
            id: machine, name: machine.rawValue, status: "running", image: nil, hasDesktop: true,
            memoryMb: nil, diskMb: nil, linkState: .connected, linkError: nil,
            cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil,
            remoteWorkspaces: state.workspaces.map {
                SurfaceRemoteWorkspace(id: $0.id, name: $0.name, index: $0.index, focused: $0.focused)
            }
        )
        let resources = CmuxTuiSnapshotParser.resources(from: state)
        if incremental { catalog.applyCloudStateDelta(state, resources: resources, info: info) }
        else { catalog.replaceCloudState(state, resources: resources, info: info) }
    }

    private func visibilityNodes(_ snapshot: SurfaceCatalogSnapshot) -> [CloudTreeNode] {
        CloudTreeNodeBuilder.nodes(machines: [], snapshot: snapshot, localWorkspaces: [], includeLocalMachine: false)
    }

    private func workspaceRows(_ snapshot: SurfaceCatalogSnapshot) -> [CloudTreeNode] {
        CloudTreeNodeBuilder.flattened(visibilityNodes(snapshot)).filter { $0.structureTag == "workspace" }
    }

    private func workspaceIDs(_ snapshot: SurfaceCatalogSnapshot) -> [String] {
        workspaceRows(snapshot).compactMap {
            if case .workspace(_, let workspace, _, _, _) = $0.kind { return workspace.id }
            return nil
        }
    }
}
