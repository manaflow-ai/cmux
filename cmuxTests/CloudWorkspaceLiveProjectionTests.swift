import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Live Cloud workspace projection")
struct CloudWorkspaceLiveProjectionTests {
    private let machine = SurfaceMachineID.cloud("live-fixture")

    private func graph(_ placement: [String: String], revision: Int, generation: String = "live") throws -> CloudVMState {
        let tabs = placement.keys.sorted()
        let document: [String: Any] = [
            "cursor": ["generation": generation, "revision": String(revision)],
            "workspaces": ["a", "b"].enumerated().map { ["id": $0.element, "name": "Workspace " + $0.element, "index": $0.offset] as [String: Any] },
            "screens": ["a", "b"].map { id in ["id": "screen_" + id, "workspace_id": id, "layout": [
                "version": 1, "screen_id": "screen_" + id,
                "root": ["kind": "leaf", "pane_id": "pane_" + id, "tab_ids": tabs.filter { placement[$0] == id }]
            ]] as [String: Any] },
            "panes": ["a", "b"].map { ["id": "pane_" + $0, "screen_id": "screen_" + $0] },
            "tabs": tabs.enumerated().map { index, id in
                ["id": id, "pane_id": "pane_" + placement[id]!, "name": "Name " + id, "index": index,
                 "content_kind": "terminal", "content_id": id == "third" ? "term_other" : "term_shared"] as [String: Any]
            },
            "terminals": ["term_shared", "term_other"].map { ["id": $0, "title": "Process " + $0, "lifecycle": "running"] },
            "browsers": [], "agents": []
        ]
        return try #require(CmuxTuiSnapshotParser.state(fromSnapshot: document, machine: machine))
    }

    private func install(_ state: CloudVMState, catalog: SurfaceCatalog) {
        let info = SurfaceMachineInfo(id: machine, name: "Fixture", status: "running", image: nil, hasDesktop: false,
            memoryMb: nil, diskMb: nil, linkState: .connected, linkError: nil,
            cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil,
            remoteWorkspaces: state.workspaces.map { SurfaceRemoteWorkspace(id: $0.id, name: $0.name, index: $0.index, focused: $0.focused) })
        catalog.replaceCloudState(state, resources: CmuxTuiSnapshotParser.resources(from: state), info: info)
        catalog.reconcileCloudRemoteState(machine: machine, state: state)
    }

    @Test("Existing native workspaces follow create, cross-workspace move, one-view close and reconnect")
    func followsLiveMembership() async throws {
        let a = UUID(), b = UUID()
        let bindings = [a: WorkspaceCloudVMBinding(vmID: machine.rawValue, isBase: false, remoteWorkspaceID: "a"),
                        b: WorkspaceCloudVMBinding(vmID: machine.rawValue, isBase: false, remoteWorkspaceID: "b")]
        var closed: [SurfaceProjection] = []
        var layouts: [UUID: SurfaceProjectionLayout] = [:]
        let coordinator = CloudWorkspaceProjectionCoordinator(environment: .init(
            bindings: { bindings }, close: { closed.append($0) }, applyLayout: { id, layout, _ in layouts[id] = layout }
        ))
        let catalog = SurfaceCatalog(cloudPlacementCoordinator: CloudPlacementCoordinator(binding: { bindings[$0] }),
                                     cloudWorkspaceProjectionCoordinator: coordinator)
        let provider = CloudPlacementTestProvider(machine: machine)
        catalog.register(provider)
        let initial = try graph(["first": "a", "second": "a"], revision: 1)
        install(initial, catalog: catalog)
        await coordinator.waitForIdle()
        let firstPanel = try #require(catalog.projections.first { $0.remoteTabID == "first" }?.panelID)
        #expect(catalog.projections.count == 2)
        #expect(catalog.projections.allSatisfy { $0.workspaceID == a })

        install(try graph(["first": "a", "second": "a", "third": "a"], revision: 2), catalog: catalog)
        await coordinator.waitForIdle()
        #expect(catalog.projections.count == 3)
        #expect(catalog.projections.first { $0.remoteTabID == "first" }?.panelID == firstPanel)

        install(try graph(["first": "a", "second": "b", "third": "a"], revision: 3), catalog: catalog)
        await coordinator.waitForIdle()
        #expect(catalog.projections.first { $0.remoteTabID == "second" }?.workspaceID == b)
        #expect(catalog.projections.filter { $0.workspaceID == a }.count == 2)
        #expect(layouts[b]?.placements.compactMap(\.remoteTabID) == ["second"])

        let closedState = try graph(["second": "b", "third": "a"], revision: 4)
        install(closedState, catalog: catalog)
        await coordinator.waitForIdle()
        #expect(!catalog.projections.contains { $0.remoteTabID == "first" })
        #expect(catalog.projections.contains { $0.remoteTabID == "second" })
        #expect(catalog.resources[SurfaceResourceID(machine: machine, kind: .terminal, key: "term_shared")] != nil)
        #expect(closed.contains { $0.panelID == firstPanel })
        #expect(provider.closedTabs.isEmpty, "reconciliation never authors a second remote close")

        catalog.reconcileCloudRemoteState(machine: machine, state: initial)
        await coordinator.waitForIdle()
        #expect(catalog.projections.count == 2, "delayed callbacks cannot restore old membership")
        install(try graph(["first": "a", "second": "b", "third": "a"], revision: 1, generation: "reconnected"), catalog: catalog)
        await coordinator.waitForIdle()
        #expect(catalog.projections.count == 3)
        let restoredRecords = catalog.projectionRecords(forWorkspace: a)
        catalog.restore(restoredRecords, workspaceID: a)
        coordinator.request(machine: machine, catalog: catalog)
        await coordinator.waitForIdle()
        #expect(catalog.projections.count == 3, "refresh and restore are idempotent")
        #expect(coordinator.failures.isEmpty)
    }

