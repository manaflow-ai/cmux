import CmuxCloud
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
        generation: String = "membership",
        frontendID: String = CloudVMDisplayMembership.projectionFrontendID,
        projectionGeneration: String = CloudVMDisplayMembership.projectionGeneration,
        windowID: String? = nil,
        sessionID: String? = nil
    ) -> [String: Any] {
        var snapshot: [String: Any] = [
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
                "frontend_id": frontendID,
                "window_id": windowID ?? CloudVMDisplayMembership.projectionWindowID(machine: machine, workspaceID: workspaceID),
                "generation": projectionGeneration,
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
        if let sessionID {
            snapshot["session"] = ["id": sessionID]
        }
        return snapshot
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

    @Test("Closing a display pane removes the display from its workspace for every client")
    func closedDisplayIsNotRebuiltFromAnyClientsToken() async throws {
        let catalog = SurfaceCatalog()
        let provider = CloudDisplayMembershipTestProvider(machine: machine)
        let stale = try state(revision: 1, memberships: [["display_id": displayID, "client_id": "mac-b", "view_id": "panel-b"]])
        catalog.register(provider)
        let coordinator = CloudPlacementCoordinator()
        let display = SurfaceResourceID(machine: machine, kind: .display, key: displayID)
        // Another client's view of the same display in the same workspace.
        let otherClients = SurfaceResourcePlacement(resource: display, remoteWorkspaceID: workspaceID,
                                                    cloudDisplayMembershipViewID: "panel-b")
        let pane = SurfaceProjection(resource: display, workspaceID: UUID(), panelID: UUID(),
                                     remoteWorkspaceID: workspaceID, remoteTabID: nil)
        #expect(!coordinator.isPendingClose(otherClients, on: machine))
        // Closed before this pane's own token reached the local graph.
        coordinator.projectionDidEnd(pane, reason: .paneClosed, catalog: catalog)
        #expect(coordinator.isPendingClose(otherClients, on: machine))
        #expect(await provider.removed.result == "\(displayID)@\(workspaceID)")
        await coordinator.enqueue(resource: display, catalog: catalog) { true }.value
        // A graph fetched before the removal landed still holds the other
        // client's token; it must not rebuild the pane.
        coordinator.settleClosedDisplays(stale, catalog: catalog)
        #expect(coordinator.isPendingClose(otherClients, on: machine))
        coordinator.settleClosedDisplays(try state(revision: 2, memberships: []), catalog: catalog)
        #expect(!coordinator.isPendingClose(otherClients, on: machine))
        #expect(coordinator.closedDisplays.isEmpty)
    }

    @Test("Opening the display here again lifts its removal")
    func reopenedDisplayLiftsTheFence() {
        let catalog = SurfaceCatalog()
        catalog.register(CloudDisplayMembershipTestProvider(machine: machine))
        let coordinator = CloudPlacementCoordinator()
        let display = SurfaceResourceID(machine: machine, kind: .display, key: displayID)
        let placement = SurfaceResourcePlacement(resource: display, remoteWorkspaceID: workspaceID,
                                                 cloudDisplayMembershipViewID: "panel-b")
        coordinator.projectionDidEnd(SurfaceProjection(resource: display, workspaceID: UUID(), panelID: UUID(),
                                                       remoteWorkspaceID: workspaceID, remoteTabID: nil),
                                     reason: .paneClosed, catalog: catalog)
        #expect(coordinator.isPendingClose(placement, on: machine))
        coordinator.syncCloudDisplayMembership(
            projection: SurfaceProjection(resource: display, workspaceID: UUID(), panelID: UUID(),
                                          remoteWorkspaceID: workspaceID, remoteTabID: nil),
            catalog: catalog)
        #expect(!coordinator.isPendingClose(placement, on: machine))
    }

    @Test("A display another client puts back after the removal is shown again")
    func reAddedByAnotherClientLiftsTheFence() async throws {
        let catalog = SurfaceCatalog()
        let provider = CloudDisplayMembershipTestProvider(machine: machine)
        catalog.register(provider)
        let coordinator = CloudPlacementCoordinator()
        let display = SurfaceResourceID(machine: machine, kind: .display, key: displayID)
        coordinator.projectionDidEnd(SurfaceProjection(resource: display, workspaceID: UUID(), panelID: UUID(),
                                                       remoteWorkspaceID: workspaceID, remoteTabID: nil),
                                     reason: .paneClosed, catalog: catalog)
        _ = await provider.removed.result
        await coordinator.enqueue(resource: display, catalog: catalog) { true }.value
        let readded = SurfaceResourcePlacement(resource: display, remoteWorkspaceID: workspaceID,
                                               cloudDisplayMembershipViewID: "panel-c")
        // A graph from before the removal.
        coordinator.settleClosedDisplays(try state(revision: 1, memberships: [
            ["display_id": displayID, "client_id": "mac-b", "view_id": "panel-b"]]), catalog: catalog)
        #expect(coordinator.isPendingClose(readded, on: machine))
        // Shown again in a graph after the removal: another client opened it.
        coordinator.settleClosedDisplays(try state(revision: 2, memberships: [
            ["display_id": displayID, "client_id": "mac-c", "view_id": "panel-c"]]), catalog: catalog)
        #expect(!coordinator.isPendingClose(readded, on: machine))
    }

    @Test("A removal that found nothing to delete still fences graphs older than it")
    func noOpRemovalKeepsOlderGraphsFenced() async throws {
        let catalog = SurfaceCatalog()
        let provider = CloudDisplayMembershipTestProvider(machine: machine)
        // The removal read revision 3, which already had no token for the display.
        provider.removalBasisRevision = 3
        catalog.register(provider)
        let coordinator = CloudPlacementCoordinator()
        let display = SurfaceResourceID(machine: machine, kind: .display, key: displayID)
        let placement = SurfaceResourcePlacement(resource: display, remoteWorkspaceID: workspaceID,
                                                 cloudDisplayMembershipViewID: "panel-b")
        coordinator.projectionDidEnd(SurfaceProjection(resource: display, workspaceID: UUID(), panelID: UUID(),
                                                       remoteWorkspaceID: workspaceID, remoteTabID: nil),
                                     reason: .paneClosed, catalog: catalog)
        _ = await provider.removed.result
        await coordinator.enqueue(resource: display, catalog: catalog) { true }.value
        coordinator.settleClosedDisplays(try state(revision: 2, memberships: [
            ["display_id": displayID, "client_id": "mac-b", "view_id": "panel-b"]]), catalog: catalog)
        #expect(coordinator.isPendingClose(placement, on: machine), "a stale graph must not rebuild the closed pane")
    }

    @Test("A graph published between the removal's read and its write stays fenced")
    func graphBeforeTheWriteLandsStaysFenced() async throws {
        let catalog = SurfaceCatalog()
        let provider = CloudDisplayMembershipTestProvider(machine: machine)
        // The removal read revision 3; an unrelated change made revision 4;
        // the removal's write landed at revision 5.
        provider.removalBasisRevision = 5
        catalog.register(provider)
        let coordinator = CloudPlacementCoordinator()
        let display = SurfaceResourceID(machine: machine, kind: .display, key: displayID)
        let placement = SurfaceResourcePlacement(resource: display, remoteWorkspaceID: workspaceID,
                                                 cloudDisplayMembershipViewID: "panel-b")
        coordinator.projectionDidEnd(SurfaceProjection(resource: display, workspaceID: UUID(), panelID: UUID(),
                                                       remoteWorkspaceID: workspaceID, remoteTabID: nil),
                                     reason: .paneClosed, catalog: catalog)
        _ = await provider.removed.result
        await coordinator.enqueue(resource: display, catalog: catalog) { true }.value
        coordinator.settleClosedDisplays(try state(revision: 4, memberships: [
            ["display_id": displayID, "client_id": "mac-b", "view_id": "panel-b"]]), catalog: catalog)
        #expect(coordinator.isPendingClose(placement, on: machine))
        coordinator.settleClosedDisplays(try state(revision: 6, memberships: [
            ["display_id": displayID, "client_id": "mac-c", "view_id": "panel-c"]]), catalog: catalog)
        #expect(!coordinator.isPendingClose(placement, on: machine), "a token after the write is a re-add")
    }

    @Test("Reopening a display while its close is still queued keeps the reopened pane")
    func reopenBeforeTheQueuedCloseRunsWins() async throws {
        let catalog = SurfaceCatalog()
        let provider = CloudDisplayMembershipTestProvider(machine: machine)
        catalog.register(provider)
        let coordinator = CloudPlacementCoordinator()
        let display = SurfaceResourceID(machine: machine, kind: .display, key: displayID)
        let placement = SurfaceResourcePlacement(resource: display, remoteWorkspaceID: workspaceID,
                                                 cloudDisplayMembershipViewID: "panel-b")
        // Hold the lane so the close queues behind earlier work, as on a slow machine.
        let release = CloudLinkFirstValue<Bool>()
        coordinator.enqueue(resource: display, catalog: catalog) { _ = await release.result; return true }
        coordinator.projectionDidEnd(SurfaceProjection(resource: display, workspaceID: UUID(), panelID: UUID(),
                                                       remoteWorkspaceID: workspaceID, remoteTabID: nil),
                                     reason: .paneClosed, catalog: catalog)
        coordinator.syncCloudDisplayMembership(
            projection: SurfaceProjection(resource: display, workspaceID: UUID(), panelID: UUID(),
                                          remoteWorkspaceID: workspaceID, remoteTabID: nil),
            catalog: catalog)
        release.resolve(true)
        await coordinator.enqueue(resource: display, catalog: catalog) { true }.value
        #expect(provider.removals == 0, "the queued close must not remove the reopened display")
        #expect(!coordinator.isPendingClose(placement, on: machine))
    }

    @Test("A workspace display with its own local pane is one sidebar row")
    func memberDisplayWithLocalPaneIsListedOnce() throws {
        let state = try state()
        let catalog = SurfaceCatalog()
        catalog.replaceCloudState(state, resources: resources(state), info: info(state))
        // New Display: one pane in the workspace and the one membership token it wrote.
        catalog.record(SurfaceProjection(
            resource: SurfaceResourceID(machine: machine, kind: .display, key: displayID),
            workspaceID: UUID(), panelID: UUID(), remoteWorkspaceID: workspaceID
        ))
        let tree = CloudTreeNodeBuilder.flattened(CloudTreeNodeBuilder.nodes(
            machines: [MachineSnapshot(id: machine.rawValue, provider: "test", image: "test", isDesktop: true, activity: .ready, createdAt: nil, label: "Display VM")],
            snapshot: catalog.snapshot, localWorkspaces: [], includeLocalMachine: false
        ))
        let workspace = try #require(tree.first { $0.id == CloudTreeNodeBuilder.nodeID(workspace: workspaceID, machine: machine) })
        let displayRows = workspace.children.filter { node in
            if case .display(let resource, _, _) = node.kind { return resource.id.key == displayID }
            return false
        }
        #expect(displayRows.count == 1)
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

    @Test("Workspace open retains the exact synthetic display membership identity")
    func workspaceGroupResolvesMembershipView() throws {
        let accepted = try state()
        let catalog = SurfaceCatalog()
        catalog.replaceCloudState(accepted, resources: resources(accepted), info: info(accepted))
        let group = try catalog.remoteWorkspaceGroup(machine: machine, workspaceID: workspaceID)
        let display = try #require(group.placements.first { $0.resource.kind == .display })
        #expect(display.cloudDisplayMembershipViewID == "panel-a")
        let view = try #require(try catalog.remoteView(for: display, fallbackWorkspaceID: workspaceID))
        #expect(view.isCloudDisplayMembershipView)
        #expect(view.cloudDisplayMembershipViewID == "panel-a")
    }

    @Test("Installing a newer snapshot replaces membership rows without touching the display pool")
    func catalogSnapshotRefreshReconcilesMembership() throws {
        let initial = try state()
        let catalog = SurfaceCatalog()
        catalog.replaceCloudState(initial, resources: resources(initial), info: info(initial))
        #expect(catalog.snapshot.cloudDisplayMemberships.count == 1)
        let next = try state(revision: 2, memberships: [])
        catalog.replaceCloudState(next, resources: resources(next), info: info(next))
        #expect(catalog.snapshot.cloudDisplayMemberships.isEmpty)
        #expect(catalog.snapshot.resources(on: machine).filter { $0.kind == .display }.count == 1)
        #expect(catalog.snapshot.cloudWorkspaceResources(on: machine).filter { $0.id.key == displayID }.count == 1)
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
        #expect(workspaceResources.last?.remoteViews?.first?.isCloudDisplayMembershipView == true)
        #expect(!workspaceResources.contains { $0.id.key == "display:99" })
    }

    @Test("Frontend provenance fences reject rows from another client implementation")
    func rejectsForeignProjectionProvenance() throws {
        for mutation in [
            ("frontend", document(revision: 1, memberships: [["display_id": displayID, "client_id": "mac-a", "view_id": "panel-a"]], frontendID: "other-frontend")),
            ("generation", document(revision: 1, memberships: [["display_id": displayID, "client_id": "mac-a", "view_id": "panel-a"]], projectionGeneration: "old-generation")),
            ("window", document(revision: 1, memberships: [["display_id": displayID, "client_id": "mac-a", "view_id": "panel-a"]], windowID: "cloud-workspace:other-vm:ws_cloud")),
            ("session", document(revision: 1, memberships: [["display_id": displayID, "client_id": "mac-a", "view_id": "panel-a"]], sessionID: "other-session")),
        ] {
            let parsed = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: mutation.1, machine: machine))
            #expect(parsed.displayMemberships.isEmpty, "\(mutation.0) provenance must not enter the accepted state")
        }
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

/// Records membership writes; nothing else about the provider is exercised.
@MainActor
private final class CloudDisplayMembershipTestProvider: SurfaceProvider, CloudDisplayMembershipSyncing {
    let machine: SurfaceMachineID
    let info: SurfaceMachineInfo
    let removed = CloudLinkFirstValue<String>()

    init(machine: SurfaceMachineID) {
        self.machine = machine
        info = SurfaceMachineInfo(id: machine, name: machine.rawValue, status: "running", image: nil, hasDesktop: true,
                                  memoryMb: nil, diskMb: nil, linkState: .connected, linkError: nil,
                                  cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil)
    }

    func refresh() async {}
    func materialize(_ resource: SurfaceResource, at destination: SurfaceDestination, focus: Bool) async throws -> SurfaceProjection {
        throw SurfaceCatalogError.unsupported("materialize")
    }
    func materialize(_ resource: SurfaceResource, remoteView: SurfaceRemoteView?, at destination: SurfaceDestination,
                     focus: Bool) async throws -> SurfaceProjection {
        throw SurfaceCatalogError.unsupported("materialize")
    }
    func createTerminal(command: [String]?, cwd: String?, name: String?, remoteWorkspaceID: String?) async throws -> SurfaceResource {
        throw SurfaceCatalogError.unsupported("createTerminal")
    }
    func projectionDidEnd(_ projection: SurfaceProjection) {}

    func cloudDisplayMembershipWorkspace(displayID: String, panelID: UUID) async throws -> String? { nil }
    func syncCloudDisplayMembership(displayID: String, workspaceID: String, panelID: UUID, attached: Bool) async throws {}
    /// The revision the removal's write lands at.
    var removalBasisRevision: UInt64 = 1
    private(set) var removals = 0
    func removeCloudDisplay(displayID: String, fromWorkspace workspaceID: String) async throws -> CloudVMCursor? {
        removals += 1
        removed.resolve("\(displayID)@\(workspaceID)")
        return CloudVMCursor(generation: "membership", revision: removalBasisRevision)
    }
}
