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
            // The provider is held, so every request overlaps the previous create.
            // Focus alternates between the original and newly reserved surfaces.
            await withTaskGroup(of: Void.self) { group in
                for index in 0..<8 {
                    group.addTask { @MainActor in
                        if index.isMultiple(of: 3) { workspace.focusPanel(sourceID) }
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

    @Test("Wrong creation or materialization receipts are never accepted", arguments: ["creationWorkspace", "projectionWorkspace", "projectionMachine"])
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
            #expect(workspace.openCloudTerminalOptimistically(on: provider.machine, remoteWorkspaceID: provider.remote.id))
            let pendingID = try #require(workspace.cloudPendingCreations.keys.first)
            provider.release.resolve(true)
            try await settled { workspace.cloudMaterializationFailures[pendingID] != nil }
            #expect(catalog.projection(forPanel: pendingID) == nil)
            #expect(workspace.machineOwningSurface(pendingID) == provider.machine)
            #expect(workspace.terminalPanel(for: pendingID)?.surface.ioMode == .manualMirror)
            #expect(workspace.cloudPendingCreations[pendingID] != nil)
            #expect(provider.materialized.count == (kind == "creationWorkspace" ? 0 : 1))
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
            #expect(Set(workspace.panels.keys) == before)
            #expect(workspace.cloudPaneCreationFailureStore.failure?.machine == provider.machine)
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