    @Test("Local create intent prevents duplicate materialization while an event arrives")
    func localCreationOwnsItsDestinationUntilItFinishes() async throws {
        let local = UUID()
        let coordinator = CloudWorkspaceProjectionCoordinator(environment: .init(bindings: {
            [local: WorkspaceCloudVMBinding(vmID: machine.rawValue, isBase: false, remoteWorkspaceID: "a")]
        }))
        let catalog = SurfaceCatalog(cloudWorkspaceProjectionCoordinator: coordinator)
        catalog.register(CloudPlacementTestProvider(machine: machine))
        let token = coordinator.beginLocalMutation(on: machine)
        install(try graph(["first": "a"], revision: 1), catalog: catalog)
        await coordinator.waitForIdle()
        #expect(catalog.projections.isEmpty)
        let native = SurfaceProjection(resource: SurfaceResourceID(machine: machine, kind: .terminal, key: "term_shared"),
                                       workspaceID: local, panelID: UUID(), remoteWorkspaceID: "a", remoteTabID: "first")
        catalog.record(native)
        coordinator.endLocalMutation(token, on: machine, catalog: catalog)
        await coordinator.waitForIdle()
        #expect(catalog.projections == [native])
    }

    @Test("Lifecycle cancellation is not retained as a projection failure")
    func cancelledMaterializationIsNotAnError() async throws {
        let local = UUID()
        let coordinator = CloudWorkspaceProjectionCoordinator(environment: .init(bindings: {
            [local: WorkspaceCloudVMBinding(vmID: machine.rawValue, isBase: false, remoteWorkspaceID: "a")]
        }))
        let catalog = SurfaceCatalog(cloudWorkspaceProjectionCoordinator: coordinator)
        let provider = CloudPlacementTestProvider(machine: machine)
        provider.beforeMaterialization = { throw CancellationError() }
        catalog.register(provider)
        install(try graph(["first": "a"], revision: 1), catalog: catalog)
        await coordinator.waitForIdle()
        #expect(coordinator.failures.isEmpty)
        #expect(catalog.projections.isEmpty)
    }

    @Test("Reconnect does not recreate an explicitly closed daemon view")
    func reconnectDoesNotUndoRemoteClose() async throws {
        let local = UUID()
        let binding = WorkspaceCloudVMBinding(vmID: machine.rawValue, isBase: false, remoteWorkspaceID: "a")
        let coordinator = CloudWorkspaceProjectionCoordinator(environment: .init(bindings: { [local: binding] }))
        let catalog = SurfaceCatalog(cloudPlacementCoordinator: CloudPlacementCoordinator(binding: { _ in binding }),
                                     cloudWorkspaceProjectionCoordinator: coordinator)
        catalog.register(CloudPlacementTestProvider(machine: machine))
        install(try graph(["first": "a"], revision: 1), catalog: catalog)
        await coordinator.waitForIdle()
        let terminal = try #require(catalog.projections.first?.resource)
        let token = coordinator.beginLocalMutation(on: machine)
        install(try graph([:], revision: 2), catalog: catalog)
        var repaired = false
        await catalog.cloudPlacementCoordinator.repairPlacement(for: terminal, catalog: catalog) { _ in
            repaired = true
            return SurfaceRemotePlacement(workspaceID: "a", tabID: "resurrected")
        }
        #expect(!repaired, "a closed view is not an attachment fault")
        coordinator.endLocalMutation(token, on: machine, catalog: catalog)
        await coordinator.waitForIdle()
        #expect(catalog.projections.isEmpty)
    }

