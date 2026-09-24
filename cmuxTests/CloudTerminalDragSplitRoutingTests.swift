import Bonsplit
import CmuxCore
import CmuxSurfaceCatalogModel
import Foundation
import Testing
@testable import CmuxTerminal
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct CloudTerminalDragSplitRoutingTests {
    @Test("One-tab Cloud edge drags inherit their moved source, including before attachment",
          arguments: ["left", "right", "up", "down"], ["bonsplit", "portal"])
    func cloudDrag(direction: String, entrypoint: String) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let app = try VaultPaneAppFixture()
            let workspace = app.workspace
            let provider = CloudTerminalPlacementTestProvider()
            let source = try installSource(in: workspace, provider: provider)
            let sourcePane = try #require(workspace.paneId(forPanelId: source))
            let terminal = try #require(workspace.terminalPanel(for: source))
            let font = terminal.surface.recordObservedFontSizeLineage(
                runtimePoints: 19, isExplicitOverride: true, globalFontMagnificationPercent: 100
            )
            defer { tearDown(app, provider: provider) }
            let before = Set(workspace.panels.keys)

            try drag(source, in: workspace, direction: direction, entrypoint: entrypoint)

            let added = Set(workspace.panels.keys).subtracting(before)
            try #require(added.count == 1)
            let replacement = try #require(added.first)
            #expect(app.manager.tabs.count == 1)
            #expect(workspace.focusedPanelId == source)
            #expect(workspace.paneId(forPanelId: source) != sourcePane)
            #expect(workspace.paneId(forPanelId: replacement) == sourcePane)
            #expect(workspace.bonsplitController.tabs(inPane: sourcePane).count == 1)
            #expect(workspace.cloudPendingCreations[replacement]?.machine == provider.machine)
            #expect(workspace.cloudPendingCreations[replacement]?.remoteWorkspaceID == provider.remote.id)
            #expect(workspace.machineOwningSurface(replacement) == provider.machine)
            #expect(workspace.terminalPanel(for: replacement)?.surface.ioMode == .manualMirror)
            #expect(workspace.terminalPanel(for: replacement)?.surface.fontSizeLineageSnapshot() == font)

            try await settled { provider.layoutSources.count == 1 }
            #expect(provider.layoutSources.first?.tabID == "tab-source")
            #expect(provider.layoutSources.first?.direction != nil)
            #expect(provider.requestedWorkspaces == [provider.remote.id])
            provider.release.resolve(true)
            try await settled { !workspace.cloudPaneCreationFailureStore.hasActiveRequests }
            let projection = try #require(SurfaceCatalog.shared.projection(forPanel: replacement))
            #expect(projection.workspaceID == workspace.id)
            #expect(projection.resource.machine == provider.machine)
            #expect(projection.remoteWorkspaceID == provider.remote.id)
            #expect(workspace.focusedPanelId == source)
            #expect(workspace.cloudPendingCreations.isEmpty)
        }
    }

    @Test("Disconnected and restored Cloud sources fail visibly without leaving a local pane",
          arguments: [false, true])
    func unavailableSource(restored: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let app = try VaultPaneAppFixture()
            let workspace = app.workspace
            let catalog = SurfaceCatalog.shared
            let source = try #require(workspace.focusedPanelId)
            let machine = SurfaceMachineID.cloud("unavailable-13304-\(UUID())")
            let resource = SurfaceResourceID(machine: machine, kind: .terminal, key: "source")
            if restored {
                catalog.restore([SurfaceProjectionRecord(
                    panelID: source, resource: resource, remoteWorkspaceID: "saved-workspace", remoteTabID: "saved-tab"
                )], workspaceID: workspace.id)
            } else {
                catalog.record(SurfaceProjection(
                    resource: resource, workspaceID: workspace.id, panelID: source,
                    remoteWorkspaceID: "saved-workspace", remoteTabID: "saved-tab"
                ))
            }
            defer {
                catalog.endProjections(panelID: source, reason: .replaced)
                app.tearDown()
            }
            let before = Set(workspace.panels.keys)
            try drag(source, in: workspace, direction: "down")
            #expect(Set(workspace.panels.keys) == before)
            #expect(workspace.bonsplitController.allPaneIds.count == 1)
            #expect(workspace.cloudPaneCreationFailureStore.failure?.machine == machine)
            #expect(workspace.cloudPaneCreationFailureStore.failure?.sourcePanelID == source)
            #expect(workspace.focusedPanelId == source)
        }
    }

    @Test("Dragging a pending Cloud terminal waits for its own remote tab")
    func pendingSource() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let app = try VaultPaneAppFixture()
            let provider = CloudTerminalPlacementTestProvider()
            let workspace = app.workspace
            let source = try installSource(in: workspace, provider: provider)
            defer { tearDown(app, provider: provider) }
            #expect(workspace.newTerminalSplitOutcome(from: source, orientation: .horizontal).isAccepted)
            let parent = try #require(workspace.focusedPanelId)
            try drag(parent, in: workspace, direction: "up")
            #expect(workspace.cloudPendingCreations.count == 2)
            #expect(workspace.panels.count == 3)
            try await settled { provider.requestedWorkspaces.count == 1 }
            provider.release.resolve(true)
            try await settled { !workspace.cloudPaneCreationFailureStore.hasActiveRequests }
            #expect(provider.layoutSources.map(\.tabID) == ["tab-source", "tab-created-0"])
            #expect(provider.layoutSources.map(\.direction) == [.right, .down])
            #expect(provider.materialized.count == 2)
            #expect(workspace.focusedPanelId == parent)
            #expect(provider.materialized.allSatisfy { $0.remoteWorkspaceID == provider.remote.id })
        }
    }

    @Test("Managed-Cloud remote ownership routes even without a catalog projection")
    func legacyManagedCloudOwnership() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let app = try VaultPaneAppFixture()
            let provider = CloudTerminalPlacementTestProvider()
            let workspace = app.workspace
            let source = try #require(workspace.focusedPanelId)
            let catalog = SurfaceCatalog.shared
            catalog.register(provider)
            workspace.remoteConfiguration = WorkspaceRemoteConfiguration(
                destination: "root@cloud", port: nil, identityFile: nil, sshOptions: [],
                localProxyPort: nil, relayPort: nil, relayID: nil, relayToken: nil,
                localSocketPath: nil, managedCloudVMID: provider.machine.rawValue,
                terminalStartupCommand: nil
            )
            workspace.cloudVMBinding = WorkspaceCloudVMBinding(
                vmID: provider.machine.rawValue, isBase: false, remoteWorkspaceID: provider.remote.id
            )
            workspace.activeRemoteTerminalSurfaceIds.insert(source)
            defer { tearDown(app, provider: provider) }

            try drag(source, in: workspace, direction: "right")

            #expect(workspace.cloudPendingCreations.count == 1)
            #expect(workspace.machineOwningSurface(source) == provider.machine)
            try await settled { provider.requestedWorkspaces.count == 1 }
            #expect(provider.requestedWorkspaces == [provider.remote.id])
            provider.release.resolve(true)
            try await settled { !workspace.cloudPaneCreationFailureStore.hasActiveRequests }
            #expect(provider.materialized.count == 1)
        }
    }

    @Test("Cloud drag failures keep provider details and identifiers out of user copy")
    func cloudFailureTextIsSanitized() {
        let failure = CloudPaneCreationFailure(
            machine: .cloud("secret-machine"),
            error: CmuxTuiSurfaceProvider.ProviderError.remoteWorkspaceNotFound("secret-workspace")
        )
        #expect(!failure.errorText.contains("secret-workspace"))
        #expect(!failure.errorText.contains("cmux-tui"))
        #expect(!failure.copyableText.contains("secret-machine"))
        #expect(!failure.copyableText.contains("secret-workspace"))
    }

    @Test("Moving one of multiple Cloud tabs does not create an extra terminal")
    func populatedSourcePane() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let app = try VaultPaneAppFixture()
            let workspace = app.workspace
            let pane = try #require(workspace.bonsplitController.focusedPaneId)
            _ = try #require(workspace.newTerminalSurface(inPane: pane, focus: false))
            let provider = CloudTerminalPlacementTestProvider()
            let source = try installSource(in: workspace, provider: provider)
            defer { tearDown(app, provider: provider) }
            let before = Set(workspace.panels.keys)
            try drag(source, in: workspace, direction: "left")
            #expect(Set(workspace.panels.keys) == before)
            #expect(workspace.bonsplitController.allPaneIds.count == 2)
            #expect(workspace.cloudPendingCreations.isEmpty)
            #expect(provider.requestedWorkspaces.isEmpty)
        }
    }

    @Test("Local one-tab edge drags keep their local replacement and focus", arguments: ["left", "right", "up", "down"])
    func localDrag(direction: String) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let app = try VaultPaneAppFixture()
            defer { app.tearDown() }
            let workspace = app.workspace
            let source = try #require(workspace.focusedPanelId)
            let sourcePane = try #require(workspace.paneId(forPanelId: source))
            let before = Set(workspace.panels.keys)
            try drag(source, in: workspace, direction: direction)
            let added = Set(workspace.panels.keys).subtracting(before)
            try #require(added.count == 1)
            let replacement = try #require(added.first)
            #expect(workspace.machineOwningSurface(replacement) == .local)
            #expect(workspace.terminalPanel(for: replacement)?.surface.ioMode == .exec)
            #expect(workspace.paneId(forPanelId: replacement) == sourcePane)
            #expect(workspace.focusedPanelId == source)
            #expect(workspace.cloudPendingCreations.isEmpty)
        }
    }

    private func installSource(in workspace: Workspace, provider: CloudTerminalPlacementTestProvider,
                               remoteTabID: String? = "tab-source") throws -> UUID {
        let source = try #require(workspace.focusedPanelId)
        let catalog = SurfaceCatalog.shared
        catalog.register(provider)
        let resource = provider.resource(key: "source")
        catalog.upsert(resource, from: provider)
        catalog.record(SurfaceProjection(
            resource: resource.id, workspaceID: workspace.id, panelID: source,
            remoteWorkspaceID: provider.remote.id, remoteTabID: remoteTabID
        ))
        workspace.cloudVMBinding = WorkspaceCloudVMBinding(
            vmID: provider.machine.rawValue, isBase: false, remoteWorkspaceID: provider.remote.id
        )
        return source
    }

    private func drag(_ source: UUID, in workspace: Workspace, direction: String, entrypoint: String = "bonsplit") throws {
        let pane = try #require(workspace.paneId(forPanelId: source))
        let tab = try #require(workspace.surfaceIdFromPanelId(source))
        let horizontal = direction == "left" || direction == "right"
        let first = direction == "left" || direction == "up"
        if entrypoint == "portal" {
            let zone: DropZone = horizontal ? (first ? .left : .right) : (first ? .top : .bottom)
            #expect(workspace.performPortalSurfaceDrop(tabId: tab.uuid, sourcePaneId: pane.id, targetPane: pane, zone: zone))
        } else {
            _ = try #require(workspace.bonsplitController.splitPane(
                pane, orientation: horizontal ? .horizontal : .vertical, movingTab: tab, insertFirst: first
            ))
        }
    }

    private func tearDown(_ app: VaultPaneAppFixture, provider: CloudTerminalPlacementTestProvider) {
        app.workspace.cloudPaneCreationFailureStore.cancelAll()
        provider.release.resolve(true)
        SurfaceCatalog.shared.unregister(machine: provider.machine)
        app.tearDown()
    }

    /// The provider barrier establishes ordering; this deadline only bounds a failed test.
    private func settled(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition())
    }
}
