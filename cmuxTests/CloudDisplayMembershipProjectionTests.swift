import CmuxSurfaceCatalogModel
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud display membership projection")
struct CloudDisplayMembershipProjectionTests {
    private let machine = SurfaceMachineID.cloud("display-membership-vm")
    private let workspaceID = "ws_cloud"
    private let displayID = "display:1"

    private func document(
        revision: Int,
        memberships: [[String: Any]] = [],
        display: String = "display:1",
        generation: String = "membership"
    ) -> [String: Any] {
        [
            "cursor": ["generation": generation, "revision": String(revision)],
            "workspaces": [["id": workspaceID, "name": "Cloud", "index": 0, "focused": true]],
            "screens": [["id": "screen_cloud", "workspace_id": workspaceID]],
            "panes": [["id": "pane_cloud", "screen_id": "screen_cloud"]],
            "tabs": [["id": "tab_terminal", "pane_id": "pane_cloud", "index": 0,
                       "focused": true, "content_kind": "terminal", "content_id": "term_cloud"]],
            "terminals": [["id": "term_cloud", "tab_id": "tab_terminal", "title": "terminal", "lifecycle": "running"]],
            "browsers": [],
            "agents": [],
            "frontend_projections": [[
                "id": "projection_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "session_id": "session_cloud",
                "frontend_id": "cmux-macos-cloud-layout-v1",
                "window_id": "cloud-workspace",
                "generation": "cmux-cloud-display-layout-v1",
                "projection_revision": "\(revision)",
                "projection": [
                    "schema": "cmux.cloud.workspace-displays.v1",
                    "machine_id": machine.rawValue,
                    "workspace_id": workspaceID,
                    "memberships": memberships,
                ],
            ]],
            "display_hint": display,
        ]
    }

    private func state(
        revision: Int = 1,
        memberships: [[String: Any]] = [["display_id": "display:1", "client_id": "mac-a", "view_id": "panel-a"]],
        generation: String = "membership"
    ) throws -> CloudVMState {
        try #require(CmuxTuiSnapshotParser.state(
            fromSnapshot: document(revision: revision, memberships: memberships, generation: generation),
            machine: machine
        ))
    }

    private func info(_ state: CloudVMState) -> SurfaceMachineInfo {
        SurfaceMachineInfo(
            id: machine, name: "Display VM", status: "running", image: nil, hasDesktop: true,
            memoryMb: nil, diskMb: nil, linkState: .connected, linkError: nil,
            cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil,
            remoteWorkspaces: state.workspaces.map {
                SurfaceRemoteWorkspace(id: $0.id, name: $0.name, index: $0.index, focused: $0.focused)
            }
        )
    }

    private func resources(_ state: CloudVMState) -> [SurfaceResource] {
        [CmuxTuiSnapshotParser.display(machine: machine),
         CmuxTuiSnapshotParser.resources(from: state).first { $0.kind == .terminal }].compactMap { $0 }
    }

    @Test("A frontend projection gives every client the same workspace display row")
    func sameAcceptedSnapshotProjectsOnTwoClients() throws {
        let state = try state()
        let resources = resources(state)
        let first = SurfaceCatalog()
        let second = SurfaceCatalog()
        first.replaceCloudState(state, resources: resources, info: info(state))
        second.replaceCloudState(state, resources: resources, info: info(state))
        for catalog in [first, second] {
            let tree = CloudTreeNodeBuilder.flattened(CloudTreeNodeBuilder.nodes(
                machines: [MachineSnapshot(id: machine.rawValue, provider: "test", image: "test", isDesktop: true, activity: .ready, createdAt: nil, label: "Display VM")],
                snapshot: catalog.snapshot, localWorkspaces: [], includeLocalMachine: false
            ))
            let workspace = try #require(tree.first { $0.id == CloudTreeNodeBuilder.nodeID(workspace: workspaceID, machine: machine) })
            #expect(workspace.children.contains { node in
                if case .display(let resource, _, _) = node.kind { return resource.id.key == displayID }
                return false
            })
            let pool = try #require(tree.first { $0.id == CloudTreeNodeBuilder.nodeID(displaysPool: machine) })
            #expect(pool.children.count == 1)
        }
    }

    @Test("Foreign and unknown display provenance stays out of workspace membership")
    func ownershipIsCheckedAtProjectionBoundary() throws {
        let state = try state(memberships: [
            ["display_id": "display:1", "client_id": "mac-a", "view_id": "panel-a"],
            ["display_id": "display:99", "client_id": "foreign-vm", "view_id": "panel-b"],
        ])
        let snapshot = SurfaceCatalogSnapshot(
            machines: [info(state)], resources: resources(state), projections: [],
            cloudDisplayMemberships: state.displayMemberships
        )
        let workspaceResources = snapshot.cloudWorkspaceResources(on: machine)
        #expect(workspaceResources.filter { $0.id.key == displayID }.count == 2)
        #expect(!workspaceResources.contains { $0.id.key == "display:99" })
    }

    @Test("Revision updates replace display membership and stale deltas cannot win")
    func revisionOrderingPreservesAcceptedProjection() throws {
        let initial = try state()
        let nextDocument = document(revision: 2, memberships: [], generation: "membership")
        let next = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: nextDocument, machine: machine))
        #expect(next.displayMemberships.isEmpty)
        #expect(CloudVMStateSyncDecision.forDelta(
            generation: "membership", previousRevision: 1, revision: 2, current: initial.cursor
        ) == .installSnapshot)
        #expect(CloudVMStateSyncDecision.forDelta(
            generation: "membership", previousRevision: 0, revision: 1, current: next.cursor
        ) == .ignoreStale)
        #expect(CloudVMStateSyncDecision.forSnapshot(incoming: initial.cursor, current: next.cursor) == .ignoreStale)
    }

    @Test("Reconnect keeps the durable membership while client view tokens change")
    func reconnectRetainsWorkspacePlacement() throws {
        let first = try state(memberships: [["display_id": displayID, "client_id": "mac-a", "view_id": "panel-a"]])
        let reconnected = try state(
            revision: 1,
            memberships: [["display_id": displayID, "client_id": "mac-b", "view_id": "panel-b"]],
            generation: "reconnected"
        )
        #expect(first.displayMemberships.first?.displayID == reconnected.displayMemberships.first?.displayID)
        #expect(first.displayMemberships.first?.workspaceID == reconnected.displayMemberships.first?.workspaceID)
        #expect(first.displayMemberships.first?.viewID != reconnected.displayMemberships.first?.viewID)
    }
}