    @Test("An acknowledged local close cannot be reopened by a lagging graph")
    func localCloseReceipt() async throws {
        let local = UUID()
        let binding = WorkspaceCloudVMBinding(vmID: machine.rawValue, isBase: false, remoteWorkspaceID: "a")
        let coordinator = CloudWorkspaceProjectionCoordinator(environment: .init(bindings: { [local: binding] }))
        let catalog = SurfaceCatalog(cloudPlacementCoordinator: CloudPlacementCoordinator(binding: { _ in binding }),
                                     cloudWorkspaceProjectionCoordinator: coordinator)
        let provider = CloudPlacementTestProvider(machine: machine)
        catalog.register(provider)
        install(try graph(["first": "a", "second": "a"], revision: 1), catalog: catalog)
        await coordinator.waitForIdle()
        let first = try #require(catalog.projections.first { $0.remoteTabID == "first" })
        catalog.endProjections(panelID: first.panelID)
        await catalog.cloudPlacementCoordinator.waitForPendingMutations()
        await coordinator.waitForIdle()
        #expect(provider.closedTabs == ["first"])
        #expect(!catalog.projections.contains { $0.remoteTabID == "first" })
        install(try graph(["second": "a"], revision: 2), catalog: catalog)
        await coordinator.waitForIdle()
        install(try graph(["first": "a", "second": "a"], revision: 3), catalog: catalog)
        await coordinator.waitForIdle()
        #expect(catalog.projections.count == 2, "a later authoritative restore can create the view again")
    }

    @Test("A projection waiting for its Cloud resource remains in the next session snapshot")
    func pendingProjectionPersistsAcrossAutosave() throws {
        let catalog = SurfaceCatalog()
        let panel = UUID()
        let workspace = UUID()
        let resource = SurfaceResourceID(machine: machine, kind: .terminal, key: "term_waiting")
        let record = SurfaceProjectionRecord(
            panelID: panel,
            resource: resource,
            remoteWorkspaceID: "a",
            remoteTabID: "tab_waiting"
        )

        catalog.restore([record], workspaceID: workspace)
        let saved = catalog.projectionRecords(forWorkspace: workspace)
        #expect(saved == [record])
        #expect(catalog.projectionRecords(forWorkspace: workspace) == saved)
    }

    @Test("A pending projection has one owner and cannot be resurrected after close or replacement")
    func pendingProjectionOwnershipIsUnique() throws {
        let catalog = SurfaceCatalog()
        let firstWorkspace = UUID(), secondWorkspace = UUID(), panel = UUID()
        let first = SurfaceProjectionRecord(
            panelID: panel,
            resource: SurfaceResourceID(machine: machine, kind: .terminal, key: "term_first"),
            remoteWorkspaceID: "a",
            remoteTabID: "tab_first"
        )
        let replacement = SurfaceProjectionRecord(
            panelID: panel,
            resource: SurfaceResourceID(machine: machine, kind: .terminal, key: "term_second"),
            remoteWorkspaceID: "b",
            remoteTabID: "tab_second"
        )
        catalog.restore([first], workspaceID: firstWorkspace)
        catalog.restore([replacement], workspaceID: secondWorkspace)
        #expect(catalog.projectionRecords(forWorkspace: firstWorkspace).isEmpty)
        #expect(catalog.projectionRecords(forWorkspace: secondWorkspace) == [replacement])

        catalog.moveProjections(panelID: panel, to: firstWorkspace)
        catalog.endProjections(panelID: panel)
        let provider = CloudPlacementTestProvider(machine: machine)
        catalog.register(provider)
        catalog.replaceResources([], on: machine, info: provider.info, from: provider)
        #expect(catalog.projectionRecords(forWorkspace: firstWorkspace).isEmpty)
    }
}
