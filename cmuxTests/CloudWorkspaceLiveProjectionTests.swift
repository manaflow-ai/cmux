import Foundation
import Testing
import WebKit
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

    private func install(_ state: CloudVMState, catalog: SurfaceCatalog, extraResources: [SurfaceResource] = []) {
        let info = SurfaceMachineInfo(id: machine, name: "Fixture", status: "running", image: nil, hasDesktop: false,
            memoryMb: nil, diskMb: nil, linkState: .connected, linkError: nil,
            cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil,
            remoteWorkspaces: state.workspaces.map { SurfaceRemoteWorkspace(id: $0.id, name: $0.name, index: $0.index, focused: $0.focused) })
        catalog.replaceCloudState(state, resources: CmuxTuiSnapshotParser.resources(from: state) + extraResources, info: info)
        catalog.reconcileCloudRemoteState(machine: machine, state: state)
    }

    @Test("Cloud refresh and reconnect preserve local Desktop and port splits", arguments: [false, true], [false, true])
    func localDesktopKeepsItsSplit(focusDesktop: Bool, isPort: Bool) async throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let terminal = try #require(workspace.focusedPanelId)
        let browser = try #require(workspace.newBrowserSplit(
            from: terminal, orientation: .horizontal, url: URL(string: "about:blank"),
            focus: focusDesktop, initialDividerPosition: 0.65, websiteDataStore: .nonPersistent()
        ))
        defer { browser.close() }
        let binding = WorkspaceCloudVMBinding(vmID: machine.rawValue, isBase: false, remoteWorkspaceID: "a")
        var closed: [SurfaceProjection] = []
        var appliedLayouts = 0
        let coordinator = CloudWorkspaceProjectionCoordinator(environment: .init(
            bindings: { [workspace.id: binding] }, close: { closed.append($0) },
            applyLayout: { id, layout, projections in
                #expect(id == workspace.id)
                appliedLayouts += 1
                workspace.applyCloudWorkspaceLayout(layout, projections: projections)
            }
        ))
        let catalog = SurfaceCatalog(
            cloudPlacementCoordinator: CloudPlacementCoordinator(binding: { _ in binding }),
            cloudWorkspaceProjectionCoordinator: coordinator
        )
        catalog.register(CloudPlacementTestProvider(machine: machine))
        let desktop = isPort
            ? CmuxTuiSnapshotParser.portBrowser(machine: machine, port: 6969)
            : CmuxTuiSnapshotParser.display(machine: machine)
        catalog.record(SurfaceProjection(
            resource: SurfaceResourceID(machine: machine, kind: .terminal, key: "term_shared"),
            workspaceID: workspace.id, panelID: terminal, remoteWorkspaceID: "a", remoteTabID: "first"
        ))
        catalog.record(SurfaceProjection(
            resource: desktop.id, workspaceID: workspace.id, panelID: browser.id, remoteWorkspaceID: "a"
        ))
        let tree = workspace.bonsplitController.treeSnapshot()
        let focused = workspace.focusedPanelId
        let desktopPane = workspace.paneId(forPanelId: browser.id)
        let panels = Set(workspace.panels.keys)
        for state in [
            try graph(["first": "a"], revision: 1),
            try graph(["first": "a"], revision: 2),
            try graph(["first": "a"], revision: 1, generation: "reconnected")
        ] {
            install(state, catalog: catalog, extraResources: [desktop])
            await coordinator.waitForIdle()
            #expect(workspace.bonsplitController.treeSnapshot() == tree)
            #expect(workspace.paneId(forPanelId: browser.id) == desktopPane)
            #expect(workspace.focusedPanelId == focused)
            #expect(Set(workspace.panels.keys) == panels)
            #expect(catalog.projections.count == 2)
            #expect(closed.isEmpty && coordinator.failures.isEmpty)
        }
        #expect(appliedLayouts == 3, "Exercise the native layout boundary on each accepted graph")
    }

    @Test("Opening a port in a bound Cloud workspace survives reconciliation and follows local moves")
    func openedPortSurvivesReconciliation() async throws {
        let live = LiveWorkspaceFixture()
        defer { live.tearDown() }
        let local = live.id(), other = live.id(), viewer = UUID()
        let bindings = [
            local: WorkspaceCloudVMBinding(vmID: machine.rawValue, isBase: false, remoteWorkspaceID: "a"),
            other: WorkspaceCloudVMBinding(vmID: machine.rawValue, isBase: false, remoteWorkspaceID: "b")
        ]
        var closed: [SurfaceProjection] = []
        let coordinator = CloudWorkspaceProjectionCoordinator(environment: .init(
            bindings: { bindings }, close: { closed.append($0) }
        ))
        let placement = CloudPlacementCoordinator(binding: { bindings[$0] })
        let catalog = SurfaceCatalog(live: live, cloudPlacementCoordinator: placement, cloudWorkspaceProjectionCoordinator: coordinator)
        let provider = CloudPlacementTestProvider(machine: machine)
        catalog.register(provider)
        let port = CmuxTuiSnapshotParser.portBrowser(machine: machine, port: 6969)
        install(try graph(["first": "a"], revision: 1), catalog: catalog, extraResources: [port])
        await coordinator.waitForIdle()
        let opened = try await catalog.openCloudPort(
            machine: machine, port: 6969, into: .workspace(id: local, placement: .split),
            focus: false, reuseExisting: true, reuseInWorkspace: local
        )
        await placement.waitForPendingMutations()
        await coordinator.waitForIdle()
        #expect(catalog.projection(forPanel: opened.projection.panelID)?.remoteWorkspaceID == "a")
        #expect(closed.isEmpty)
        for (destination, expected) in [(other, "b" as String?), (viewer, nil), (local, "a")] {
            catalog.moveProjections(panelID: opened.projection.panelID, to: destination)
            await placement.waitForPendingMutations()
            coordinator.request(machine: machine, catalog: catalog)
            await coordinator.waitForIdle()
            let current = try #require(catalog.projection(forPanel: opened.projection.panelID))
            #expect(current.workspaceID == destination)
            #expect(current.remoteWorkspaceID == expected)
            #expect(current.remoteTabID == nil)
            #expect(closed.isEmpty)
        }
        catalog.endProjections(panelID: opened.projection.panelID)
        await placement.waitForPendingMutations()
        #expect(provider.moved.isEmpty && provider.closedTabs.isEmpty)
    }

    @Test("Existing native workspaces follow create, cross-workspace move, one-view close and reconnect")
    func followsLiveMembership() async throws {
        let live = LiveWorkspaceFixture()
        defer { live.tearDown() }
        let a = live.id(), b = live.id()
        let bindings = [a: WorkspaceCloudVMBinding(vmID: machine.rawValue, isBase: false, remoteWorkspaceID: "a"),
                        b: WorkspaceCloudVMBinding(vmID: machine.rawValue, isBase: false, remoteWorkspaceID: "b")]
        var closed: [SurfaceProjection] = []
        var layouts: [UUID: SurfaceProjectionLayout] = [:]
        let coordinator = CloudWorkspaceProjectionCoordinator(environment: .init(
            bindings: { bindings }, close: { closed.append($0) }, applyLayout: { id, layout, _ in layouts[id] = layout }
        ))
        let catalog = SurfaceCatalog(live: live, cloudPlacementCoordinator: CloudPlacementCoordinator(binding: { bindings[$0] }),
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

    @Test("Opening one remote terminal repeatedly reuses its exact local projection")
    func openingOneTerminalRepeatedlyReusesProjection() async throws {
        let live = LiveWorkspaceFixture()
        defer { live.tearDown() }
        let workspaceID = live.id()
        let remoteWorkspace = SurfaceRemoteWorkspace(
            id: "remote-main", name: "main", index: 0, focused: true
        )
        let remoteView = SurfaceRemoteView(
            tabID: "tab-shell", workspace: remoteWorkspace,
            screenID: "screen-main", paneID: "pane-main", focused: true
        )
        let resourceID = SurfaceResourceID(
            machine: machine, kind: .terminal, key: "term-shell"
        )
        let resource = SurfaceResource(
            id: resourceID, title: "shell", detail: "/", lifecycle: .running,
            agent: nil, remoteWorkspace: remoteWorkspace,
            remoteViews: [remoteView], port: nil, url: nil
        )
        let catalog = SurfaceCatalog(live: live)
        catalog.register(CloudPlacementTestProvider(machine: machine))
        catalog.upsert(resource)

        let first = try await catalog.project(
            resourceID,
            into: .workspace(id: workspaceID, placement: .split),
            focus: false, reuseExisting: true, remoteView: remoteView
        )
        let second = try await catalog.project(
            resourceID,
            into: .workspace(id: workspaceID, placement: .split),
            focus: false, reuseExisting: true, remoteView: remoteView
        )

        #expect(!first.reused)
        #expect(second.reused)
        #expect(first.projection == second.projection)
        #expect(catalog.projections == [first.projection])
    }

    @Test("Lifecycle cancellation is not retained as a projection failure")
    func cancelledMaterializationIsNotAnError() async throws {
        let live = LiveWorkspaceFixture()
        defer { live.tearDown() }
        let local = live.id()
        let coordinator = CloudWorkspaceProjectionCoordinator(environment: .init(bindings: {
            [local: WorkspaceCloudVMBinding(vmID: machine.rawValue, isBase: false, remoteWorkspaceID: "a")]
        }))
        let catalog = SurfaceCatalog(live: live, cloudWorkspaceProjectionCoordinator: coordinator)
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
        let live = LiveWorkspaceFixture()
        defer { live.tearDown() }
        let local = live.id()
        let binding = WorkspaceCloudVMBinding(vmID: machine.rawValue, isBase: false, remoteWorkspaceID: "a")
        let coordinator = CloudWorkspaceProjectionCoordinator(environment: .init(bindings: { [local: binding] }))
        let catalog = SurfaceCatalog(live: live, cloudPlacementCoordinator: CloudPlacementCoordinator(binding: { _ in binding }),
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
        let live = LiveWorkspaceFixture()
        defer { live.tearDown() }
        let local = live.id()
        let binding = WorkspaceCloudVMBinding(vmID: machine.rawValue, isBase: false, remoteWorkspaceID: "a")
        let coordinator = CloudWorkspaceProjectionCoordinator(environment: .init(bindings: { [local: binding] }))
        let catalog = SurfaceCatalog(live: live, cloudPlacementCoordinator: CloudPlacementCoordinator(binding: { _ in binding }),
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
        let live = LiveWorkspaceFixture()
        defer { live.tearDown() }
        let catalog = SurfaceCatalog(live: live)
        let panel = UUID()
        let workspace = live.id()
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
        let live = LiveWorkspaceFixture()
        defer { live.tearDown() }
        let catalog = SurfaceCatalog(live: live)
        let firstWorkspace = live.id(), secondWorkspace = live.id(), panel = UUID()
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
