import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A local workspace bound to a machine workspace mirrors it: panes moved in place their
/// tabs there, panes closed on purpose close their tabs, and the workspace closing leaves
/// the machine workspace alone.
@MainActor
@Suite
struct CloudPlacementCoordinatorTests {
    private static let machine = SurfaceMachineID.cloud("vivid-newt")
    private static let main = SurfaceRemoteWorkspace(id: "ws_main", name: "main", index: 0, focused: true)
    private static let api = SurfaceRemoteWorkspace(id: "ws_api", name: "api", index: 1, focused: false)

    private static func terminal(_ key: String, views: [SurfaceRemoteView]) -> SurfaceResource {
        SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .terminal, key: key),
            title: key, detail: "/root", lifecycle: .running, agent: nil,
            remoteWorkspace: views.first?.workspace, remoteViews: views, port: nil, url: nil
        )
    }

    /// A catalog whose local workspace `bound` mirrors `ws_api`; every other local workspace is a viewer.
    private static func harness(bound: UUID) -> (SurfaceCatalog, CloudPlacementTestProvider) {
        let catalog = SurfaceCatalog(cloudPlacementCoordinator: CloudPlacementCoordinator(binding: { id in
            id == bound ? WorkspaceCloudVMBinding(vmID: "vivid-newt", isBase: false, remoteWorkspaceID: "ws_api") : nil
        }, workspaceExists: { _, remoteID in remoteID == "ws_api" ? true : nil }))
        let provider = CloudPlacementTestProvider(machine: machine)
        catalog.register(provider)
        return (catalog, provider)
    }

    @Test func moveTabArgumentsUseTheProjectDestinationGrammar() {
        let target = CloudTuiTerminalProjectionTarget(workspaceID: "ws_api", screenID: "screen_2", paneID: "pane_2", index: 3)
        #expect(
            CloudTuiCommandLine.moveTabArguments(socketPath: "/k.sock", tabID: "tab_1", target: target, expectedRevision: "9", idempotencyKey: "placement-1") == [
                "--socket", "/k.sock", "--json", "tab", "tab_1", "move",
                "--workspace", "ws_api", "--screen", "screen_2", "--pane", "pane_2", "--index", "3",
                "--expected-revision", "9", "--idempotency-key", "placement-1",
            ]
        )
    }

    @Test func projectionTargetInsideAWorkspaceAppendsToItsFocusedPane() async throws {
        let snapshot: [String: Any] = [
            "cursor": ["generation": "g", "revision": "12"],
            "workspaces": [["id": "ws_main", "focused": true], ["id": "ws_api", "focused": false]],
            "screens": [["id": "screen_1", "workspace_id": "ws_main"], ["id": "screen_2", "workspace_id": "ws_api"]],
            "panes": [["id": "pane_1", "screen_id": "screen_1"], ["id": "pane_2", "screen_id": "screen_2"]],
            "tabs": [
                ["id": "tab_1", "pane_id": "pane_1", "content_kind": "terminal", "content_id": "term_a"],
                ["id": "tab_2", "pane_id": "pane_2", "content_kind": "terminal", "content_id": "term_b"],
                ["id": "tab_3", "pane_id": "pane_2", "content_kind": "terminal", "content_id": "term_c"],
            ],
            "terminals": [], "browsers": [], "agents": [],
        ]
        let inAPI = try #require(CmuxTuiSnapshotParser.projectionTarget(from: snapshot, inWorkspace: "ws_api"))
        #expect(inAPI == CloudTuiTerminalProjectionTarget(workspaceID: "ws_api", screenID: "screen_2", paneID: "pane_2", index: 2))
        #expect(CmuxTuiSnapshotParser.projectionTarget(from: snapshot, inWorkspace: "ws_gone") == nil)
        let data = try JSONSerialization.data(withJSONObject: snapshot)
        let preferred = try #require(await CmuxTuiSnapshotParser.terminalProjectionTarget(from: data, preferringWorkspace: "ws_api"))
        #expect(preferred.target.workspaceID == "ws_api" && preferred.revision == "12")
        #expect(await CmuxTuiSnapshotParser.terminalProjectionTarget(from: data, preferringWorkspace: "ws_gone") == nil)
        let fallback = try #require(await CmuxTuiSnapshotParser.terminalProjectionTarget(from: data, preferringWorkspace: nil))
        #expect(fallback.target.workspaceID == "ws_main")

    }

    @Test func aPaneMovedIntoTheMirroredWorkspaceMovesItsTabThere() async {
        let viewer = UUID(), bound = UUID(), panel = UUID()
        let (catalog, provider) = Self.harness(bound: bound)
        let term = Self.terminal("term_1", views: [SurfaceRemoteView(tabID: "tab_1", workspace: Self.main)])
        catalog.replaceResources([term], on: Self.machine)
        catalog.record(SurfaceProjection(resource: term.id, workspaceID: viewer, panelID: panel, remoteWorkspaceID: "ws_main", remoteTabID: "tab_1"))

        catalog.moveProjections(panelID: panel, to: bound)
        await catalog.cloudPlacementCoordinator.waitForPendingMutations()

        #expect(provider.moved.map { "\($0.tab)->\($0.workspace)" } == ["tab_1->ws_api"])
        #expect(provider.projected.isEmpty)
        let projection = catalog.projection(forPanel: panel)
        #expect(projection?.workspaceID == bound)
        #expect(projection?.remoteWorkspaceID == "ws_api" && projection?.remoteTabID == "tab_1")
    }

    @Test func aViewlessTerminalMovedIntoTheMirroredWorkspaceIsProjectedThere() async {
        let viewer = UUID(), bound = UUID(), panel = UUID()
        let (catalog, provider) = Self.harness(bound: bound)
        let pool = Self.terminal("term_pool", views: [])
        catalog.replaceResources([pool], on: Self.machine)
        catalog.record(SurfaceProjection(resource: pool.id, workspaceID: viewer, panelID: panel))

        catalog.moveProjections(panelID: panel, to: bound)
        await catalog.cloudPlacementCoordinator.waitForPendingMutations()

        #expect(provider.projected.map { "\($0.terminal)->\($0.workspace)" } == ["term_pool->ws_api"])
        #expect(provider.moved.isEmpty)
        #expect(catalog.projection(forPanel: panel)?.remoteWorkspaceID == "ws_api")
        #expect(catalog.projection(forPanel: panel)?.remoteTabID == "tab_projected")
    }

    @Test func aDisplayMovedIntoTheMirroredWorkspaceIsRecordedThereWithoutADaemonCall() async {
        let viewer = UUID(), bound = UUID(), panel = UUID()
        let (catalog, provider) = Self.harness(bound: bound)
        let display = CmuxTuiSnapshotParser.display(machine: Self.machine)
        catalog.replaceResources([display], on: Self.machine)
        catalog.record(SurfaceProjection(resource: display.id, workspaceID: viewer, panelID: panel))

        catalog.moveProjections(panelID: panel, to: bound)
        await catalog.cloudPlacementCoordinator.waitForPendingMutations()

        #expect(catalog.projection(forPanel: panel)?.remoteWorkspaceID == "ws_api")
        #expect(catalog.projection(forPanel: panel)?.remoteTabID == nil)
        #expect(provider.moved.isEmpty && provider.projected.isEmpty)
    }

    @Test func aPaneAlreadyInItsWorkspaceOrMovedIntoAViewerWorkspaceLeavesTheLayoutAlone() async {
        let viewer = UUID(), other = UUID(), bound = UUID()
        let (catalog, provider) = Self.harness(bound: bound)
        let term = Self.terminal("term_1", views: [SurfaceRemoteView(tabID: "tab_1", workspace: Self.api)])
        catalog.replaceResources([term], on: Self.machine)
        let inPlace = UUID(), viewing = UUID()
        catalog.record(SurfaceProjection(resource: term.id, workspaceID: viewer, panelID: inPlace, remoteWorkspaceID: "ws_api", remoteTabID: "tab_1"))
        catalog.record(SurfaceProjection(resource: term.id, workspaceID: viewer, panelID: viewing, remoteWorkspaceID: "ws_api", remoteTabID: "tab_1"))

        catalog.moveProjections(panelID: inPlace, to: bound)   // already in ws_api
        catalog.moveProjections(panelID: viewing, to: other)   // a viewer workspace
        await catalog.cloudPlacementCoordinator.waitForPendingMutations()

        #expect(provider.moved.isEmpty && provider.projected.isEmpty)
        #expect(catalog.projection(forPanel: inPlace)?.remoteWorkspaceID == "ws_api")
    }

    @Test func closingAPaneInTheMirroredWorkspaceClosesItsTab() async {
        let bound = UUID(), panel = UUID()
        let (catalog, provider) = Self.harness(bound: bound)
        let term = Self.terminal("term_1", views: [SurfaceRemoteView(tabID: "tab_1", workspace: Self.api)])
        catalog.replaceResources([term], on: Self.machine)
        catalog.record(SurfaceProjection(resource: term.id, workspaceID: bound, panelID: panel, remoteWorkspaceID: "ws_api", remoteTabID: "tab_1"))

        catalog.endProjections(panelID: panel)
        await catalog.cloudPlacementCoordinator.waitForPendingMutations()

        #expect(provider.closedTabs == ["tab_1"])
        #expect(catalog.projection(forPanel: panel) == nil)
        #expect(catalog.resources[term.id] != nil, "the terminal detaches; it is not killed")
    }

    @Test func teardownReplacementViewersAndASecondPaneKeepTheTab() async {
        let bound = UUID(), viewer = UUID()
        let (catalog, provider) = Self.harness(bound: bound)
        let term = Self.terminal("term_1", views: [SurfaceRemoteView(tabID: "tab_1", workspace: Self.api)])
        catalog.replaceResources([term], on: Self.machine)
        func project(_ workspace: UUID) -> UUID {
            let panel = UUID()
            catalog.record(SurfaceProjection(resource: term.id, workspaceID: workspace, panelID: panel, remoteWorkspaceID: "ws_api", remoteTabID: "tab_1"))
            return panel
        }

        // ⌘⇧W, a window closing, quit: the pane ends because its workspace does.
        catalog.endProjections(panelID: project(bound), reason: .workspaceTeardown)
        // A pane the catalog closes itself (a replaced placeholder, a race loser).
        let replaced = project(bound)
        catalog.endProjections(panelID: replaced, reason: .replaced)
        // A viewer pane outside the mirrored workspace.
        catalog.endProjections(panelID: project(viewer))
        // One of two mirrored panes showing the same tab.
        let first = project(bound), second = project(bound)
        catalog.endProjections(panelID: first)
        await catalog.cloudPlacementCoordinator.waitForPendingMutations()
        #expect(provider.closedTabs.isEmpty)

        // The last pane showing the tab closes it.
        catalog.endProjections(panelID: second)
        await catalog.cloudPlacementCoordinator.waitForPendingMutations()
        #expect(provider.closedTabs == ["tab_1"])
    }

    @Test func rapidMoveThenMoveThenCloseUsesTheConfirmedPlacement() async throws {
        let original = UUID(), bound = UUID(), panel = UUID()
        let coordinator = CloudPlacementCoordinator(binding: { id in
            WorkspaceCloudVMBinding(vmID: "vivid-newt", isBase: false, remoteWorkspaceID: id == bound ? "ws_api" : "ws_main")
        })
        let catalog = SurfaceCatalog(cloudPlacementCoordinator: coordinator)
        let provider = CloudPlacementTestProvider(machine: Self.machine)
        catalog.register(provider)
        let term = Self.terminal("term_1", views: [SurfaceRemoteView(tabID: "tab_1", workspace: Self.main)])
        catalog.replaceResources([term], on: Self.machine)
        catalog.record(SurfaceProjection(resource: term.id, workspaceID: original, panelID: panel, remoteWorkspaceID: "ws_main", remoteTabID: "tab_1"))
        let (started, start) = AsyncStream<Void>.makeStream()
        let (release, finish) = AsyncStream<Void>.makeStream()
        provider.beforeMutation = {
            provider.beforeMutation = nil
            start.yield(())
            start.finish()
            for await _ in release { break }
        }
        catalog.moveProjections(panelID: panel, to: bound)
        for await _ in started { break }
        catalog.moveProjections(panelID: panel, to: original)
        catalog.endProjections(panelID: panel)
        #expect(provider.events == ["move-start:ws_api"])
        finish.yield(())
        finish.finish()
        await coordinator.waitForPendingMutations()
        #expect(provider.events == ["move-start:ws_api", "move-end:ws_api", "move-start:ws_main", "move-end:ws_main", "close:tab_1"])
        #expect(catalog.projection(forPanel: panel) == nil)
    }

    @Test func closingDuringProjectionClosesTheCreatedTabWithoutKillingTheTerminal() async {
        let viewer = UUID(), bound = UUID(), panel = UUID()
        let (catalog, provider) = Self.harness(bound: bound)
        let terminal = Self.terminal("pool", views: [])
        catalog.replaceResources([terminal], on: Self.machine)
        catalog.record(SurfaceProjection(resource: terminal.id, workspaceID: viewer, panelID: panel))
        catalog.moveProjections(panelID: panel, to: bound)
        catalog.endProjections(panelID: panel)
        await catalog.cloudPlacementCoordinator.waitForPendingMutations()
        #expect(provider.projected.count == 1)
        #expect(provider.closedTabs == ["tab_projected"])
        #expect(catalog.resources[terminal.id] != nil)
    }

    @Test func failedMoveKeepsConfirmedCoordinatesAndReportsTheFailure() async {
        let viewer = UUID(), bound = UUID(), panel = UUID()
        var errors = 0
        let coordinator = CloudPlacementCoordinator(
            binding: { id in id == bound ? WorkspaceCloudVMBinding(vmID: "vivid-newt", isBase: false, remoteWorkspaceID: "ws_api") : nil },
            reportFailure: { _, _ in errors += 1 }
        )
        let catalog = SurfaceCatalog(cloudPlacementCoordinator: coordinator)
        let provider = CloudPlacementTestProvider(machine: Self.machine)
        catalog.register(provider)
        let term = Self.terminal("term_1", views: [SurfaceRemoteView(tabID: "tab_1", workspace: Self.main)])
        catalog.replaceResources([term], on: Self.machine)
        catalog.record(SurfaceProjection(resource: term.id, workspaceID: viewer, panelID: panel, remoteWorkspaceID: "ws_main", remoteTabID: "tab_1"))
        provider.beforeMutation = { throw SurfaceCatalogError.unsupported("offline") }
        catalog.moveProjections(panelID: panel, to: bound)
        await coordinator.waitForPendingMutations()
        #expect(catalog.projection(forPanel: panel)?.workspaceID == bound)
        #expect(catalog.projection(forPanel: panel)?.remoteWorkspaceID == "ws_main")
        #expect(coordinator.failures[term.id] != nil && errors == 1 && provider.refreshCount == 1)
        // Closing the failed move cannot close its tab in the original workspace.
        catalog.endProjections(panelID: panel)
        await coordinator.waitForPendingMutations()
        #expect(provider.closedTabs.isEmpty)
        #expect(coordinator.failures[term.id] != nil)
    }

    @Test func aMovedTabUpdatesEveryLocalViewAndBoundCreationIgnoresStaleFocus() async {
        let viewer = UUID(), bound = UUID(), panel = UUID(), other = UUID()
        let (catalog, provider) = Self.harness(bound: bound)
        let term = Self.terminal("term_1", views: [SurfaceRemoteView(tabID: "tab_1", workspace: Self.main)])
        catalog.replaceResources([term], on: Self.machine)
        for id in [panel, other] {
            catalog.record(SurfaceProjection(resource: term.id, workspaceID: viewer, panelID: id, remoteWorkspaceID: "ws_main", remoteTabID: "tab_1"))
        }
        catalog.moveProjections(panelID: panel, to: bound)
        #expect(catalog.cloudPlacementCoordinator.creationWorkspaceID(in: bound, near: term) == "ws_api")
        await catalog.cloudPlacementCoordinator.waitForPendingMutations()
        #expect(catalog.projection(forPanel: other)?.remoteWorkspaceID == "ws_api")
        catalog.endProjections(panelID: panel)
        await catalog.cloudPlacementCoordinator.waitForPendingMutations()
        #expect(provider.closedTabs.isEmpty)
    }

    @Test func anAmbiguousTerminalIsNotProjectedAgain() async {
        let viewer = UUID(), bound = UUID(), panel = UUID()
        let (catalog, provider) = Self.harness(bound: bound)
        let term = Self.terminal("term_1", views: [
            SurfaceRemoteView(tabID: "tab_1", workspace: Self.main),
            SurfaceRemoteView(tabID: "tab_2", workspace: Self.main)
        ])
        catalog.replaceResources([term], on: Self.machine)
        catalog.record(SurfaceProjection(resource: term.id, workspaceID: viewer, panelID: panel))
        catalog.moveProjections(panelID: panel, to: bound)
        await catalog.cloudPlacementCoordinator.waitForPendingMutations()
        #expect(provider.projected.isEmpty && provider.moved.isEmpty)
        #expect(catalog.cloudPlacementCoordinator.failures[term.id] != nil)
    }

    @Test func mutationResponseRetainsTheExactTabIdentity() async throws {
        let data = Data(#"{"value":{"id":"tab_new","pane_id":"pane_2","content_kind":"terminal","content_id":"term_1"},"generation":"g","revision":"13","replayed":false}"#.utf8)
        let target = CloudTuiTerminalProjectionTarget(workspaceID: "ws_api", screenID: "screen_2", paneID: "pane_2", index: 0)
        let placement = try #require(await CmuxTuiSnapshotParser.placedTab(from: data, at: target, terminalID: "term_1"))
        #expect(placement.tabID == "tab_new" && placement.workspaceID == "ws_api")
        #expect(placement.cursor == CloudVMCursor(generation: "g", revision: 13))
        #expect(await CmuxTuiSnapshotParser.placedTab(from: data, at: target, terminalID: "wrong") == nil)
        #expect(await CmuxTuiSnapshotParser.placedTab(from: data, at: target, tabID: "wrong") == nil)
    }

    @Test func staleSnapshotsCannotUndoAMoveButNewRemoteEditsAreReconciled() async throws {
        let viewer = UUID(), bound = UUID(), panel = UUID()
        let (catalog, provider) = Self.harness(bound: bound)
        let term = Self.terminal("term_1", views: [SurfaceRemoteView(tabID: "tab_1", workspace: Self.main)])
        catalog.replaceResources([term], on: Self.machine)
        catalog.record(SurfaceProjection(resource: term.id, workspaceID: viewer, panelID: panel, remoteWorkspaceID: "ws_main", remoteTabID: "tab_1"))
        provider.moveCursor = CloudVMCursor(generation: "g", revision: 13)
        catalog.moveProjections(panelID: panel, to: bound)
        await catalog.cloudPlacementCoordinator.waitForPendingMutations()

        func state(revision: String) throws -> CloudVMState {
            try #require(CmuxTuiSnapshotParser.state(fromSnapshot: [
                "cursor": ["generation": "g", "revision": revision],
                "workspaces": [["id": "ws_main"], ["id": "ws_api"]],
                "screens": [["id": "screen", "workspace_id": "ws_main"]],
                "panes": [["id": "pane", "screen_id": "screen"]],
                "tabs": [["id": "tab_1", "pane_id": "pane", "content_kind": "terminal", "content_id": "term_1"]],
                "terminals": [["id": "term_1", "tab_ids": ["tab_1"]]],
                "browsers": [], "agents": []
            ], machine: Self.machine))
        }
        catalog.reconcileCloudRemoteState(machine: Self.machine, state: try state(revision: "12"), observation: .current)
        #expect(catalog.projection(forPanel: panel)?.remoteWorkspaceID == "ws_api")
        catalog.reconcileCloudRemoteState(machine: Self.machine, state: try state(revision: "14"), observation: .current)
        #expect(catalog.projection(forPanel: panel)?.remoteWorkspaceID == "ws_main")
        #expect(catalog.projection(forPanel: panel)?.workspaceID == bound)
    }

    @Test func malformedCloseSnapshotsAreDistinctFromAnAlreadyMissingTab() async throws {
        #expect(await CmuxTuiSnapshotParser.tabPlacement(from: Data("{}".utf8), tabID: "tab_1") == nil)
        let empty = Data(#"{"cursor":{"generation":"g","revision":"4"},"workspaces":[],"screens":[],"panes":[],"tabs":[],"terminals":[],"browsers":[],"agents":[]}"#.utf8)
        let missing = try #require(await CmuxTuiSnapshotParser.tabPlacement(from: empty, tabID: "tab_1"))
        #expect(missing.workspaceID == nil && missing.revision == "4")
    }

    @Test func aDetachedTerminalDropsItsStaleTabBeforeMoving() async throws {
        let viewer = UUID(), bound = UUID(), panel = UUID()
        let (catalog, provider) = Self.harness(bound: bound)
        let term = Self.terminal("term_1", views: [])
        catalog.replaceResources([term], on: Self.machine)
        catalog.record(SurfaceProjection(resource: term.id, workspaceID: viewer, panelID: panel, remoteWorkspaceID: "ws_main", remoteTabID: "tab_gone"))
        let state = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: [
            "cursor": ["generation": "g", "revision": "20"],
            "workspaces": [["id": "ws_main"], ["id": "ws_api"]],
            "screens": [], "panes": [], "tabs": [],
            "terminals": [["id": "term_1", "tab_ids": []]], "browsers": [], "agents": []
        ], machine: Self.machine))
        catalog.reconcileCloudRemoteState(machine: Self.machine, state: state, observation: .current)
        catalog.moveProjections(panelID: panel, to: bound)
        await catalog.cloudPlacementCoordinator.waitForPendingMutations()
        #expect(provider.moved.isEmpty)
        #expect(provider.projected.map { $0.terminal } == ["term_1"])
        #expect(catalog.projection(forPanel: panel)?.remoteTabID == "tab_projected")
    }

    @Test func openingIntoABoundWorkspaceUsesTheSharedPlacementPath() async throws {
        let bound = UUID()
        let (catalog, provider) = Self.harness(bound: bound)
        let term = Self.terminal("term_1", views: [SurfaceRemoteView(tabID: "tab_1", workspace: Self.main)])
        catalog.replaceResources([term], on: Self.machine)
        _ = try await catalog.project(term.id, into: .tab(workspaceID: bound, paneID: UUID().uuidString, index: nil), focus: false, reuseExisting: false)
        await catalog.cloudPlacementCoordinator.waitForPendingMutations()
        #expect(provider.moved.map { $0.workspace } == ["ws_api"])
        #expect(provider.projected.isEmpty)
    }

    @Test func aFreshSnapshotDistinguishesDetachedUniqueAndAmbiguousTerminalViews() async throws {
        var snapshot: [String: Any] = [
            "cursor": ["generation": "g", "revision": "8"],
            "workspaces": [["id": "ws_main"]],
            "screens": [["id": "screen", "workspace_id": "ws_main"]],
            "panes": [["id": "pane", "screen_id": "screen"]],
            "tabs": [], "terminals": [["id": "term_1"]], "browsers": [], "agents": []
        ]
        let detached = try #require(await CmuxTuiSnapshotParser.terminalPlacement(from: JSONSerialization.data(withJSONObject: snapshot), terminalID: "term_1"))
        #expect(detached.placement == nil)
        let tab = ["id": "tab_1", "pane_id": "pane", "content_kind": "terminal", "content_id": "term_1"]
        snapshot["tabs"] = [tab]
        let existing = try #require(await CmuxTuiSnapshotParser.terminalPlacement(from: JSONSerialization.data(withJSONObject: snapshot), terminalID: "term_1"))
        #expect(existing.placement?.tabID == "tab_1" && existing.placement?.workspaceID == "ws_main")
        let placement = try #require(existing.placement)
        // The daemon focus moved elsewhere while a reconnect/open was waiting.
        // Attachment keeps this exact tab; a user layout edit may reparent it.
        #expect(CmuxTuiSurfaceProvider.TerminalPlacementIntent.attachment.retainedPlacement(placement, requestedWorkspaceID: "ws_api") == placement)
        #expect(CmuxTuiSurfaceProvider.TerminalPlacementIntent.layoutEdit.retainedPlacement(placement, requestedWorkspaceID: "ws_api") == nil)
        var duplicate = tab
        duplicate["id"] = "tab_2"
        snapshot["tabs"] = [tab, duplicate]
        #expect(await CmuxTuiSnapshotParser.terminalPlacement(from: try JSONSerialization.data(withJSONObject: snapshot), terminalID: "term_1") == nil)
    }

    @Test func invalidPlacementGraphsAreRejectedBeforeChoosingADestination() async throws {
        let tab = ["id": "tab_1", "pane_id": "pane", "content_kind": "terminal", "content_id": "term_1"]
        var snapshot: [String: Any] = [
            "cursor": ["generation": "g", "revision": "8"],
            "workspaces": [["id": "ws_main"]],
            "screens": [["id": "screen", "workspace_id": "ws_main"]],
            "panes": [["id": "pane", "screen_id": "screen"]],
            "tabs": [tab, tab], "terminals": [["id": "term_1"]], "browsers": [], "agents": []
        ]
        #expect(CmuxTuiSnapshotParser.projectionTarget(from: snapshot, inWorkspace: "ws_main") == nil)
        #expect(await CmuxTuiSnapshotParser.tabPlacement(from: try JSONSerialization.data(withJSONObject: snapshot), tabID: "tab_1") == nil)
        snapshot["tabs"] = [tab]
        snapshot["screens"] = [["id": "screen", "workspace_id": "ws_missing"]]
        #expect(await CmuxTuiSnapshotParser.terminalProjectionTarget(from: try JSONSerialization.data(withJSONObject: snapshot), preferringWorkspace: nil) == nil)
    }

    @Test(arguments: [SurfaceProjectionEndReason.replaced, .workspaceTeardown])
    func programmaticRemovalReasonsAreScopedAndNeverLeakPastAFailedClose(reason: SurfaceProjectionEndReason) async {
        let bound = UUID(), replaced = UUID(), failedClose = UUID()
        let (catalog, provider) = Self.harness(bound: bound)
        let replacedTerm = Self.terminal("replaced", views: [SurfaceRemoteView(tabID: "tab_replaced", workspace: Self.api)])
        let failedTerm = Self.terminal("failed", views: [SurfaceRemoteView(tabID: "tab_failed", workspace: Self.api)])
        catalog.replaceResources([replacedTerm, failedTerm], on: Self.machine)
        catalog.record(SurfaceProjection(resource: replacedTerm.id, workspaceID: bound, panelID: replaced, remoteWorkspaceID: "ws_api", remoteTabID: "tab_replaced"))
        catalog.record(SurfaceProjection(resource: failedTerm.id, workspaceID: bound, panelID: failedClose, remoteWorkspaceID: "ws_api", remoteTabID: "tab_failed"))
        catalog.withProjectionEndReason(for: [replaced], reason: reason) {
            catalog.endProjections(panelID: replaced)
        }
        catalog.withProjectionEndReason(for: [failedClose], reason: reason) {
            // A rejected socket close does not mutate the panel map.
        }
        catalog.endProjections(panelID: failedClose)
        await catalog.cloudPlacementCoordinator.waitForPendingMutations()
        #expect(provider.closedTabs == ["tab_failed"])
    }

    @Test func replacingARestoredPaneKeepsItsExactTabAmongMultipleViews() async {
        let bound = UUID(), oldPanel = UUID(), newPanel = UUID()
        let (catalog, provider) = Self.harness(bound: bound)
        let term = Self.terminal("term_1", views: [
            SurfaceRemoteView(tabID: "tab_main", workspace: Self.main),
            SurfaceRemoteView(tabID: "tab_api", workspace: Self.api)
        ])
        catalog.replaceResources([term], on: Self.machine)
        let previous = SurfaceProjection(resource: term.id, workspaceID: bound, panelID: oldPanel, remoteWorkspaceID: "ws_api", remoteTabID: "tab_api")
        catalog.record(previous)
        catalog.replaceProjection(previous, withPanel: newPanel, in: bound, remotePlacement: nil)
        await catalog.cloudPlacementCoordinator.waitForPendingMutations()
        #expect(catalog.projection(forPanel: oldPanel) == nil)
        #expect(catalog.projection(forPanel: newPanel)?.remoteTabID == "tab_api")
        #expect(provider.closedTabs.isEmpty && provider.moved.isEmpty)
        catalog.endProjections(panelID: newPanel)
        await catalog.cloudPlacementCoordinator.waitForPendingMutations()
        #expect(provider.closedTabs == ["tab_api"])
    }

    @Test func replacementPrefersTheNewBackingTabReceiptOverSavedCoordinates() {
        let bound = UUID(), newPanel = UUID()
        let (catalog, _) = Self.harness(bound: bound)
        let term = Self.terminal("term_1", views: [])
        catalog.replaceResources([term], on: Self.machine)
        let previous = SurfaceProjection(resource: term.id, workspaceID: bound, panelID: UUID(), remoteWorkspaceID: "ws_main", remoteTabID: "gone")
        catalog.record(previous)
        catalog.replaceProjection(previous, withPanel: newPanel, in: bound, remotePlacement: SurfaceRemotePlacement(workspaceID: "ws_api", tabID: "tab_new"))
        #expect(catalog.projection(forPanel: newPanel)?.remoteTabID == "tab_new")
        #expect(catalog.projection(forPanel: newPanel)?.remoteWorkspaceID == "ws_api")
    }

    @Test func repairUsesTheBindingAndFinishesBeforeALaterUserMove() async {
        let api = UUID(), main = UUID(), panel = UUID()
        let coordinator = CloudPlacementCoordinator(binding: { id in
            WorkspaceCloudVMBinding(vmID: "vivid-newt", isBase: false, remoteWorkspaceID: id == api ? "ws_api" : "ws_main")
        })
        let catalog = SurfaceCatalog(cloudPlacementCoordinator: coordinator)
        let provider = CloudPlacementTestProvider(machine: Self.machine)
        catalog.register(provider)
        let term = Self.terminal("term_1", views: [])
        catalog.replaceResources([term], on: Self.machine)
        catalog.record(SurfaceProjection(resource: term.id, workspaceID: api, panelID: panel))
        let (started, start) = AsyncStream<Void>.makeStream()
        let (released, release) = AsyncStream<Void>.makeStream()
        let repair = Task { @MainActor in
            await coordinator.repairPlacement(for: term.id, catalog: catalog) { workspace in
                #expect(workspace == "ws_api")
                start.yield(())
                start.finish()
                for await _ in released { break }
                return SurfaceRemotePlacement(workspaceID: "ws_api", tabID: "tab_repaired")
            }
        }
        for await _ in started { break }
        catalog.moveProjections(panelID: panel, to: main)
        release.yield(())
        release.finish()
        await repair.value
        await coordinator.waitForPendingMutations()
        #expect(provider.moved.map { $0.tab + "->" + $0.workspace } == ["tab_repaired->ws_main"])
        #expect(catalog.projection(forPanel: panel)?.remoteWorkspaceID == "ws_main")
        #expect(catalog.projection(forPanel: panel)?.remoteTabID == "tab_repaired")
    }

    @Test func repairDoesNotGuessBetweenConflictingBindings() async {
        let api = UUID(), main = UUID()
        let coordinator = CloudPlacementCoordinator(binding: { id in
            WorkspaceCloudVMBinding(vmID: "vivid-newt", isBase: false, remoteWorkspaceID: id == api ? "ws_api" : "ws_main")
        })
        let catalog = SurfaceCatalog(cloudPlacementCoordinator: coordinator)
        let provider = CloudPlacementTestProvider(machine: Self.machine)
        catalog.register(provider)
        let term = Self.terminal("term_1", views: [])
        catalog.replaceResources([term], on: Self.machine)
        for workspace in [api, main] {
            catalog.record(SurfaceProjection(resource: term.id, workspaceID: workspace, panelID: UUID()))
        }
        var attempted = false
        await coordinator.repairPlacement(for: term.id, catalog: catalog) { _ in
            attempted = true
            return SurfaceRemotePlacement(workspaceID: "unexpected", tabID: "unexpected")
        }
        #expect(!attempted && coordinator.failures[term.id] != nil)
        #expect(provider.refreshCount == 0, "recovery must not recursively await the refresh that owns it")
    }

    @Test func aCloseDuringRepairClosesTheRepairedTab() async {
        let bound = UUID(), panel = UUID()
        let (catalog, provider) = Self.harness(bound: bound)
        let term = Self.terminal("term_1", views: [])
        catalog.replaceResources([term], on: Self.machine)
        catalog.record(SurfaceProjection(resource: term.id, workspaceID: bound, panelID: panel))
        let (started, start) = AsyncStream<Void>.makeStream()
        let (released, release) = AsyncStream<Void>.makeStream()
        let repair = Task { @MainActor in
            await catalog.cloudPlacementCoordinator.repairPlacement(for: term.id, catalog: catalog) { _ in
                start.yield(())
                start.finish()
                for await _ in released { break }
                return SurfaceRemotePlacement(workspaceID: "ws_api", tabID: "tab_repaired")
            }
        }
        for await _ in started { break }
        catalog.endProjections(panelID: panel)
        release.yield(())
        release.finish()
        await repair.value
        await catalog.cloudPlacementCoordinator.waitForPendingMutations()
        #expect(provider.closedTabs == ["tab_repaired"])
        #expect(catalog.resources[term.id] != nil)
    }

    @Test func anUnresolvedViewerKeepsTheBackingTabUntilItsIdentityIsKnown() async {
        let bound = UUID(), closing = UUID()
        let (catalog, provider) = Self.harness(bound: bound)
        let term = Self.terminal("term_1", views: [])
        catalog.replaceResources([term], on: Self.machine)
        catalog.record(SurfaceProjection(resource: term.id, workspaceID: bound, panelID: closing, remoteWorkspaceID: "ws_api", remoteTabID: "tab_api"))
        catalog.record(SurfaceProjection(resource: term.id, workspaceID: UUID(), panelID: UUID()))
        catalog.endProjections(panelID: closing)
        await catalog.cloudPlacementCoordinator.waitForPendingMutations()
        #expect(provider.closedTabs.isEmpty)
    }

    @Test func replacementUsesTheOnlyLiveViewWhenTheSavedTabIsGone() async {
        let bound = UUID(), panel = UUID()
        let (catalog, provider) = Self.harness(bound: bound)
        let term = Self.terminal("term_1", views: [SurfaceRemoteView(tabID: "tab_live", workspace: Self.api)])
        catalog.replaceResources([term], on: Self.machine)
        let previous = SurfaceProjection(resource: term.id, workspaceID: bound, panelID: UUID(), remoteWorkspaceID: "ws_main", remoteTabID: "tab_gone")
        catalog.record(previous)
        catalog.replaceProjection(previous, withPanel: panel, in: bound, remotePlacement: nil)
        #expect(catalog.projection(forPanel: panel)?.remoteTabID == "tab_live")
        #expect(catalog.projection(forPanel: panel)?.remoteWorkspaceID == "ws_api")
        catalog.endProjections(panelID: panel)
        await catalog.cloudPlacementCoordinator.waitForPendingMutations()
        #expect(provider.closedTabs == ["tab_live"])
    }

    @Test func aMissingTrackedTabClearsCoordinatesEvenWhenOtherViewsRemain() throws {
        let bound = UUID(), panel = UUID()
        let (catalog, _) = Self.harness(bound: bound)
        let term = Self.terminal("term_1", views: [SurfaceRemoteView(tabID: "tab_live", workspace: Self.api)])
        catalog.replaceResources([term], on: Self.machine)
        let previous = SurfaceProjection(resource: term.id, workspaceID: bound, panelID: panel, remoteWorkspaceID: "ws_main", remoteTabID: "tab_gone")
        catalog.record(previous)
        let state = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: [
            "cursor": ["generation": "g", "revision": "20"],
            "workspaces": [["id": "ws_api"]],
            "screens": [["id": "screen", "workspace_id": "ws_api"]],
            "panes": [["id": "pane", "screen_id": "screen"]],
            "tabs": [["id": "tab_live", "pane_id": "pane", "content_kind": "terminal", "content_id": "term_1"]],
            "terminals": [["id": "term_1", "tab_ids": ["tab_live"]]], "browsers": [], "agents": []
        ], machine: Self.machine))
        catalog.reconcileCloudRemoteState(machine: Self.machine, state: state, observation: .current)
        #expect(catalog.projection(forPanel: panel)?.remoteTabID == nil)
        #expect(catalog.projection(forPanel: panel)?.remoteWorkspaceID == nil)
    }

    @Test func replacementDoesNotGuessBetweenLiveViewsAfterTheSavedTabDisappears() {
        let bound = UUID(), panel = UUID()
        let (catalog, _) = Self.harness(bound: bound)
        let term = Self.terminal("term_1", views: [
            SurfaceRemoteView(tabID: "tab_1", workspace: Self.api),
            SurfaceRemoteView(tabID: "tab_2", workspace: Self.api)
        ])
        catalog.replaceResources([term], on: Self.machine)
        let previous = SurfaceProjection(resource: term.id, workspaceID: bound, panelID: UUID(), remoteWorkspaceID: "ws_api", remoteTabID: "tab_gone")
        catalog.record(previous)
        catalog.replaceProjection(previous, withPanel: panel, in: bound, remotePlacement: nil)
        #expect(catalog.projection(forPanel: panel)?.remoteTabID == nil)
        #expect(catalog.projection(forPanel: panel)?.remoteWorkspaceID == nil)
    }
}
