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

    @Test("Shell-only machines do not invent a desktop")
    func noDesktopForBaseMachine() {
        #expect(!nodes(link: .connected, desktop: false).contains {
            if case .display = $0.kind { return true }
            return false
        })
    }

    @MainActor
    @Test("A closed Cloud workspace stays absent after delayed machine metadata", arguments: [false, true])
    func closedWorkspaceDoesNotReappear(useDelta: Bool) throws {
        let catalog = SurfaceCatalog()
        let provider = CloudPlacementTestProvider(machine: machine)
        let initial = try workspaceState()
        let staleInfo = info(initial)
        provider.info = staleInfo
        catalog.register(provider)
        catalog.replaceCloudState(initial, resources: CmuxTuiSnapshotParser.resources(from: initial), info: staleInfo)
        #expect(terminalCounts(catalog.snapshot) == ["ws_quit": 2, "ws_empty": 0])

        // The daemon closes the terminals and their workspace. Consume the
        // authoritative deletion through the same parser and publication paths
        // as a live event or the next full refresh.
        let closed = try closingWorkspace(in: initial)
        let resources = CmuxTuiSnapshotParser.resources(from: closed)
        if useDelta {
            catalog.applyCloudStateDelta(closed, resources: resources, info: info(closed))
        } else {
            catalog.replaceCloudState(closed, resources: resources, info: info(closed))
        }
        try expectClosedWorkspace(in: catalog)

        // A summary captured before close can finish after the graph commit.
        // It still owns status/stats, but cannot create an empty workspace.
        var delayedInfo = staleInfo
        delayedInfo.cpuPercent = 42
        catalog.updateMachine(delayedInfo, from: provider)
        #expect(catalog.machines[machine]?.cpuPercent == 42)
        try expectClosedWorkspace(in: catalog)

        // Losing the connection must retain the accepted membership. Replacing
        // a provider with its old summary cannot resurrect the workspace either.
        catalog.markCloudStateStale(on: machine, reason: "reconnecting", info: staleInfo)
        try expectClosedWorkspace(in: catalog)
        catalog.replaceUnavailableCloudState(on: machine, resources: resources, info: staleInfo)
        try expectClosedWorkspace(in: catalog)
        let replacement = CloudPlacementTestProvider(machine: machine)
        replacement.info = staleInfo
        catalog.register(replacement)
        try expectClosedWorkspace(in: catalog)
    }

    @MainActor
    @Test("Graph publication does not adopt obsolete workspace rows from metadata", arguments: [false, true])
    func publicationOwnsWorkspaceMembership(useResourcePatch: Bool) throws {
        let catalog = SurfaceCatalog()
        let initial = try workspaceState()
        let staleInfo = info(initial)
        catalog.replaceCloudState(initial, resources: CmuxTuiSnapshotParser.resources(from: initial), info: staleInfo)
        let closed = try closingWorkspace(in: initial)
        if useResourcePatch {
            catalog.applyCloudStateResourcePatch(
                closed,
                resources: CmuxTuiSnapshotParser.resources(from: closed),
                affectedResourceIDs: Set(CmuxTuiSnapshotParser.resources(from: initial).map(\.id)),
                info: staleInfo
            )
        } else {
            catalog.replaceCloudState(closed, resources: CmuxTuiSnapshotParser.resources(from: closed), info: staleInfo)
        }
        try expectClosedWorkspace(in: catalog)
    }

    @MainActor
    @Test("New empty workspaces require graph ownership after the first snapshot")
    func emptyWorkspaceCreationFollowsTheGraph() throws {
        let catalog = SurfaceCatalog()
        let provider = CloudPlacementTestProvider(machine: machine)
        let initial = try workspaceState()
        provider.info = info(initial)
        catalog.register(provider)
        // Legacy providers can report membership before a graph is available.
        #expect(Set(terminalCounts(catalog.snapshot).keys) == ["ws_quit", "ws_empty"])
        let closed = try closingWorkspace(in: initial)
        catalog.replaceCloudState(closed, resources: [], info: info(closed))

        var provisional = info(closed)
        provisional.remoteWorkspaces?.append(SurfaceRemoteWorkspace(
            id: "ws_new", name: "work", index: 1, focused: false
        ))
        catalog.updateMachine(provisional, from: provider)
        try expectClosedWorkspace(in: catalog)

        // A genuinely new empty workspace (even with the closed one's name)
        // appears when the daemon publishes it. No name/empty-row filtering or
        // permanent deletion tombstones may prevent intentional recreation.
        var document = try #require(closed.snapshotObject())
        document["workspaces"] = [
            ["id": "ws_empty", "name": "scratch", "index": 0],
            ["id": "ws_new", "name": "work", "index": 1]
        ]
        document["cursor"] = ["generation": "sidebar", "revision": "3"]
        let created = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: document, machine: machine))
        catalog.replaceCloudState(created, resources: [], info: info(closed))
        #expect(terminalCounts(catalog.snapshot) == ["ws_empty": 0, "ws_new": 0])
        #expect(CloudTreeNodeBuilder.lookupRemoteWorkspace("work", on: machine, snapshot: catalog.snapshot)
            == .found(SurfaceRemoteWorkspace(id: "ws_new", name: "work", index: 1, focused: false), .none))
    }

    private func workspaceState() throws -> CloudVMState {
        let document: [String: Any] = [
            "cursor": ["generation": "sidebar", "revision": "1"],
            "workspaces": [
                ["id": "ws_quit", "name": "work", "index": 0, "focused": true],
                ["id": "ws_empty", "name": "scratch", "index": 1, "focused": false]
            ],
            "screens": [["id": "screen_quit", "workspace_id": "ws_quit"]],
            "panes": [["id": "pane_quit", "screen_id": "screen_quit"]],
            "tabs": ["a", "b"].map {
                ["id": "tab_\($0)", "pane_id": "pane_quit", "content_kind": "terminal", "content_id": "term_\($0)"]
            },
            "terminals": ["a", "b"].map {
                ["id": "term_\($0)", "tab_id": "tab_\($0)", "title": "shell", "lifecycle": "running"]
            },
            "browsers": [], "agents": []
        ]
        return try #require(CmuxTuiSnapshotParser.state(fromSnapshot: document, machine: machine))
    }

    private func closingWorkspace(in state: CloudVMState) throws -> CloudVMState {
        let deleted: [(String, String)] = [
            ("tab", "tab_a"), ("tab", "tab_b"), ("terminal", "term_a"), ("terminal", "term_b"),
            ("pane", "pane_quit"), ("screen", "screen_quit"), ("workspace", "ws_quit")
        ]
        let delta: [String: Any] = [
            "kind": "delta", "previous_revision": "1", "revision": "2",
            "changes": deleted.map { ["kind": "delete", "resource": $0.0, "id": $0.1] }
        ]
        return try #require(CmuxTuiSnapshotParser.applying(
            deltaPayload: JSONSerialization.data(withJSONObject: delta),
            cursor: CloudVMCursor(generation: "sidebar", revision: 2),
            to: state
        ))
    }

    private func info(_ state: CloudVMState) -> SurfaceMachineInfo {
        SurfaceMachineInfo(
            id: machine, name: machine.rawValue, status: "running", image: nil,
            hasDesktop: false, memoryMb: nil, diskMb: nil, linkState: .connected,
            linkError: nil, cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil,
            remoteWorkspaces: state.workspaces.map {
                SurfaceRemoteWorkspace(id: $0.id, name: $0.name, index: $0.index, focused: $0.focused)
            }
        )
    }

    private func terminalCounts(_ snapshot: SurfaceCatalogSnapshot) -> [String: Int] {
        let tree = CloudTreeNodeBuilder.flattened(CloudTreeNodeBuilder.nodes(
            machines: [], snapshot: snapshot, localWorkspaces: [], includeLocalMachine: false
        ))
        var counts: [String: Int] = [:]
        for node in tree {
            if case .workspace(_, let workspace, let count, _, _) = node.kind {
                counts[workspace.id] = count
            }
        }
        return counts
    }

    @MainActor
    private func expectClosedWorkspace(in catalog: SurfaceCatalog) throws {
        let snapshot = catalog.snapshot
        #expect(terminalCounts(snapshot) == ["ws_empty": 0])
        #expect(CloudTreeNodeBuilder.lookupRemoteWorkspace("ws_quit", on: machine, snapshot: snapshot) == .notFound)
        #expect(CloudTreeNodeBuilder.lookupRemoteWorkspace("work", on: machine, snapshot: snapshot) == .notFound)
        #expect(throws: (any Error).self) {
            try catalog.remoteWorkspaceGroup(machine: machine, workspaceID: "ws_quit")
        }
        let state = try #require(catalog.cloudStates[machine])
        #expect(state.workspaces.map(\.id) == ["ws_empty"])
        #expect(state.terminals.isEmpty)
    }
}
