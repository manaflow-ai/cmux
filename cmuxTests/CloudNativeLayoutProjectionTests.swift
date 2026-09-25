import CMUXMobileCore
import CMUXAuthCore
import CmuxAuthRuntime
import CmuxCore
import CmuxIrohTransport
import CmuxSurfaceCatalogModel
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Native Cloud layout projection preserves panels and focus")
struct CloudNativeLayoutProjectionTests {
    @Test("Closing a mirrored Mac terminal updates its owner, while teardown only detaches",
          arguments: [SurfaceProjectionEndReason.paneClosed, .workspaceTeardown, .replaced])
    func closingDeviceProjectionUpdatesSource(reason: SurfaceProjectionEndReason) async throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let viewer = try #require(manager.selectedWorkspace)
        let pane = try #require(viewer.bonsplitController.allPaneIds.first)
        let first = try #require(viewer.focusedPanelId)
        let second = try #require(viewer.newTerminalSurface(inPane: pane, focus: false)?.id)
        defer { viewer.teardownAllPanels(); manager.tabs = [] }
        let instance = SurfaceDeviceInstanceID(deviceID: "close-owner", tag: "test")
        let machine = SurfaceMachineID.device(instance)
        let remoteID = UUID().uuidString
        let remoteA = UUID().uuidString, remoteB = UUID().uuidString
        let catalog = SurfaceCatalog()
        let defaultsName = "DeviceProjectionClose-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let auth = makeDeviceTestAuth(defaults: defaults)
        let record = DeviceDirectoryRecord(instance: instance, deviceName: "Source", platform: "mac",
            bundleID: nil, presenceState: .online, isPaired: false, lastSeenAt: nil, routes: [],
            ownerUserID: "test", accountTrust: .sameAccount)
        let link = DeviceLink(record: record, runtime: DeviceLinkRuntime(tokens: HiveAccountTokenSource(
            auth: auth, identity: AuthenticatedSessionIdentity(generation: 0, accountID: "test"), teamID: nil
        )), authorization: UnpairedDeviceLayoutSource())
        let provider = DeviceSurfaceProvider(record: record, link: link, catalog: catalog)
        defer { provider.stop() }
        catalog.register(provider)
        let remoteWorkspace = SurfaceRemoteWorkspace(id: remoteID, name: "Source", index: 0, focused: false)
        for (panel, remote) in [(first, remoteA), (second, remoteB)] {
            let resource = SurfaceResource(id: .init(machine: machine, kind: .terminal, key: remote),
                title: remote, detail: nil, lifecycle: .running, agent: nil, remoteWorkspace: remoteWorkspace,
                remoteViews: [SurfaceRemoteView(tabID: remote, workspace: remoteWorkspace)], port: nil, url: nil)
            catalog.upsert(resource)
            catalog.record(.init(resource: resource.id, workspaceID: viewer.id, panelID: panel,
                remoteWorkspaceID: remoteID, remoteTabID: remote))
        }
        var source = DeviceWorkspaceLayoutSnapshot(workspaceID: remoteID,
            layout: .pane(id: "source", surfaceIDs: [remoteA, remoteB], selectedSurfaceID: remoteA),
            revision: "initial", sequence: 1)
        var closes = 0
        let coordinator = DeviceWorkspaceLayoutCoordinator(machine: machine, catalog: catalog,
            workspace: { $0 == viewer.id ? viewer : nil },
            request: { method, params in
                if method == "mobile.terminal.close" {
                    #expect(params["workspace_id"] as? String == remoteID)
                    #expect(params["surface_id"] as? String == remoteB)
                    closes += 1
                    source = DeviceWorkspaceLayoutSnapshot(workspaceID: remoteID,
                        layout: .pane(id: "source", surfaceIDs: [remoteA], selectedSurfaceID: remoteA),
                        revision: "closed", sequence: 2)
                    return try JSONSerialization.data(withJSONObject: ["closed": true,
                        "workspace_id": remoteID, "surface_id": remoteB])
                }
                #expect(method == "device.workspace.layout")
                return try JSONEncoder().encode(source)
            }, refresh: {}, isConnected: { true }, didAccept: {}, notificationCenter: NotificationCenter())
        provider.layoutSync = coordinator
        coordinator.accept(source)
        await coordinator.waitForIdle()
        viewer.performRemoteTmuxMirrorMutation { _ = viewer.closePanel(second, force: true) }
        catalog.endProjections(panelID: second, reason: reason)
        await coordinator.waitForIdle()
        let shouldClose = reason == .paneClosed
        #expect(closes == (shouldClose ? 1 : 0))
        #expect(try source.layout.validatedSurfaceIDs() == (shouldClose ? [remoteA] : [remoteA, remoteB]))
        if shouldClose {
            let mapping = [first.uuidString: remoteA]
            #expect(try viewer.deviceWorkspaceLayoutSnapshot()?.remappingSurfaceIDs(mapping).hasSameArrangement(as: source.layout) == true)
        }
    }

    private func makeDeviceTestAuth(defaults: UserDefaults) -> AuthCoordinator {
        let config = AuthConfig(stack: CMUXAuthConfig(projectId: "test", publishableClientKey: "test"),
            magicLinkCallbackURL: "http://127.0.0.1:1/auth/callback", apiBaseURL: "http://127.0.0.1:1")
        return AuthCoordinator(
            client: StackAuthClient(config: config, tokenStore: .memory, noAutomaticPrefetch: true),
            sessionCache: CMUXAuthSessionCache(keyValueStore: defaults, key: "session"),
            userCache: CMUXAuthIdentityStore(keyValueStore: defaults, key: "user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: defaults, key: "team"),
            anchor: AuthPresentationContextProvider(), config: config,
            launch: AuthLaunchOptions(clearAuthRequested: false, mockDataEnabled: false, environment: [:], includesDevAuth: false))
    }

    private final class UnpairedDeviceLayoutSource: DeviceLinkAuthorizationSource {
        var pairedDevices: [DevicePairedDevice] { [] }
        let authorizationDidChangeNotification = Notification.Name("DeviceLayout-\(UUID().uuidString)")
        func authorization(for instance: SurfaceDeviceInstanceID, route: CmxAttachRoute) -> CmxLegacyTailscaleAuthorizationEvidence? { nil }
    }

    @Test func nativeMirrorTabInsertionHonorsTheSourceOrder() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        defer { workspace.teardownAllPanels(); manager.tabs = [] }
        var ids: [String: UUID] = [:]
        for (name, index) in [("C", 0), ("A", 0), ("B", 1), ("D", 3)] {
            let panel = try #require(workspace.makeRemoteTmuxPanePanel(onInput: { _ in }, keyNameResolver: nil))
            ids[name] = try workspace.insertCloudManualMirrorPanel(panel,
                at: .tab(workspaceID: workspace.id, paneID: pane.id.uuidString, index: index),
                focus: name == "C", isLoading: false)
        }
        let expected = ["A", "B", "C", "D"].compactMap { ids[$0] }.compactMap { workspace.surfaceIdFromPanelId($0) }
        let actual = workspace.bonsplitController.tabs(inPane: pane).map(\.id)
            .filter { expected.contains($0) }
        #expect(actual == expected)
        #expect(workspace.focusedPanelId == ids["C"])
    }

    @Test(.timeLimit(.minutes(1)))
    func deviceLayoutsRoundTripWithoutEchoAndPreserveTheNewestGesture() async throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let viewer = try #require(manager.selectedWorkspace)
        let pane = try #require(viewer.bonsplitController.allPaneIds.first)
        let first = try #require(viewer.focusedPanelId)
        let second = try #require(viewer.newTerminalSurface(inPane: pane, focus: false)?.id)
        defer { viewer.teardownAllPanels(); manager.tabs = [] }
        let machine = SurfaceMachineID.device(.init(deviceID: "layout-owner", tag: "test"))
        let remoteID = UUID()
        let remoteA = UUID().uuidString
        let remoteB = UUID().uuidString
        let catalog = SurfaceCatalog()
        let provider = CloudPlacementTestProvider(machine: machine)
        catalog.register(provider)
        let remoteWorkspace = SurfaceRemoteWorkspace(id: remoteID.uuidString, name: "Remote", index: 0, focused: false)
        for (panel, remote) in [(first, remoteA), (second, remoteB)] {
            let resource = SurfaceResource(id: .init(machine: machine, kind: .terminal, key: remote),
                title: remote, detail: nil, lifecycle: .running, agent: nil, remoteWorkspace: remoteWorkspace,
                remoteViews: [SurfaceRemoteView(tabID: remote, workspace: remoteWorkspace)], port: nil, url: nil)
            catalog.upsert(resource)
            catalog.record(.init(resource: resource.id, workspaceID: viewer.id, panelID: panel,
                remoteWorkspaceID: remoteID.uuidString, remoteTabID: remote))
        }
        let localLayout: (Double) -> DeviceWorkspaceLayoutNode = { ratio in
            .split(direction: .horizontal, ratio: ratio,
                first: .pane(id: "left", surfaceIDs: [first.uuidString], selectedSurfaceID: first.uuidString),
                second: .pane(id: "right", surfaceIDs: [second.uuidString], selectedSurfaceID: second.uuidString))
        }
        let mapping = [first.uuidString: remoteA, second.uuidString: remoteB]
        var source = try localLayout(0.4).remappingSurfaceIDs(mapping)
        weak var receiver: DeviceWorkspaceLayoutCoordinator?
        let host = DeviceWorkspaceLayoutHost(capture: { $0 == remoteID ? source : nil },
            apply: { _, next in source = next }, createTerminal: { _, _, _ in nil },
            publish: { receiver?.accept($0) }, notificationCenter: NotificationCenter())
        var writes = 0
        var closeAttempts = 0
        var rejectNext = false
        var holdNext = false
        var release: CheckedContinuation<Void, Never>?
        let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let coordinator = DeviceWorkspaceLayoutCoordinator(machine: machine, catalog: catalog,
            workspace: { $0 == viewer.id ? viewer : nil },
            request: { method, params in
                if method == "mobile.terminal.close" {
                    closeAttempts += 1
                    throw DeviceLinkError.notConnected
                }
                if method == "device.workspace.layout.apply" {
                    writes += 1
                    if rejectNext { rejectNext = false; throw DeviceLinkError.notConnected }
                    if holdNext {
                        holdNext = false
                        entered.continuation.yield(())
                        await withCheckedContinuation { release = $0 }
                    }
                }
                switch host.handle(.init(id: nil, method: method, params: params, auth: nil)) {
                case .ok(let payload): return try JSONSerialization.data(withJSONObject: payload)
                case .failure(let error): throw error
                case nil: throw DeviceLinkError.malformedResponse(method)
                }
            }, refresh: {}, isConnected: { true }, didAccept: {}, notificationCenter: NotificationCenter())
        receiver = coordinator
        provider.onProjectionEnd = { coordinator.projectionDidEnd($0, reason: $1) }
        provider.materializeProjection = { resource, view, _ in
            let pane = try #require(viewer.bonsplitController.allPaneIds.first)
            let panel = try #require(viewer.newTerminalSurface(inPane: pane, focus: false))
            return SurfaceProjection(resource: resource.id, workspaceID: viewer.id, panelID: panel.id,
                remoteWorkspaceID: view?.workspace.id, remoteTabID: view?.tabID)
        }
        defer { coordinator.stop(); entered.continuation.finish() }
        let initial = try #require(host.snapshot(for: remoteID))
        coordinator.accept(initial)
        await coordinator.waitForIdle()
        #expect(try viewer.deviceWorkspaceLayoutSnapshot()?.remappingSurfaceIDs(mapping).hasSameArrangement(as: source) == true)

        // A remote application must not be echoed as a user edit.
        coordinator.nativeLayoutChanged(workspaceID: viewer.id, capturedLayout: localLayout(0.4), isExternal: true)
        await coordinator.waitForIdle()
        #expect(writes == 0)

        holdNext = true
        coordinator.nativeLayoutChanged(workspaceID: viewer.id, capturedLayout: localLayout(0.55))
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
        coordinator.nativeLayoutChanged(workspaceID: viewer.id, capturedLayout: localLayout(0.7))
        release?.resume()
        await coordinator.waitForIdle()
        #expect(writes == 2)
        #expect(source.hasSameArrangement(as: try localLayout(0.7).remappingSurfaceIDs(mapping)))

        // Older events cannot replace an accepted reply; source edits do project live.
        coordinator.accept(initial)
        source = try localLayout(0.3).remappingSurfaceIDs(mapping)
        _ = host.snapshot(for: remoteID)
        await coordinator.waitForIdle()
        #expect(try viewer.deviceWorkspaceLayoutSnapshot()?.remappingSurfaceIDs(mapping).hasSameArrangement(as: source) == true)
        #expect(writes == 2)

        rejectNext = true
        try viewer.applyDeviceWorkspaceLayout(localLayout(0.8))
        coordinator.nativeLayoutChanged(workspaceID: viewer.id, capturedLayout: localLayout(0.8))
        await coordinator.waitForIdle()
        #expect(try viewer.deviceWorkspaceLayoutSnapshot()?.remappingSurfaceIDs(mapping).hasSameArrangement(as: source) == true,
            "A failed write rolls the viewer back to the authoritative source layout")
        #expect(Set(viewer.panels.keys) == [first, second], "Layout reconciliation preserves terminal instances")

        viewer.performRemoteTmuxMirrorMutation { _ = viewer.closePanel(second, force: true) }
        catalog.endProjections(panelID: second)
        await coordinator.waitForIdle()
        #expect(closeAttempts == 1)
        let restored = catalog.projections.filter { $0.workspaceID == viewer.id }
        #expect(Set(restored.map(\.resource.key)) == [remoteA, remoteB], "A failed close restores the source terminal in the viewer")
        let restoredMapping = Dictionary(uniqueKeysWithValues: restored.map { ($0.panelID.uuidString, $0.resource.key) })
        #expect(try viewer.deviceWorkspaceLayoutSnapshot()?.remappingSurfaceIDs(restoredMapping).hasSameArrangement(as: source) == true)
    }

    @Test(arguments: [false, true])
    func newWorkspaceActionKeepsTheSelectedDeviceContext(fromSidebar: Bool) async throws {
        let manager = TabManager(createInitialWorkspace: false)
        let workspace = Workspace(title: "Other Mac", initialSurface: .cloudVMLoading)
        manager.tabs = [workspace]
        manager.selectedTabId = workspace.id
        defer { workspace.teardownAllPanels(); manager.tabs = [] }
        let panelID = try #require(workspace.focusedPanelId)
        let machine = SurfaceMachineID.device(.init(deviceID: "other-mac", tag: "test"))
        workspace.cloudBindingState.updateCatalogMetadata(resources: [panelID: .init(machine: machine, kind: .terminal, key: "remote")], machineNames: [:])
        let app = AppDelegate()
        let operations = CloudWorkspaceOperationController(isAvailable: { true })
        var targets: [SurfaceMachineID] = []
        app.deviceWorkspaceCreationCoordinator = DeviceWorkspaceCreationCoordinator(operations: operations,
            create: { target, owner in
                #expect(owner === manager)
                targets.append(target)
            })
        if fromSidebar {
            app.createWorkspaceAtEndFromSidebar(windowId: UUID(), tabManager: manager)
            app.createWorkspaceAtEndFromSidebar(windowId: UUID(), tabManager: manager)
        } else {
            #expect(app.performNewWorkspaceAction(tabManager: manager))
            #expect(!app.performNewWorkspaceAction(tabManager: manager))
        }
        await operations.waitForPendingOperations()
        #expect(targets == [machine])
        #expect(manager.tabs.map(\.id) == [workspace.id], "The route must not create a local fallback workspace")
        app.deviceWorkspaceCreationCoordinator = nil
        if fromSidebar {
            app.createWorkspaceAtEndFromSidebar(windowId: UUID(), tabManager: manager)
        } else {
            #expect(!app.performNewWorkspaceAction(tabManager: manager))
        }
        #expect(manager.tabs.map(\.id) == [workspace.id])
    }

    @Test func deviceLayoutWritesAreScopedAndRejectStaleRevisions() throws {
        let workspaceID = UUID()
        let a = UUID().uuidString
        let b = UUID().uuidString
        var layout = DeviceWorkspaceLayoutNode.pane(id: "pane", surfaceIDs: [a, b], selectedSurfaceID: a)
        var writes = 0
        let host = DeviceWorkspaceLayoutHost(
            capture: { $0 == workspaceID ? layout : nil },
            apply: { id, next in
                #expect(id == workspaceID)
                writes += 1
                layout = next
            },
            createTerminal: { _, _, _ in nil },
            publish: { _ in },
            notificationCenter: NotificationCenter()
        )
        let initial = try #require(host.snapshot(for: workspaceID))
        let next = DeviceWorkspaceLayoutNode.split(direction: .horizontal, ratio: 0.35,
            first: .pane(id: "local-a", surfaceIDs: [a], selectedSurfaceID: a),
            second: .pane(id: "local-b", surfaceIDs: [b], selectedSurfaceID: b))
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(next))
        let params: [String: Any] = ["workspace_id": workspaceID.uuidString,
            "request_id": "move-1", "base_revision": initial.revision, "layout": encoded]
        let request = MobileHostRPCRequest(id: "edit", method: "device.workspace.layout.apply", params: params, auth: nil)
        guard case .ok = host.handle(request) else { Issue.record("Expected accepted layout"); return }
        #expect(layout.hasSameArrangement(as: next))
        #expect(writes == 1)
        guard case .ok = host.handle(request) else { Issue.record("Expected idempotent receipt"); return }
        #expect(writes == 1)
        var stale = params
        stale["request_id"] = "move-2"
        guard case .failure(let error) = host.handle(.init(id: nil, method: request.method, params: stale, auth: nil)) else {
            Issue.record("A stale edit must be rejected"); return
        }
        #expect(error.code == "layout_conflict")
        stale["base_revision"] = try #require(host.snapshot(for: workspaceID)).revision
        stale["layout"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            DeviceWorkspaceLayoutNode.pane(id: "foreign", surfaceIDs: [UUID().uuidString], selectedSurfaceID: nil)))
        guard case .failure = host.handle(.init(id: nil, method: request.method, params: stale, auth: nil)) else {
            Issue.record("A layout must not borrow terminals from another workspace"); return
        }
        #expect(writes == 1)
    }

    @Test func deviceNamesFollowTheCatalogWithoutCreatingACloudBinding() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelId)
        let service = CloudWorkspaceRenameService(environment: .init(
            workspace: { $0 == workspace.id ? workspace : nil },
            tabManager: { $0 == workspace.id ? manager : nil }, workspaces: { [workspace] }
        ))
        let catalog = SurfaceCatalog(cloudWorkspaceRenameService: service)
        let machine = SurfaceMachineID.device(SurfaceDeviceInstanceID(deviceID: UUID().uuidString, tag: "default"))
        catalog.register(CloudPlacementTestProvider(machine: machine))
        let remote = SurfaceRemoteWorkspace(id: "source-workspace", name: "Source project", index: 0, focused: true)
        var resource = SurfaceResource(id: SurfaceResourceID(machine: machine, kind: .terminal, key: "terminal"),
            title: "Build logs", detail: "/remote/project", lifecycle: .running, agent: nil, remoteWorkspace: remote,
            remoteViews: [SurfaceRemoteView(tabID: "terminal", workspace: remote, name: "Build logs")], port: nil, url: nil)
        catalog.upsert(resource)
        catalog.record(SurfaceProjection(resource: resource.id, workspaceID: workspace.id, panelID: panelID,
            remoteWorkspaceID: remote.id, remoteTabID: "terminal"))
        catalog.replaceResources([resource], on: machine)
        #expect(workspace.title == "Source project")
        #expect(workspace.panelTitle(panelId: panelID) == "Build logs")
        #expect(workspace.cloudVMBinding == nil)
        resource.title = "Tests"
        resource.remoteViews?[0].name = "Tests"
        resource.remoteViews?[0].workspace.name = "Renamed project"
        resource.remoteWorkspace?.name = "Renamed project"
        catalog.replaceResources([resource], on: machine)
        #expect(workspace.title == "Renamed project")
        #expect(workspace.panelTitle(panelId: panelID) == "Tests")
        #expect(workspace.cloudVMBinding == nil)
        for panel in workspace.panels.values { panel.close() }
        manager.tabs = []
    }

    @Test func macLayoutRequestReadsOnlyTheRequestedWorkspace() throws {
        let id = UUID()
        let layout = DeviceWorkspaceLayoutNode.pane(id: "pane", surfaceIDs: ["first", "second"], selectedSurfaceID: "second")
        var reads: [UUID] = []
        let rpc = DeviceWorkspaceLayoutHost(capture: { requested in
            reads.append(requested)
            return requested == id ? layout : nil
        }, apply: { _, _ in Issue.record("A read must not mutate layout") }, createTerminal: { _, _, _ in nil },
            publish: { _ in }, notificationCenter: NotificationCenter())
        let request = MobileHostRPCRequest(id: "layout", method: "device.workspace.layout", params: ["workspace_id": id.uuidString], auth: nil)
        guard case .ok(let payload) = rpc.handle(request) else {
            Issue.record("Expected a Mac layout snapshot"); return
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        let snapshot = try JSONDecoder().decode(DeviceWorkspaceLayoutSnapshot.self, from: data)
        #expect(snapshot.workspaceID == id.uuidString)
        #expect(snapshot.layout == layout)
        #expect(!snapshot.revision.isEmpty)
        #expect(reads == [id])
        #expect(rpc.handle(MobileHostRPCRequest(id: nil, method: "mobile.sync.fetch", params: [:], auth: nil)) == nil)
        #expect(reads == [id], "Mobile sync does not enter the Mac layout handler")
    }

    @Test func deviceLayoutCapturesNativeTabGroupsAndDividers() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        defer { for panel in workspace.panels.values { panel.close() }; manager.tabs = [] }
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let first = try #require(workspace.focusedPanelId)
        var panels = [first]
        for _ in 0..<3 { panels.append(try #require(workspace.newTerminalSurface(inPane: pane, focus: false)?.id)) }
        let machine = SurfaceMachineID.cloud("layout-capture")
        let projections = panels.enumerated().map { index, panel in
            SurfaceProjection(resource: SurfaceResourceID(machine: machine, kind: .terminal, key: "t\(index)"),
                workspaceID: workspace.id, panelID: panel, remoteWorkspaceID: "remote", remoteTabID: "tab\(index)")
        }
        let placements = projections.map {
            SurfaceResourcePlacement(resource: $0.resource, remoteWorkspaceID: $0.remoteWorkspaceID, remoteTabID: $0.remoteTabID)
        }
        workspace.applyCloudWorkspaceLayout(.split(direction: .right, ratio: 0.65,
            first: .leaf(placements: Array(placements[0...1])),
            second: .split(direction: .down, ratio: 0.3,
                first: .leaf(placements: [placements[2]]), second: .leaf(placements: [placements[3]]))), projections: projections)
        workspace.bonsplitController.selectTab(try #require(workspace.surfaceIdFromPanelId(panels[1])))

        let captured = try #require(workspace.deviceWorkspaceLayoutSnapshot())
        guard case .split(let direction, let ratio, let left, let right) = captured,
              case .pane(_, let leftSurfaces, let selected) = left,
              case .split(let nestedDirection, let nestedRatio, let top, let bottom) = right,
              case .pane(_, let topSurfaces, _) = top,
              case .pane(_, let bottomSurfaces, _) = bottom else {
            Issue.record("The Mac layout tree must preserve the native nested splits"); return
        }
        #expect(direction == .horizontal && abs(ratio - 0.65) < 0.001)
        #expect(nestedDirection == .vertical && abs(nestedRatio - 0.3) < 0.001)
        #expect(leftSurfaces == Array(panels[0...1]).map(\.uuidString))
        #expect(selected == panels[1].uuidString)
        #expect(topSurfaces == [panels[2].uuidString])
        #expect(bottomSurfaces == [panels[3].uuidString])
    }

    @Test func topologyReusesPanelsAndPreservesSelectedTerminal() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let first = try #require(workspace.focusedPanelId)
        let second = try #require(workspace.newTerminalSurface(inPane: pane, focus: false)?.id)
        let third = try #require(workspace.newTerminalSurface(inPane: pane, focus: false)?.id)
        let machine = SurfaceMachineID.cloud("native-fixture")
        let projections = [first, second, third].enumerated().map { index, panel in
            SurfaceProjection(resource: SurfaceResourceID(machine: machine, kind: .terminal, key: "term_\(index)"),
                              workspaceID: workspace.id, panelID: panel, remoteWorkspaceID: "remote", remoteTabID: "tab_\(index)")
        }
        let placements = projections.map {
            SurfaceResourcePlacement(resource: $0.resource, remoteWorkspaceID: $0.remoteWorkspaceID, remoteTabID: $0.remoteTabID)
        }
        let secondTab = try #require(workspace.surfaceIdFromPanelId(second))
        workspace.bonsplitController.selectTab(secondTab)
        let originalPanels = Set(workspace.panels.keys)
        let layout = SurfaceProjectionLayout.split(direction: .right, ratio: 0.6,
            first: .leaf(placements: [placements[0]]), second: .split(direction: .down, ratio: 0.4,
                first: .leaf(placements: [placements[1]]), second: .leaf(placements: [placements[2]])))
        workspace.applyCloudWorkspaceLayout(layout, projections: projections)
        #expect(Set(workspace.panels.keys) == originalPanels)
        #expect(workspace.bonsplitController.allPaneIds.count == 3)
        #expect(workspace.bonsplitController.focusedPaneId == workspace.paneId(forPanelId: second))
        let secondPane = try #require(workspace.paneId(forPanelId: second))
        #expect(workspace.bonsplitController.selectedTab(inPane: secondPane)?.id == secondTab)
        let tree = workspace.bonsplitController.treeSnapshot()
        guard case .split(let root) = tree, case .split(let right) = root.second else {
            Issue.record("Expected the daemon split structure"); return
        }
        #expect(root.orientation == "horizontal" && right.orientation == "vertical")
        #expect(abs(root.dividerPosition - 0.6) < 0.001)
        #expect(abs(right.dividerPosition - 0.4) < 0.001)
        workspace.applyCloudWorkspaceLayout(layout, projections: projections)
        #expect(workspace.bonsplitController.treeSnapshot() == tree, "repeated refresh is a geometry no-op")
        workspace.applyCloudWorkspaceLayout(.leaf(placements: Array(placements.reversed())), projections: projections)
        #expect(workspace.bonsplitController.allPaneIds.count == 1)
        let finalPane = try #require(workspace.bonsplitController.allPaneIds.first)
        #expect(workspace.bonsplitController.tabs(inPane: finalPane).map(\.id) == [third, second, first].compactMap { workspace.surfaceIdFromPanelId($0) })
        #expect(Set(workspace.panels.keys) == originalPanels)
    }
}
