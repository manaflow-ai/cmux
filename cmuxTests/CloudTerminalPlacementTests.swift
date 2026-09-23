import Bonsplit
import CmuxControlSocket
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct CloudTerminalPlacementTests {
    @Test("Overlapping creates from pending Cloud panes retain machine and remote workspace", arguments: ["tab", "split", "button", "socketTab", "socketSplit"])
    func overlappingCreates(action: String) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let app = try VaultPaneAppFixture()
            let workspace = app.workspace
            let sourceID = try #require(workspace.focusedPanelId)
            let provider = CloudTerminalPlacementTestProvider()
            let catalog = SurfaceCatalog.shared
            catalog.register(provider)
            let resource = provider.resource(key: "source")
            catalog.upsert(resource, from: provider)
            catalog.record(SurfaceProjection(
                resource: resource.id, workspaceID: workspace.id, panelID: sourceID,
                remoteWorkspaceID: provider.remote.id, remoteTabID: "tab-source"
            ))
            defer {
                workspace.cloudPaneCreationFailureStore.cancelAll()
                provider.release.resolve(true)
                catalog.unregister(machine: provider.machine)
                app.tearDown()
            }
            let before = Set(workspace.panels.keys)
            // All eight independent requests target the same confirmed source.
            // Their remote creates overlap regardless of executor scheduling.
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<8 {
                    group.addTask { @MainActor in
                        workspace.focusPanel(sourceID)
                        perform(action, workspace: workspace)
                    }
                }
            }
            let added = Set(workspace.panels.keys).subtracting(before)
            #expect(added.count == 8)
            try #require(Set(workspace.cloudPendingCreations.keys) == added,
                         "Every visible new pane must already have Cloud ownership before remote creation returns")
            #expect(added.allSatisfy { workspace.machineOwningSurface($0) == provider.machine })
            #expect(added.allSatisfy { workspace.terminalPanel(for: $0)?.surface.ioMode == .manualMirror })

            // Return focus to the original source while the creates are suspended.
            // Completion must adopt each reservation without stealing focus back.
            workspace.focusPanel(sourceID)
            try await settled { provider.requestedWorkspaces.count == 8 }
            provider.release.resolve(true)
            try await settled {
                provider.materialized.count == 8 && !workspace.cloudPaneCreationFailureStore.hasActiveRequests
            }
            #expect(provider.requestedWorkspaces == Array(repeating: provider.remote.id, count: 8))
            let results = added.compactMap { catalog.projection(forPanel: $0) }
            #expect(results.count == 8)
            #expect(results.allSatisfy {
                $0.resource.machine == provider.machine && $0.remoteWorkspaceID == provider.remote.id
                    && $0.workspaceID == workspace.id
            })
            #expect(workspace.focusedPanelId == sourceID)
            #expect(workspace.cloudPendingCreations.isEmpty)
        }
    }

    @Test("Pending child operations wait for their own parent's remote tab")
    func chainedCreatesPreserveRemoteGeometry() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let app = try VaultPaneAppFixture()
            let workspace = app.workspace
            let provider = CloudTerminalPlacementTestProvider()
            let sourceID = try installSource(in: workspace, provider: provider)
            defer {
                workspace.cloudPaneCreationFailureStore.cancelAll()
                provider.release.resolve(true)
                SurfaceCatalog.shared.unregister(machine: provider.machine)
                app.tearDown()
            }
            #expect(workspace.newTerminalSplitOutcome(from: sourceID, orientation: .horizontal).isAccepted)
            let pendingB = try #require(workspace.focusedPanelId)
            #expect(pendingB != sourceID)
            #expect(workspace.newTerminalSplitOutcome(from: pendingB, orientation: .vertical).isAccepted)
            let pendingC = try #require(workspace.focusedPanelId)
            let paneC = try #require(workspace.paneId(forPanelId: pendingC))
            #expect(workspace.newTerminalSurfaceOutcome(inPane: paneC, focus: true).isAccepted)
            #expect(workspace.cloudPendingCreations.count == 3)
            try await settled { provider.requestedWorkspaces.count == 1 }
            #expect(provider.layoutSources.map(\.tabID) == ["tab-source"])
            provider.release.resolve(true)
            try await settled { provider.materialized.count == 3 && !workspace.cloudPaneCreationFailureStore.hasActiveRequests }
            #expect(provider.layoutSources.map(\.tabID) == ["tab-source", "tab-created-0", "tab-created-1"])
            #expect(provider.layoutSources.map(\.direction) == [.right, .down, nil])
            #expect(provider.materialized.allSatisfy {
                $0.resource.machine == provider.machine && $0.remoteWorkspaceID == provider.remote.id
            })
        }
    }

    @Test("Closing a pending parent settles its child visibly without a local fallback")
    func cancelledParentFailsChild() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let app = try VaultPaneAppFixture()
            let workspace = app.workspace
            let provider = CloudTerminalPlacementTestProvider()
            let sourceID = try installSource(in: workspace, provider: provider)
            defer {
                workspace.cloudPaneCreationFailureStore.cancelAll()
                provider.release.resolve(true)
                SurfaceCatalog.shared.unregister(machine: provider.machine)
                app.tearDown()
            }
            #expect(workspace.newTerminalSplitOutcome(from: sourceID, orientation: .horizontal).isAccepted)
            let parentID = try #require(workspace.focusedPanelId)
            #expect(workspace.newTerminalSplitOutcome(from: parentID, orientation: .vertical).isAccepted)
            let childID = try #require(workspace.focusedPanelId)
            try await settled { provider.requestedWorkspaces.count == 1 }
            #expect(workspace.closePanel(parentID, force: true))
            try await settled { workspace.cloudMaterializationFailures[childID] != nil }
            #expect(provider.requestedWorkspaces.count == 1)
            #expect(workspace.machineOwningSurface(childID) == provider.machine)
            #expect(workspace.terminalPanel(for: childID)?.surface.ioMode == .manualMirror)
            #expect(SurfaceCatalog.shared.projection(forPanel: childID) == nil)
        }
    }

    private func installSource(in workspace: Workspace, provider: CloudTerminalPlacementTestProvider) throws -> UUID {
        let sourceID = try #require(workspace.focusedPanelId)
        let resource = provider.resource(key: "source")
        SurfaceCatalog.shared.register(provider)
        SurfaceCatalog.shared.upsert(resource, from: provider)
        SurfaceCatalog.shared.record(SurfaceProjection(
            resource: resource.id, workspaceID: workspace.id, panelID: sourceID,
            remoteWorkspaceID: provider.remote.id, remoteTabID: "tab-source"
        ))
        return sourceID
    }

    @Test("Genuine local sources retain their local creation path", arguments: ["tab", "split", "button", "socketTab", "socketSplit"])
    func localSources(action: String) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let app = try VaultPaneAppFixture()
            defer { app.tearDown() }
            let workspace = app.workspace
            let before = Set(workspace.panels.keys)
            perform(action, workspace: workspace)
            let added = Set(workspace.panels.keys).subtracting(before)
            #expect(added.count == 1)
            #expect(added.allSatisfy { workspace.machineOwningSurface($0) == .local })
            #expect(workspace.cloudPendingCreations.isEmpty)
        }
    }

    @Test("Unavailable Cloud source fails visibly without a local replacement", arguments: ["tab", "split", "button", "socketTab", "socketSplit"])
    func unavailableSource(action: String) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let app = try VaultPaneAppFixture()
            defer { app.tearDown() }
            let workspace = app.workspace
            let sourceID = try #require(workspace.focusedPanelId)
            let machine = SurfaceMachineID.cloud("unavailable-\(UUID())")
            let catalog = SurfaceCatalog.shared
            catalog.record(SurfaceProjection(
                resource: SurfaceResourceID(machine: machine, kind: .terminal, key: "source"),
                workspaceID: workspace.id, panelID: sourceID,
                remoteWorkspaceID: "ws-source", remoteTabID: "tab-source"
            ))
            defer { catalog.endProjections(panelID: sourceID, reason: .replaced) }
            let before = Set(workspace.panels.keys)
            perform(action, workspace: workspace, expectsAcceptance: false)
            #expect(Set(workspace.panels.keys) == before)
            #expect(workspace.bonsplitController.allPaneIds.count == 1)
            #expect(workspace.cloudPaneCreationFailureStore.failure?.machine == machine)
        }
    }

    @Test("Wrong creation or materialization receipts are never accepted", arguments: ["creationWorkspace", "projectionWorkspace", "projectionMachine", "workspaceOnlyResource", "contradictoryWorkspaceView"])
    func mismatchedReceipt(kind: String) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let app = try VaultPaneAppFixture()
            let provider = CloudTerminalPlacementTestProvider()
            let catalog = SurfaceCatalog.shared
            let workspace = app.workspace
            catalog.register(provider)
            defer {
                workspace.cloudPaneCreationFailureStore.cancelAll()
                provider.release.resolve(true)
                catalog.unregister(machine: provider.machine)
                app.tearDown()
            }
            if kind == "creationWorkspace" { provider.returnedWorkspaceID = "other-workspace" }
            if kind == "projectionWorkspace" { provider.projectedWorkspaceID = "other-workspace" }
            if kind == "projectionMachine" { provider.projectedMachine = .local }
            if kind == "workspaceOnlyResource" { provider.omitRemoteViews = true }
            if kind == "contradictoryWorkspaceView" { provider.contradictoryViewWorkspaceID = "other-workspace" }
            #expect(workspace.openCloudTerminalOptimistically(on: provider.machine, remoteWorkspaceID: provider.remote.id))
            let pendingID = try #require(workspace.cloudPendingCreations.keys.first)
            provider.release.resolve(true)
            if kind == "workspaceOnlyResource" {
                try await settled { catalog.projection(forPanel: pendingID) != nil }
                #expect(catalog.projection(forPanel: pendingID)?.remoteWorkspaceID == provider.remote.id)
                #expect(workspace.cloudPendingCreations[pendingID] == nil)
            } else {
                try await settled { workspace.cloudMaterializationFailures[pendingID] != nil }
                #expect(catalog.projection(forPanel: pendingID) == nil)
                #expect(workspace.machineOwningSurface(pendingID) == provider.machine)
                #expect(workspace.terminalPanel(for: pendingID)?.surface.ioMode == .manualMirror)
                #expect(workspace.cloudPendingCreations[pendingID] != nil)
            }
            #expect(provider.materialized.count == (kind == "creationWorkspace" || kind == "contradictoryWorkspaceView" ? 0 : 1))
        }
    }

    @Test("Cloud launch overrides fail closed instead of creating local terminals")
    func launchOverrides() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let app = try VaultPaneAppFixture()
            let provider = CloudTerminalPlacementTestProvider()
            let workspace = app.workspace
            SurfaceCatalog.shared.register(provider)
            defer {
                workspace.cloudPaneCreationFailureStore.cancelAll()
                provider.release.resolve(true)
                SurfaceCatalog.shared.unregister(machine: provider.machine)
                app.tearDown()
            }
            #expect(workspace.openCloudTerminalOptimistically(on: provider.machine, remoteWorkspaceID: provider.remote.id))
            let source = try #require(workspace.focusedPanelId)
            let pane = try #require(workspace.paneId(forPanelId: source))
            let before = Set(workspace.panels.keys)
            #expect(!workspace.newTerminalSurfaceOutcome(inPane: pane, initialCommand: "echo must-not-run-locally").isAccepted)
            #expect(!workspace.newTerminalSplitOutcome(from: source, orientation: .horizontal, workingDirectory: "/tmp").isAccepted)
            #expect(!workspace.newTerminalSplitOutcome(from: source, orientation: .horizontal, initialDividerPosition: 0.3).isAccepted)
            #expect(Set(workspace.panels.keys) == before)
            #expect(workspace.cloudPaneCreationFailureStore.failure?.machine == provider.machine)
        }
    }

    @Test("Staged Cloud identity wins over a local restore placeholder", arguments: [false, true])
    func restoredCloudOwnership(hasLocalPlaceholder: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let app = try VaultPaneAppFixture()
            let workspace = app.workspace
            let source = try #require(workspace.focusedPanelId)
            let catalog = SurfaceCatalog.shared
            let machine = SurfaceMachineID.cloud("restore-\(UUID())")
            defer {
                catalog.endProjections(panelID: source, reason: .replaced)
                catalog.unregister(machine: machine)
                app.tearDown()
            }
            if hasLocalPlaceholder {
                catalog.record(SurfaceProjection(
                    resource: SurfaceResourceID(machine: .local, kind: .terminal, key: source.uuidString),
                    workspaceID: workspace.id, panelID: source
                ))
            }
            catalog.restore([SurfaceProjectionRecord(
                panelID: source, resource: SurfaceResourceID(machine: machine, kind: .terminal, key: "source"),
                remoteWorkspaceID: "restored-workspace", remoteTabID: "restored-tab"
            )], workspaceID: workspace.id)
            let placement = try #require(workspace.cloudTerminalSourcePlacement(forPanel: source))
            #expect(placement.machine == machine)
            #expect(placement.remoteWorkspaceID == "restored-workspace")
            #expect(placement.remoteTabID == "restored-tab")
            let before = Set(workspace.panels.keys)
            for action in ["tab", "split", "button", "socketTab", "socketSplit"] {
                perform(action, workspace: workspace, expectsAcceptance: false)
                #expect(Set(workspace.panels.keys) == before)
                #expect(workspace.cloudPaneCreationFailureStore.failure?.machine == machine)
            }
        }
    }

    @Test("Staged Cloud ownership is scoped to the saved workspace")
    func staleRestoreFromAnotherWorkspaceIsNotASource() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let app = try VaultPaneAppFixture()
            let workspace = app.workspace
            let source = try #require(workspace.focusedPanelId)
            let catalog = SurfaceCatalog.shared
            let machine = SurfaceMachineID.cloud("stale-\(UUID())")
            defer {
                catalog.endProjections(panelID: source, reason: .replaced)
                catalog.unregister(machine: machine)
                app.tearDown()
            }
            catalog.restore([SurfaceProjectionRecord(
                panelID: source, resource: SurfaceResourceID(machine: machine, kind: .terminal, key: "source"),
                remoteWorkspaceID: "other-remote", remoteTabID: "other-tab"
            )], workspaceID: UUID())
            #expect(workspace.cloudTerminalSourcePlacement(forPanel: source) == nil)
        }
    }

    @Test("A local catalog placeholder cannot hide an active Cloud reservation")
    func pendingCreationRemainsCloudThroughLocalSnapshot() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let app = try VaultPaneAppFixture()
            let workspace = app.workspace
            let catalog = SurfaceCatalog.shared
            let provider = CloudTerminalPlacementTestProvider()
            catalog.register(provider)
            defer {
                workspace.cloudPaneCreationFailureStore.cancelAll()
                provider.release.resolve(true)
                catalog.unregister(machine: provider.machine)
                app.tearDown()
            }
            #expect(workspace.openCloudTerminalOptimistically(on: provider.machine, remoteWorkspaceID: provider.remote.id))
            let parent = try #require(workspace.focusedPanelId)
            catalog.record(SurfaceProjection(
                resource: SurfaceResourceID(machine: .local, kind: .terminal, key: parent.uuidString),
                workspaceID: workspace.id, panelID: parent
            ))
            #expect(workspace.newTerminalSplitOutcome(from: parent, orientation: .horizontal).isAccepted)
            #expect(workspace.cloudPendingCreations.count == 2)
            provider.release.resolve(true)
            try await settled { provider.materialized.count == 2 && !workspace.cloudPaneCreationFailureStore.hasActiveRequests }
            #expect(provider.layoutSources.map(\.tabID) == ["tab-created-0"])
            #expect(provider.materialized.allSatisfy {
                $0.resource.machine == provider.machine && $0.remoteWorkspaceID == provider.remote.id
            })
        }
    }

    @Test("Cloud sidebar creates use the group's workspace and localize invalid receipts", arguments: ["terminal", "group", "workspace"])
    func sidebarCreationValidation(action: String) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let catalog = SurfaceCatalog()
            let provider = CloudTerminalPlacementTestProvider(catalog: catalog)
            catalog.register(provider)
            defer { provider.release.resolve(true); catalog.unregister(machine: provider.machine) }
            provider.returnedWorkspaceID = "wrong-workspace"
            var failures: [String] = []
            var finished = false
            // No live local destination makes these exercise the awaited sidebar path.
            let actions = CloudTreeNodeActions.bound(
                navigationHost: AppDelegate.makeCloudTerminalNavigationHost(),
                catalog: { catalog }, selectedWorkspaceID: { UUID() }, selectLocalWorkspace: { _ in },
                onWillMutate: { _ in }, onDidMutate: { finished = true },
                onFailure: { failures.append($0) }, refresh: {}
            )
            let group = SurfaceResourceGroup(title: "source", resources: [], remoteWorkspaceID: provider.remote.id)
            switch action {
            case "terminal": actions.newTerminal(provider.machine, provider.remote.id)
            case "group": actions.openGroup(provider.machine, group, .tab, nil)
            default: actions.openGroupAsWorkspace(provider.machine, group, nil)
            }
            try await settled { provider.requestedWorkspaces.count == 1 }
            #expect(provider.requestedWorkspaces == [provider.remote.id])
            provider.release.resolve(true)
            try await settled { finished }
            #expect(failures == [CloudDiagnosticFailure.placement.label])
            #expect(provider.materialized.isEmpty)
        }
    }

    @Test("An empty local sidebar group does not require a remote workspace")
    func emptyLocalGroupRetainsLocalBehavior() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let live = LiveWorkspaceFixture()
            defer { live.tearDown() }
            let catalog = SurfaceCatalog(live: live)
            let provider = CloudTerminalPlacementTestProvider(machine: .local, catalog: catalog)
            catalog.register(provider)
            defer { provider.release.resolve(true); catalog.unregister(machine: .local) }
            let originalDestination = live.id()
            var selectedDestination = originalDestination
            var failures: [String] = []
            var finished = false
            let actions = CloudTreeNodeActions.bound(
                navigationHost: AppDelegate.makeCloudTerminalNavigationHost(),
                catalog: { catalog }, selectedWorkspaceID: { selectedDestination }, selectLocalWorkspace: { _ in },
                onWillMutate: { _ in }, onDidMutate: { finished = true },
                onFailure: { failures.append($0) }, refresh: {}
            )
            actions.openGroup(.local, SurfaceResourceGroup(title: "local", resources: []), .tab, nil)
            selectedDestination = UUID()
            provider.release.resolve(true)
            try await settled { finished }
            #expect(failures.isEmpty)
            #expect(provider.requestedWorkspaces.count == 1 && provider.requestedWorkspaces[0] == nil)
            #expect(provider.materialized.count == 1)
            #expect(provider.materialized.first?.resource.machine == .local)
            #expect(provider.materialized.first?.workspaceID == originalDestination)
        }
    }

    @Test("A machine-level pending parent resolves its own workspace and tab", arguments: [false, true])
    func machineLevelParent(omitsTab: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let app = try VaultPaneAppFixture()
            let workspace = app.workspace
            let provider = CloudTerminalPlacementTestProvider()
            provider.returnedWorkspaceID = provider.remote.id
            provider.omitRemoteViews = omitsTab
            SurfaceCatalog.shared.register(provider)
            defer {
                workspace.cloudPaneCreationFailureStore.cancelAll()
                provider.release.resolve(true)
                SurfaceCatalog.shared.unregister(machine: provider.machine)
                app.tearDown()
            }
            #expect(workspace.openCloudTerminalOptimistically(on: provider.machine, remoteWorkspaceID: nil))
            let parent = try #require(workspace.focusedPanelId)
            #expect(workspace.newTerminalSplitOutcome(from: parent, orientation: .vertical).isAccepted)
            let child = try #require(workspace.focusedPanelId)
            provider.release.resolve(true)
            if omitsTab {
                try await settled { workspace.cloudMaterializationFailures[child] != nil }
                #expect(provider.requestedWorkspaces.count == 1)
                #expect(provider.layoutSources.isEmpty)
                #expect(workspace.terminalPanel(for: child)?.surface.ioMode == .manualMirror)
            } else {
                try await settled { provider.materialized.count == 2 && !workspace.cloudPaneCreationFailureStore.hasActiveRequests }
                #expect(provider.layoutSources.map(\.tabID) == ["tab-created-0"])
                #expect(SurfaceCatalog.shared.projection(forPanel: child)?.remoteWorkspaceID == provider.remote.id)
            }
        }
    }

    private func perform(_ action: String, workspace: Workspace, expectsAcceptance: Bool = true) {
        guard let sourceID = workspace.focusedPanelId,
              let paneID = workspace.paneId(forPanelId: sourceID) else {
            Issue.record("Source pane is missing")
            return
        }
        let routing = ControlRoutingSelectors(
            hasWindowIDParam: false, windowID: nil, groupID: nil,
            workspaceID: workspace.id, surfaceID: nil, paneID: nil
        )
        TerminalController.withSocketCommandPolicyStack([true]) {
            switch action {
            case "tab":
                #expect(workspace.newTerminalSurfaceOutcome(inPane: paneID, focus: true).isAccepted == expectsAcceptance)
            case "split":
                #expect(workspace.newTerminalSplitOutcome(from: sourceID, orientation: .horizontal, focus: true).isAccepted == expectsAcceptance)
            case "button":
                #expect(workspace.bonsplitController.splitPane(paneID, orientation: .horizontal) != nil)
            case "socketTab":
                let result = TerminalController.shared.controlSurfaceCreate(routing: routing, inputs: .init(
                    typeRaw: "terminal", providerRaw: nil, rendererRaw: nil, urlRaw: nil,
                    workingDirectory: nil, initialCommand: nil, tmuxStartCommand: nil, remotePTYSessionID: nil,
                    remoteContextRaw: nil, startupEnvironment: [:], requestedPaneID: paneID.id, requestedFocus: true
                ))
                switch result {
                case .created, .routedToRemote: #expect(expectsAcceptance)
                case .createFailed: #expect(!expectsAcceptance)
                default: Issue.record("Create failed: \(result)")
                }
            default:
                let result = TerminalController.shared.controlSurfaceSplit(routing: routing, inputs: .init(
                    directionRaw: "right", typeRaw: "terminal", urlRaw: nil, requestedSourceSurfaceID: sourceID,
                    workingDirectory: nil, initialCommand: nil, tmuxStartCommand: nil, remotePTYSessionID: nil,
                    remoteContextRaw: nil, startupEnvironment: [:], clientUnsupportedRemoteTmuxOptions: [],
                    requestedFocus: true, initialDividerPosition: nil
                ))
                switch result {
                case .created, .routedToRemote: #expect(expectsAcceptance)
                case .createFailed: #expect(!expectsAcceptance)
                default: Issue.record("Split failed: \(result)")
                }
            }
        }
    }

    /// Only bounds test completion; the provider barrier controls the interleaving.
    private func settled(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition())
    }
}
