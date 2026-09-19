import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Exercises the async ownership boundaries behind #12486, without a live VM.
@MainActor
@Suite("Cloud placement selector lifecycle")
struct CloudPlacementSelectorLifecycleTests {
    private let machine = SurfaceMachineID.cloud("selector-lifecycle")

    enum MaterializationCase: CaseIterable, Sendable {
        case restored, selected, replacementDisappears
    }

    @Test(.serialized, arguments: MaterializationCase.allCases)
    func deletedPersistedTabMaterializationUsesOnlyItsRepairedPlacement(_ scenario: MaterializationCase) async throws {
        let restoredWorkspace = UUID(), siblingWorkspace = UUID()
        let restoredPanel = UUID(), siblingPanel = UUID()
        let bindings = [
            restoredWorkspace: WorkspaceCloudVMBinding(vmID: machine.rawValue, isBase: false, remoteWorkspaceID: "ws_old"),
            siblingWorkspace: WorkspaceCloudVMBinding(vmID: machine.rawValue, isBase: false, remoteWorkspaceID: "ws_target")
        ]
        let workspaceCoordinator = CloudWorkspaceProjectionCoordinator(environment: .init(bindings: { bindings }))
        let coordinator = CloudPlacementCoordinator(binding: { bindings[$0] })
        let catalog = SurfaceCatalog(cloudPlacementCoordinator: coordinator, cloudWorkspaceProjectionCoordinator: workspaceCoordinator)
        let provider = CmuxTuiSurfaceProvider(
            summary: VMSummary(id: machine.rawValue, provider: "freestyle", status: "running", image: "cmux-devbox", createdAt: 0, base: nil),
            links: CloudMachineLinkManager(clientURL: nil, hostThemeColors: { nil }),
            catalog: catalog,
            attachmentClock: MaterializationClock()
        )
        catalog.register(provider)
        // Hold native layout reconciliation while this restored placeholder owns
        // materialization, just as the surrounding projection mutation does.
        _ = workspaceCoordinator.beginLocalMutation(on: machine)
        let initial = try graph(tabID: "tab_sibling")
        catalog.replaceCloudState(initial, resources: CmuxTuiSnapshotParser.resources(from: initial), info: provider.info)
        let terminal = SurfaceResourceID(machine: machine, kind: .terminal, key: "term_live")
        let restored = SurfaceProjection(resource: terminal, workspaceID: restoredWorkspace, panelID: restoredPanel,
                                         remoteWorkspaceID: "ws_old", remoteTabID: "tab_deleted")
        let sibling = SurfaceProjection(resource: terminal, workspaceID: siblingWorkspace, panelID: siblingPanel,
                                        remoteWorkspaceID: "ws_old", remoteTabID: "tab_sibling")
        catalog.record(restored)
        catalog.record(sibling)
        #expect(!workspaceCoordinator.retainsProjection(restored, in: initial))
        var replacementSnapshot = try #require(initial.snapshotObject())
        var tabs = try #require(replacementSnapshot["tabs"] as? [[String: Any]])
        tabs.append(["id": "tab_repaired", "pane_id": "pane_old", "content_kind": "terminal", "content_id": "term_live"])
        replacementSnapshot["tabs"] = tabs
        replacementSnapshot["cursor"] = ["generation": "g", "revision": "2"]
        let replacementData = try JSONSerialization.data(withJSONObject: replacementSnapshot)
        let runner = MaterializationRunner(
            snapshot: try JSONSerialization.data(withJSONObject: try #require(initial.snapshotObject())),
            tree: try JSONSerialization.data(withJSONObject: ["workspaces": [["screens": [["panes": [["tabs": [
                ["tab_resource_id": "tab_sibling", "terminal_resource_id": "term_live", "surface": 23],
                ["tab_resource_id": "tab_repaired", "terminal_resource_id": "term_live", "surface": 41]
            ]]]]]]]])
        )
        let replacement = SurfaceRemotePlacement(workspaceID: "ws_old", tabID: "tab_repaired",
                                                  cursor: CloudVMCursor(generation: "g", revision: 2))
        var repairs = 0
        do {
            let resolved = try await provider.resolveSurfaceIDForMaterialization(
                terminalID: terminal.key, socketPath: "/fixture", commandRunner: runner,
                remoteTabID: "tab_deleted", correlationID: UUID().uuidString,
                restoringPanelID: scenario == .selected ? nil : restoredPanel
            ) { workspace in
                repairs += 1
                #expect(workspace == "ws_old", "a sibling's different binding must not block or redirect restore")
                if scenario == .restored { await runner.replace(snapshot: replacementData) }
                return replacement
            }
            #expect(scenario == .restored)
            #expect(resolved.surfaceID == 41, "materialization must resolve the receipt's tab, not its sibling")
            #expect(resolved.placement == replacement)
        } catch let CmuxTuiSurfaceProvider.ProviderError.terminalAttachTimedOut(_, failure) {
            #expect(scenario != .restored)
            #expect(failure == .missingTab)
        } catch {
            Issue.record("unexpected materialization error: \(error)")
        }
        #expect(repairs == (scenario == .selected ? 0 : 1), "a replacement that disappears must not cause unbounded repair")
        #expect(catalog.projection(forPanel: restoredPanel)?.remoteTabID == (scenario == .selected ? "tab_deleted" : "tab_repaired"))
        #expect(catalog.projection(forPanel: siblingPanel) == sibling, "repair must not retarget another local projection")
        #expect(await runner.treeReads == (scenario == .restored ? 1 : 0))
        let expectedSnapshots = scenario == .restored ? 2 : (scenario == .replacementDisappears ? 4 : 3)
        #expect(await runner.snapshotReads == expectedSnapshots)
        workspaceCoordinator.cancel(machine: machine)
        await provider.stop()
    }

    @Test
    func anUnchangedViewCanCommitAndAReplacementViewIsNotGuessed() async throws {
        let catalog = SurfaceCatalog()
        let provider = CloudPlacementTestProvider(machine: machine)
        catalog.register(provider)
        install(try graph(tabID: "tab_live"), catalog: catalog, provider: provider)
        let id = SurfaceResourceID(machine: machine, kind: .terminal, key: "term_live")
        let view = try #require(catalog.resources[id]?.remoteViews?.first)
        let opened = try await catalog.project(
            id, into: .workspace(id: UUID(), placement: .tab), focus: false, remoteView: view
        )
        #expect(catalog.projections == [opened.projection])
        #expect(opened.projection.remoteTabID == "tab_live")
    }

    @Test
    func commandFailureDiagnosticsExcludeDaemonProseAndArguments() {
        let diagnostic = CloudTuiCommandDiagnostic(
            arguments: CloudTuiRequest("tab.move", ["tab": "tab_expected", "name": "private-name"]),
            output: #"{"code":"selector.not_found","details":{"scope":"tab","selector":"tab_expected"},"message":"private-command /home/user/secret"}"#
        )
        #expect(diagnostic.operation == "tab.move")
        #expect(diagnostic.code == "selector.not_found")
        #expect(diagnostic.scope == "tab")
        #expect(!String(reflecting: diagnostic).contains("private"))
        #expect(CloudTuiDaemonAnswer.isMissingSelector(CloudMachineLink.LinkError.exited(
            status: 1, output: #"{"code":"selector.not_found","details":{"scope":"tab","selector":"tab_expected"}}"#
        )))
        #expect(!CloudTuiDaemonAnswer.isMissingSelector(CloudMachineLink.LinkError.exited(
            status: 1, output: "unrelated failure mentioning selector.not_found"
        )))
    }

    @Test(arguments: [false, true])
    func removedViewCannotCommitAfterMaterialization(reuse: Bool) async throws {
        let catalog = SurfaceCatalog()
        let provider = CloudPlacementTestProvider(machine: machine)
        catalog.register(provider)
        let initial = try graph(tabID: "tab_old")
        install(initial, catalog: catalog, provider: provider)
        let terminalID = SurfaceResourceID(machine: machine, kind: .terminal, key: "term_live")
        let view = try #require(catalog.resources[terminalID]?.remoteViews?.first)
        provider.beforeMaterialization = {
            // Another client closes the requested view while the native attach
            // is suspended. The same terminal still has a different live view.
            install(try graph(tabID: "tab_other", revision: 2), catalog: catalog, provider: provider)
        }

        await #expect(throws: SurfaceCatalogError.self) {
            try await catalog.project(
                terminalID, into: .workspace(id: UUID(), placement: .tab),
                focus: false, reuseExisting: reuse, remoteView: view
            )
        }
        #expect(catalog.projections.isEmpty)
        #expect(provider.moved.isEmpty)
        #expect(provider.closedTabs.isEmpty, "discarding a late local view must not close a remote tab")
    }

    @Test
    func queuedMoveDoesNotSendATabRemovedWhileAnotherMoveWasInFlight() async throws {
        let original = UUID(), target = UUID()
        let coordinator = CloudPlacementCoordinator(binding: { id in
            id == target ? WorkspaceCloudVMBinding(
                vmID: machine.rawValue, isBase: false, remoteWorkspaceID: "ws_target"
            ) : nil
        })
        let catalog = SurfaceCatalog(cloudPlacementCoordinator: coordinator)
        let provider = CloudPlacementTestProvider(machine: machine)
        provider.moveCursor = CloudVMCursor(generation: "g", revision: 3)
        provider.projectCursor = CloudVMCursor(generation: "g", revision: 4)
        catalog.register(provider)
        install(try graph(tabID: "tab_old"), catalog: catalog, provider: provider)
        let blocker = SurfaceProjection(
            resource: SurfaceResourceID(machine: machine, kind: .terminal, key: "term_blocker"),
            workspaceID: original, panelID: UUID(), remoteWorkspaceID: "ws_old", remoteTabID: "tab_blocker"
        )
        let moving = SurfaceProjection(
            resource: SurfaceResourceID(machine: machine, kind: .terminal, key: "term_live"),
            workspaceID: original, panelID: UUID(), remoteWorkspaceID: "ws_old", remoteTabID: "tab_old"
        )
        catalog.record(blocker)
        catalog.record(moving)
        let (started, start) = AsyncStream<Void>.makeStream()
        let (released, release) = AsyncStream<Void>.makeStream()
        provider.beforeMutation = {
            provider.beforeMutation = nil
            start.yield(())
            start.finish()
            for await _ in released { break }
        }
        catalog.moveProjections(panelID: blocker.panelID, to: target)
        for await _ in started { break }
        catalog.moveProjections(panelID: moving.panelID, to: target)
        let detached = try graph(tabID: nil, revision: 2)
        install(detached, catalog: catalog, provider: provider)
        coordinator.reconcileRemoteState(detached, catalog: catalog)
        release.yield(())
        release.finish()
        await coordinator.waitForPendingMutations()

        #expect(provider.moved.map(\.tab) == ["tab_blocker"])
        #expect(provider.projected.map(\.terminal) == ["term_live"])
        #expect(catalog.projection(forPanel: moving.panelID)?.remoteTabID == "tab_projected")
    }

    private func install(_ state: CloudVMState, catalog: SurfaceCatalog, provider: CloudPlacementTestProvider) {
        catalog.replaceCloudState(state, resources: CmuxTuiSnapshotParser.resources(from: state), info: provider.info)
    }

    private func graph(tabID: String?, revision: Int = 1) throws -> CloudVMState {
        var tabs: [[String: Any]] = [[
            "id": "tab_blocker", "pane_id": "pane_old", "content_kind": "terminal", "content_id": "term_blocker"
        ]]
        if let tabID {
            tabs.append(["id": tabID, "pane_id": "pane_old", "content_kind": "terminal", "content_id": "term_live"])
        }
        return try #require(CmuxTuiSnapshotParser.state(fromSnapshot: [
            "cursor": ["generation": "g", "revision": String(revision)],
            "workspaces": [["id": "ws_old"], ["id": "ws_target"]],
            "screens": [["id": "screen_old", "workspace_id": "ws_old"], ["id": "screen_target", "workspace_id": "ws_target"]],
            "panes": [["id": "pane_old", "screen_id": "screen_old"], ["id": "pane_target", "screen_id": "screen_target"]],
            "tabs": tabs,
            "terminals": [["id": "term_live", "lifecycle": "running"], ["id": "term_blocker", "lifecycle": "running"]],
            "browsers": [], "agents": []
        ], machine: machine))
    }

    /// Advances retry deadlines immediately while retaining cancellation behavior.
    private struct MaterializationClock: Clock {
        var now: ContinuousClock.Instant { .now }
        var minimumResolution: Duration { .zero }
        func sleep(until _: ContinuousClock.Instant, tolerance _: Duration?) async throws {
            try Task.checkCancellation()
        }
    }

    private actor MaterializationRunner: CloudTuiCommandRunning {
        var snapshot: Data
        let tree: Data
        private(set) var snapshotReads = 0
        private(set) var treeReads = 0

        init(snapshot: Data, tree: Data) { self.snapshot = snapshot; self.tree = tree }
        func replace(snapshot: Data) { self.snapshot = snapshot }
        func runTuiCommand(arguments: CloudTuiRequest, deadline: Duration) async throws -> Data {
            if arguments.operation == "session.snapshot" {
                snapshotReads += 1
                return snapshot
            }
            #expect(arguments.operation == "list-workspaces")
            #expect(arguments.raw)
            treeReads += 1
            return tree
        }
    }
}
