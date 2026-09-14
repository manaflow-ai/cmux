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

    @Test("Closing a desktop pane removes only its workspace tab after the authoritative delta", arguments: ["display", "screen"])
    func closeDesktopPane(contentKind: String) async throws {
        let localWorkspace = UUID(), panel = UUID()
        let coordinator = CloudPlacementCoordinator(binding: { id in
            id == localWorkspace
                ? WorkspaceCloudVMBinding(vmID: "membership-test", isBase: false, remoteWorkspaceID: "ws_a")
                : nil
        })
        let catalog = SurfaceCatalog(cloudPlacementCoordinator: coordinator)
        let provider = CloudPlacementTestProvider(machine: machine)
        catalog.register(provider)
        let initial = try state(desktops: ["desk_a": "a", "desk_b": "b"], contentKind: contentKind)
        publish(initial, to: catalog)
        let display = SurfaceResourceID(machine: machine, kind: .display, key: "display:1")
        catalog.record(SurfaceProjection(
            resource: display, workspaceID: localWorkspace, panelID: panel,
            remoteWorkspaceID: "ws_a", remoteTabID: "desk_a"
        ))
        publish(initial, to: catalog)
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

    @Test("Opening a machine display does not select or infer an unrelated daemon workspace")
    func displayPoolOpenHasNoImplicitTab() throws {
        let current = try state(desktops: ["desk_b": "b"])
        let display = try #require(resources(current).first { $0.id.key == "display:1" })
        #expect(CmuxTuiSurfaceProvider.defaultRemoteView(for: display) == nil)
        let terminal = try #require(resources(current).first { $0.id.key == "term_a" })
        #expect(CmuxTuiSurfaceProvider.defaultRemoteView(for: terminal)?.tabID == "tab_a")
        let rename = CloudWorkspaceRenameService()
        let projection = SurfaceProjection(resource: display.id, workspaceID: UUID(), panelID: UUID())
        #expect(rename.inferredRemoteWorkspaceTarget(projections: [projection], resources: [display]) == nil)
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

    @Test("Explicit local VNC panes belong only to their current bound workspace")
    func localDesktopMembership() async throws {
        let first = UUID(), second = UUID(), viewer = UUID()
        let coordinator = CloudPlacementCoordinator(binding: { id in
            guard id == first || id == second else { return nil }
            return WorkspaceCloudVMBinding(
                vmID: "membership-test", isBase: false,
                remoteWorkspaceID: id == first ? "ws_a" : "ws_b"
            )
        })
        let catalog = SurfaceCatalog(cloudPlacementCoordinator: coordinator)
        let provider = CloudPlacementTestProvider(machine: machine)
        catalog.register(provider)
        let current = try state(desktops: [:])
        publish(current, to: catalog)
        let desktop = SurfaceResourceID(machine: machine, kind: .display, key: "display:1")

        func desktopRows(in workspace: String) throws -> [CloudTreeNode] {
            let tree = CloudTreeNodeBuilder.flattened(CloudTreeNodeBuilder.nodes(
                machines: [], snapshot: catalog.snapshot, localWorkspaces: [], includeLocalMachine: false
            ))
            let row = try #require(tree.first { $0.id == CloudTreeNodeBuilder.nodeID(workspace: workspace, machine: machine) })
            let lookup = CloudTreeNodeBuilder.lookupRemoteWorkspace(workspace, on: machine, snapshot: catalog.snapshot)
            guard case .found(_, let members) = lookup else {
                Issue.record("Workspace lookup must resolve the sidebar workspace")
                return []
            }
            #expect(Set(row.dragGroup?.resources ?? []) == Set(members.ids))
            #expect(Set(try catalog.remoteWorkspaceGroup(machine: machine, workspaceID: workspace).resources) == Set(members.ids))
            return row.children.filter { if case .display = $0.kind { return true }; return false }
        }

        let opened = try await catalog.project(desktop, into: .workspace(id: first, placement: .split), focus: false)
        await coordinator.waitForPendingMutations()
        #expect(try desktopRows(in: "ws_a").count == 1)
        #expect(try desktopRows(in: "ws_b").isEmpty)
        let repeated = try await catalog.project(desktop, into: .workspace(id: first, placement: .split), focus: false)
        #expect(repeated.reused && repeated.projection.panelID == opened.projection.panelID)
        #expect(try desktopRows(in: "ws_a").count == 1)

        // Refresh replaces daemon rows, while the live local pane remains real.
        publish(current, to: catalog)
        #expect(try desktopRows(in: "ws_a").count == 1)
        catalog.moveProjections(panelID: opened.projection.panelID, to: second)
        await coordinator.waitForPendingMutations()
        #expect(try desktopRows(in: "ws_a").isEmpty)
        #expect(try desktopRows(in: "ws_b").count == 1)

        catalog.moveProjections(panelID: opened.projection.panelID, to: viewer)
        await coordinator.waitForPendingMutations()
        #expect(try desktopRows(in: "ws_a").isEmpty)
        #expect(try desktopRows(in: "ws_b").isEmpty)
        catalog.moveProjections(panelID: opened.projection.panelID, to: first)
        await coordinator.waitForPendingMutations()
        catalog.endProjections(panelID: opened.projection.panelID)
        await coordinator.waitForPendingMutations()
        try expectMembership(current, in: catalog)
        #expect(provider.closedTabs.isEmpty, "a local VNC view has no daemon tab to close")
    }

    @Test("Workspace groups open live local displays and reject a closed placement")
    func localDisplayGroupOpen() async throws {
        let source = UUID(), viewer = UUID()
        let coordinator = CloudPlacementCoordinator(binding: { id in
            id == source ? WorkspaceCloudVMBinding(vmID: "membership-test", isBase: false, remoteWorkspaceID: "ws_a") : nil
        })
        let catalog = SurfaceCatalog(cloudPlacementCoordinator: coordinator)
        catalog.register(CloudPlacementTestProvider(machine: machine))
        publish(try state(desktops: ["desk_b": "b"]), to: catalog)
        let desktop = SurfaceResourceID(machine: machine, kind: .display, key: "display:1")
        let original = try await catalog.project(desktop, into: .workspace(id: source, placement: .split), focus: false)
        let group = SurfaceResourceGroup(title: "Desktop", placements: [
            SurfaceResourcePlacement(resource: desktop, remoteWorkspaceID: "ws_a")
        ])
        let opened = try await catalog.projectGroup(
            group, into: .workspace(id: viewer, placement: .split), focus: false, paneLookup: { _, _ in nil }
        )
        #expect(opened.map(\.resource) == [desktop])
        #expect(catalog.projection(forPanel: opened[0].panelID)?.remoteWorkspaceID == nil)
        catalog.endProjections(panelID: original.projection.panelID)
        await coordinator.waitForPendingMutations()
        await #expect(throws: (any Error).self) {
            try await catalog.projectGroup(
                group, into: .workspace(id: viewer, placement: .split), focus: false, paneLookup: { _, _ in nil }
            )
        }
    }

    @Test("A local VNC pane never adopts or closes another workspace's daemon tab")
    func localDesktopBesideRemotePlacement() async throws {
        let workspace = UUID()
        let coordinator = CloudPlacementCoordinator(binding: { _ in
            WorkspaceCloudVMBinding(vmID: "membership-test", isBase: false, remoteWorkspaceID: "ws_a")
        })
        let catalog = SurfaceCatalog(cloudPlacementCoordinator: coordinator)
        let provider = CloudPlacementTestProvider(machine: machine)
        catalog.register(provider)
        let current = try state(desktops: ["desk_b": "b"])
        publish(current, to: catalog)
        let desktop = SurfaceResourceID(machine: machine, kind: .display, key: "display:1")
        let opened = try await catalog.project(desktop, into: .workspace(id: workspace, placement: .split), focus: false)
        await coordinator.waitForPendingMutations()
        let projection = try #require(catalog.projection(forPanel: opened.projection.panelID))
        #expect(projection.remoteWorkspaceID == "ws_a")
        #expect(projection.remoteTabID == nil)
        #expect(provider.moved.isEmpty)
        catalog.endProjections(panelID: projection.panelID)
        await coordinator.waitForPendingMutations()
        #expect(provider.closedTabs.isEmpty)
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
