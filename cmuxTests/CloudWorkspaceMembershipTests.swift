import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Exercise the daemon graph -> catalog -> outline path, including the normal
/// pane-close callback. Available machine displays never imply workspace tabs.
@MainActor
@Suite
struct CloudWorkspaceMembershipTests {
    private let machine = SurfaceMachineID.cloud("membership-test")

    @Test("Terminal-only workspaces do not inherit available machine displays")
    func terminalOnlyCreation() throws {
        let catalog = SurfaceCatalog()
        let initial = try state(desktops: [:])
        publish(initial, to: catalog)
        try expectMembership(initial, in: catalog)
        #expect(catalog.snapshot.resources(on: machine).filter { $0.kind == .display }.count == 2)

        // A newly created workspace comes from the next complete daemon graph.
        var document = try #require(initial.snapshotObject())
        document["workspaces"] = (document["workspaces"] as? [[String: Any]] ?? []) + [
            ["id": "ws_new", "name": "workspace-3", "index": 2]
        ]
        document["screens"] = (document["screens"] as? [[String: Any]] ?? []) + [
            ["id": "screen_new", "workspace_id": "ws_new"]
        ]
        document["panes"] = (document["panes"] as? [[String: Any]] ?? []) + [
            ["id": "pane_new", "screen_id": "screen_new"]
        ]
        document["tabs"] = (document["tabs"] as? [[String: Any]] ?? []) + [
            ["id": "tab_new", "pane_id": "pane_new", "content_kind": "terminal", "content_id": "term_new"]
        ]
        document["terminals"] = (document["terminals"] as? [[String: Any]] ?? []) + [
            ["id": "term_new", "tab_id": "tab_new", "title": "terminal", "lifecycle": "running"]
        ]
        document["cursor"] = ["generation": "membership", "revision": "2"]
        let created = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: document, machine: machine))
        publish(created, to: catalog)
        try expectMembership(created, in: catalog)
    }

    @Test("Closing a desktop pane removes only its workspace tab after the authoritative delta")
    func closeDesktopPane() async throws {
        let localWorkspace = UUID(), panel = UUID()
        let coordinator = CloudPlacementCoordinator(binding: { id in
            id == localWorkspace
                ? WorkspaceCloudVMBinding(vmID: "membership-test", isBase: false, remoteWorkspaceID: "ws_a")
                : nil
        })
        let catalog = SurfaceCatalog(cloudPlacementCoordinator: coordinator)
        let provider = CloudPlacementTestProvider(machine: machine)
        catalog.register(provider)
        let initial = try state(desktops: ["desk_a": "a", "desk_b": "b"])
        publish(initial, to: catalog)
        let display = SurfaceResourceID(machine: machine, kind: .display, key: "display:1")
        catalog.record(SurfaceProjection(
            resource: display, workspaceID: localWorkspace, panelID: panel,
            remoteWorkspaceID: "ws_a", remoteTabID: "desk_a"
        ))
        try expectMembership(initial, in: catalog)

        catalog.endProjections(panelID: panel)
        await coordinator.waitForPendingMutations()
        #expect(provider.closedTabs == ["desk_a"])
        #expect(catalog.projection(forPanel: panel) == nil)
        let closed = try removing("desk_a", from: initial)
        publish(closed, to: catalog, delta: true)
        try expectMembership(closed, in: catalog)
        #expect(catalog.resources[display]?.remoteViews?.map(\.tabID) == ["desk_b"])

        // Closing the last placement keeps the machine display discoverable.
        let detached = try removing("desk_b", from: closed)
        publish(detached, to: catalog, delta: true)
        try expectMembership(detached, in: catalog)
        #expect(catalog.resources[display] != nil)
        #expect(catalog.resources[display]?.remoteWorkspaces.isEmpty == true)
    }

    @Test("Refresh, reconnect and focus changes preserve exact display membership", arguments: ["display", "screen"])
    func authoritativeReconciliation(contentKind: String) throws {
        let catalog = SurfaceCatalog()
        let initial = try state(desktops: ["desk_a": "a"], contentKind: contentKind)
        publish(initial, to: catalog)
        let removed = try removing("desk_a", from: initial)
        publish(removed, to: catalog, delta: true)
        try expectMembership(removed, in: catalog)

        catalog.markCloudStateStale(on: machine, reason: "reconnecting")
        try expectMembership(removed, in: catalog)
        // A late fleet summary must not put old placement information back.
        catalog.updateMachine(info(initial))
        try expectMembership(removed, in: catalog)
        publish(removed, to: catalog)
        try expectMembership(removed, in: catalog)

        // A new daemon generation places the desktop only in B. Repeated full
        // snapshots and switching workspace focus cannot copy or duplicate it.
        for focused in ["b", "a", "b"] {
            let reconnected = try state(
                desktops: ["desk_reopened": "b"], contentKind: contentKind,
                generation: "reconnected", focused: focused
            )
            publish(reconnected, to: catalog)
            publish(reconnected, to: catalog)
            try expectMembership(reconnected, in: catalog)
        }
    }

    @Test("An explicit empty view list overrides stale legacy workspace metadata")
    func detachedDisplayDoesNotUseLegacyWorkspace() throws {
        let catalog = SurfaceCatalog()
        let current = try state(desktops: [:])
        var resources = resources(current)
        let index = try #require(resources.firstIndex { $0.kind == .display })
        resources[index].remoteViews = []
        resources[index].remoteWorkspace = info(current).remoteWorkspaces?.first
        catalog.replaceCloudState(current, resources: resources, info: info(current))
        try expectMembership(current, in: catalog)
    }

    private func state(
        desktops: [String: String], contentKind: String = "display",
        generation: String = "membership", focused: String = "a"
    ) throws -> CloudVMState {
        let workspaceIDs = ["a", "b"]
        var tabs: [[String: Any]] = workspaceIDs.map {
            ["id": "tab_\($0)", "pane_id": "pane_\($0)", "content_kind": "terminal", "content_id": "term_\($0)", "index": 0]
        }
        tabs.append(["id": "tab_docs", "pane_id": "pane_a", "content_kind": "browser", "content_id": "docs", "index": 1])
        for (tabID, workspace) in desktops.sorted(by: { $0.key < $1.key }) {
            tabs.append(["id": tabID, "pane_id": "pane_\(workspace)", "content_kind": contentKind, "content_id": "display:1", "index": 2])
        }
        let document: [String: Any] = [
            "cursor": ["generation": generation, "revision": "1"],
            "workspaces": workspaceIDs.enumerated().map {
                ["id": "ws_\($0.element)", "name": "workspace-\($0.offset + 1)", "index": $0.offset, "focused": $0.element == focused] as [String: Any]
            },
            "screens": workspaceIDs.map { ["id": "screen_\($0)", "workspace_id": "ws_\($0)"] },
            "panes": workspaceIDs.map { ["id": "pane_\($0)", "screen_id": "screen_\($0)"] },
            "tabs": tabs,
            "terminals": workspaceIDs.map {
                ["id": "term_\($0)", "tab_id": "tab_\($0)", "title": "terminal", "lifecycle": "running"]
            },
            "browsers": [["id": "docs", "tab_id": "tab_docs", "title": "Docs", "url": "http://localhost:3000"]],
            "agents": []
        ]
        return try #require(CmuxTuiSnapshotParser.state(fromSnapshot: document, machine: machine))
    }

    private func removing(_ tabID: String, from state: CloudVMState) throws -> CloudVMState {
        let previous = try #require(state.cursor)
        let cursor = CloudVMCursor(generation: previous.generation, revision: previous.revision + 1)
        let delta: [String: Any] = [
            "kind": "delta", "previous_revision": String(previous.revision), "revision": String(cursor.revision),
            "changes": [["kind": "delete", "resource": "tab", "id": tabID]]
        ]
        return try #require(CmuxTuiSnapshotParser.applying(
            deltaPayload: JSONSerialization.data(withJSONObject: delta), cursor: cursor, to: state
        ))
    }

    private func info(_ state: CloudVMState) -> SurfaceMachineInfo {
        SurfaceMachineInfo(
            id: machine, name: "Membership test", status: "running", image: nil, hasDesktop: true,
            memoryMb: nil, diskMb: nil, linkState: .connected, linkError: nil,
            cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil,
            remoteWorkspaces: state.workspaces.map {
                SurfaceRemoteWorkspace(id: $0.id, name: $0.name, index: $0.index, focused: $0.focused)
            }
        )
    }

    private func resources(_ state: CloudVMState) -> [SurfaceResource] {
        CmuxTuiSnapshotParser.mergingDisplays(
            pool: ["display:1", "display:2"].map { CmuxTuiSnapshotParser.display(machine: machine, key: $0) },
            parsed: CmuxTuiSnapshotParser.resources(from: state)
        )
    }

    private func publish(_ state: CloudVMState, to catalog: SurfaceCatalog, delta: Bool = false) {
        if delta {
            catalog.applyCloudStateDelta(state, resources: resources(state), info: info(state))
        } else {
            catalog.replaceCloudState(state, resources: resources(state), info: info(state))
        }
    }

    private func expectMembership(_ state: CloudVMState, in catalog: SurfaceCatalog) throws {
        let tree = CloudTreeNodeBuilder.flattened(CloudTreeNodeBuilder.nodes(
            machines: [], snapshot: catalog.snapshot, localWorkspaces: [], includeLocalMachine: false
        ))
        for workspace in state.workspaces {
            let row = try #require(tree.first { $0.id == CloudTreeNodeBuilder.nodeID(workspace: workspace.id, machine: machine) })
            let screens = Set(state.screens.filter { $0.workspaceID == workspace.id }.map(\.id))
            let panes = Set(state.panes.filter { screens.contains($0.screenID) }.map(\.id))
            let actualTabs = state.tabs.filter { panes.contains($0.paneID) }
            let rowTabIDs: [String] = row.children.compactMap {
                switch $0.kind {
                case .terminal(let value): return value.remoteView?.tabID
                case .browser(let value): return value.remoteView?.tabID
                case .display(_, _, let view): return view?.tabID
                default: return nil
                }
            }
            #expect(row.children.count == actualTabs.count, "\(workspace.id) children must equal real layout tabs")
            #expect(Set(rowTabIDs) == Set(actualTabs.map(\.id)))
            #expect(row.children.allSatisfy { $0.children.isEmpty })
            #expect(row.dragGroup?.placements.count == row.children.count)
        }
        let displays = try #require(tree.first { $0.id == CloudTreeNodeBuilder.nodeID(displaysPool: machine) })
        #expect(displays.children.count == 2, "available displays remain at machine level")
    }
}
