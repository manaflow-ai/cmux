import CmuxCore
import XCTest
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class WorkspaceRemoteBadgeTruthTests: XCTestCase {
    @MainActor
    func testPersistentPTYDaemonTransportErrorPropagatesAsError() {
        let workspace = Workspace()
        let config = remoteConfiguration(preserveAfterTerminalExit: true)
        workspace.configureRemoteConnection(config, autoConnect: false)

        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 1)

        let proxyError = "Remote proxy to host unavailable: Remote daemon transport failed: daemon transport keepalive timed out"
        workspace.applyRemoteConnectionStateUpdate(.error, detail: proxyError, target: "host")

        XCTAssertEqual(workspace.remoteConnectionState, .error)
        XCTAssertEqual(workspace.remoteConnectionDetail, proxyError)
        XCTAssertEqual(workspace.remoteStatusPayload()["connected"] as? Bool, false)
    }

    @MainActor
    func testUnconfirmedLegacySSHProxyOnlyErrorDoesNotClaimConnectedState() {
        let workspace = Workspace()
        let config = remoteConfiguration(preserveAfterTerminalExit: false)
        workspace.configureRemoteConnection(config, autoConnect: false)

        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 1)

        let proxyError = "Remote proxy to host unavailable: Remote daemon transport failed: daemon transport keepalive timed out"
        workspace.applyRemoteConnectionStateUpdate(.error, detail: proxyError, target: "host")

        XCTAssertEqual(workspace.remoteConnectionState, .error)
        XCTAssertEqual(workspace.remoteConnectionDetail, proxyError)
        XCTAssertEqual(workspace.remoteStatusPayload()["connected"] as? Bool, false)
    }

    @MainActor
    func testConfirmedLegacySSHTerminalOwnsPresentationUntilSessionEnds() throws {
        let workspace = Workspace()
        let config = remoteConfiguration(preserveAfterTerminalExit: false)
        workspace.configureRemoteConnection(config, autoConnect: false)
        let surfaceId = try seededTerminalSurfaceID(in: workspace)

        workspace.applyRemoteConnectionStateUpdate(
            .reconnecting,
            detail: "Reconnecting to host",
            target: "host"
        )
        XCTAssertEqual(workspace.remoteConnectionState, .reconnecting)

        XCTAssertTrue(
            workspace.markRemoteTerminalSessionConnected(
                surfaceId: surfaceId,
                relayPort: 64007
            )
        )
        XCTAssertEqual(workspace.remoteConnectionState, .connected)

        workspace.trackRemoteTerminalSurface(surfaceId)
        workspace.applyRemoteConnectionStateUpdate(
            .reconnecting,
            detail: "Auxiliary daemon reconnecting",
            target: "host"
        )
        XCTAssertEqual(workspace.remoteConnectionState, .connected)

        let proxyError = "Remote proxy to host unavailable: Remote daemon transport failed"
        workspace.applyRemoteConnectionStateUpdate(.error, detail: proxyError, target: "host")
        XCTAssertEqual(workspace.remoteConnectionState, .connected)
        XCTAssertEqual(workspace.remoteConnectionDetail, proxyError)

        workspace.markRemoteTerminalSessionEnded(surfaceId: surfaceId, relayPort: 64007)
        XCTAssertEqual(workspace.remoteConnectionState, .disconnected)
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 0)
    }

    @MainActor
    func testEndingOnlyConnectedTerminalRevealsUnderlyingProxyFailure() throws {
        let workspace = Workspace()
        let configuration = remoteConfiguration(preserveAfterTerminalExit: false)
        workspace.configureRemoteConnection(configuration, autoConnect: false)
        let connectedSurfaceID = try seededTerminalSurfaceID(in: workspace)
        let connectedTerminal = try XCTUnwrap(
            workspace.panels[connectedSurfaceID] as? TerminalPanel
        )
        let launchingTerminal = try XCTUnwrap(
            workspace.newTerminalSplit(
                from: connectedSurfaceID,
                orientation: .horizontal,
                focus: false
            )
        )

        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 2)
        XCTAssertTrue(
            workspace.markRemoteTerminalSessionConnected(
                surfaceId: connectedSurfaceID,
                authority: .relayPort(64007),
                terminalLifecycleID: connectedTerminal.surface.terminalLifecycleId
            )
        )
        let proxyError =
            "Remote proxy to host unavailable: Remote daemon transport failed"
        workspace.applyRemoteConnectionStateUpdate(
            .error,
            detail: proxyError,
            target: "host"
        )
        XCTAssertEqual(workspace.remoteConnectionState, .connected)

        XCTAssertTrue(
            workspace.markRemoteTerminalSessionEnded(
                surfaceId: connectedSurfaceID,
                relayPort: 64007,
                terminalLifecycleID: connectedTerminal.surface.terminalLifecycleId
            )
        )

        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 1)
        XCTAssertTrue(workspace.isRemoteTerminalSurface(launchingTerminal.id))
        XCTAssertFalse(workspace.hasAuthoritativelyConnectedRemoteTerminal)
        XCTAssertEqual(workspace.remoteConnectionState, .error)
        XCTAssertEqual(workspace.remoteConnectionDetail, proxyError)
    }

    @MainActor
    func testEndingOnlyConnectedDockTerminalRevealsUnderlyingProxyFailure() throws {
        let workspace = Workspace()
        let configuration = remoteConfiguration(preserveAfterTerminalExit: false)
        workspace.configureRemoteConnection(configuration, autoConnect: false)
        let connectedSurfaceID = try seededTerminalSurfaceID(in: workspace)
        let connectedTerminal = try XCTUnwrap(
            workspace.panels[connectedSurfaceID] as? TerminalPanel
        )
        let launchingTerminal = try XCTUnwrap(
            workspace.newTerminalSplit(
                from: connectedSurfaceID,
                orientation: .horizontal,
                focus: false
            )
        )
        let dock = DockSplitStore(
            workspaceId: UUID(),
            scope: .global,
            baseDirectoryProvider: { nil }
        )
        defer { dock.closeAllPanels() }
        let dockPane = try XCTUnwrap(dock.bonsplitController.allPaneIds.first)
        let detached = try XCTUnwrap(
            workspace.detachSurface(panelId: connectedSurfaceID)
        )
        XCTAssertNotNil(
            dock.attachDetachedSurface(detached, inPane: dockPane, focus: false)
        )

        XCTAssertTrue(
            workspace.markDockRemoteTerminalSessionConnected(
                surfaceId: connectedSurfaceID,
                authority: .relayPort(64007),
                terminalLifecycleID: connectedTerminal.surface.terminalLifecycleId,
                dock: dock
            )
        )
        let proxyError =
            "Remote proxy to host unavailable: Remote daemon transport failed"
        workspace.applyRemoteConnectionStateUpdate(
            .error,
            detail: proxyError,
            target: "host",
            externalRemoteTerminalDocks: [dock]
        )
        XCTAssertEqual(workspace.remoteConnectionState, .connected)

        XCTAssertTrue(
            workspace.markDockRemoteTerminalSessionEnded(
                surfaceId: connectedSurfaceID,
                authority: .relayPort(64007),
                relayPort: 64007,
                terminalLifecycleID: connectedTerminal.surface.terminalLifecycleId,
                dock: dock
            )
        )

        XCTAssertTrue(workspace.isRemoteTerminalSurface(launchingTerminal.id))
        XCTAssertFalse(
            workspace.hasAuthoritativelyConnectedRemoteTerminal(in: [dock])
        )
        XCTAssertEqual(workspace.remoteConnectionState, .error)
        XCTAssertEqual(workspace.remoteConnectionDetail, proxyError)
    }

    @MainActor
    func testEndingDockTerminalKeepsConnectedSiblingAuthoritative() throws {
        let workspace = Workspace()
        let configuration = remoteConfiguration(preserveAfterTerminalExit: false)
        workspace.configureRemoteConnection(configuration, autoConnect: false)
        let firstSurfaceID = try seededTerminalSurfaceID(in: workspace)
        let firstTerminal = try XCTUnwrap(
            workspace.panels[firstSurfaceID] as? TerminalPanel
        )
        let secondTerminal = try XCTUnwrap(
            workspace.newTerminalSplit(
                from: firstSurfaceID,
                orientation: .horizontal,
                focus: false
            )
        )
        let dock = DockSplitStore(
            workspaceId: UUID(),
            scope: .global,
            baseDirectoryProvider: { nil }
        )
        defer { dock.closeAllPanels() }
        let dockPane = try XCTUnwrap(dock.bonsplitController.allPaneIds.first)
        for surfaceID in [firstSurfaceID, secondTerminal.id] {
            let detached = try XCTUnwrap(
                workspace.detachSurface(panelId: surfaceID)
            )
            XCTAssertNotNil(
                dock.attachDetachedSurface(
                    detached,
                    inPane: dockPane,
                    focus: false
                )
            )
        }

        XCTAssertTrue(
            workspace.markDockRemoteTerminalSessionConnected(
                surfaceId: firstSurfaceID,
                authority: .relayPort(64007),
                terminalLifecycleID: firstTerminal.surface.terminalLifecycleId,
                dock: dock
            )
        )
        XCTAssertTrue(
            workspace.markDockRemoteTerminalSessionConnected(
                surfaceId: secondTerminal.id,
                authority: .relayPort(64007),
                terminalLifecycleID: secondTerminal.surface.terminalLifecycleId,
                dock: dock
            )
        )
        workspace.applyRemoteConnectionStateUpdate(
            .error,
            detail: "Remote proxy to host unavailable: Remote daemon transport failed",
            target: "host",
            externalRemoteTerminalDocks: [dock]
        )
        XCTAssertEqual(workspace.remoteConnectionState, .connected)

        XCTAssertTrue(
            workspace.markDockRemoteTerminalSessionEnded(
                surfaceId: firstSurfaceID,
                authority: .relayPort(64007),
                relayPort: 64007,
                terminalLifecycleID: firstTerminal.surface.terminalLifecycleId,
                dock: dock
            )
        )

        XCTAssertTrue(
            workspace.hasAuthoritativelyConnectedRemoteTerminal(in: [dock])
        )
        XCTAssertEqual(
            dock.detachedSurfaceTransfersByPanelId[secondTerminal.id]?
                .remoteTerminalSessionPhase,
            .connected
        )
        XCTAssertEqual(workspace.remoteConnectionState, .connected)
    }

    @MainActor
    func testClosingEndedDockTerminalReleasesSourceLifecycleGeneration() throws {
        let workspace = Workspace()
        workspace.configureRemoteConnection(
            remoteConfiguration(preserveAfterTerminalExit: false),
            autoConnect: false
        )
        let surfaceID = try seededTerminalSurfaceID(in: workspace)
        let terminal = try XCTUnwrap(
            workspace.panels[surfaceID] as? TerminalPanel
        )
        let lifecycleID = terminal.surface.terminalLifecycleId
        let dock = DockSplitStore(
            workspaceId: UUID(),
            scope: .global,
            baseDirectoryProvider: { nil }
        )
        defer { dock.closeAllPanels() }
        let dockPane = try XCTUnwrap(dock.bonsplitController.allPaneIds.first)
        let detached = try XCTUnwrap(
            workspace.detachSurface(panelId: surfaceID)
        )
        XCTAssertNotNil(
            dock.attachDetachedSurface(detached, inPane: dockPane, focus: false)
        )

        XCTAssertTrue(
            workspace.markDockRemoteTerminalSessionConnected(
                surfaceId: surfaceID,
                authority: .relayPort(64007),
                terminalLifecycleID: lifecycleID,
                dock: dock
            )
        )
        XCTAssertTrue(
            workspace.markDockRemoteTerminalSessionEnded(
                surfaceId: surfaceID,
                authority: .relayPort(64007),
                relayPort: 64007,
                terminalLifecycleID: lifecycleID,
                dock: dock
            )
        )
        XCTAssertFalse(
            workspace.markDockRemoteTerminalSessionConnected(
                surfaceId: surfaceID,
                authority: .relayPort(64007),
                terminalLifecycleID: lifecycleID,
                dock: dock
            )
        )

        let dockTabID = try XCTUnwrap(dock.surfaceId(forPanelId: surfaceID))
        XCTAssertTrue(dock.bonsplitController.closeTab(dockTabID))
        dock.reconcilePanels()

        XCTAssertNil(dock.panels[surfaceID])
        XCTAssertNil(dock.detachedSurfaceTransfersByPanelId[surfaceID])
        XCTAssertNil(
            workspace.endedRemoteTerminalLifecycleIDsBySurfaceId[surfaceID],
            "A Dock-owned ended generation must retire with its permanent panel"
        )
    }

    @MainActor
    func testClosingEndedTerminalRetiresItsLifecycleTombstone() throws {
        let workspace = Workspace()
        workspace.configureRemoteConnection(
            remoteConfiguration(preserveAfterTerminalExit: false),
            autoConnect: false
        )
        let endedSurfaceID = try seededTerminalSurfaceID(in: workspace)
        let endedTerminal = try XCTUnwrap(
            workspace.panels[endedSurfaceID] as? TerminalPanel
        )
        let siblingTerminal = try XCTUnwrap(
            workspace.newTerminalSplit(
                from: endedSurfaceID,
                orientation: .horizontal,
                focus: false
            )
        )

        XCTAssertTrue(
            workspace.markRemoteTerminalSessionEnded(
                surfaceId: endedSurfaceID,
                relayPort: 64007,
                terminalLifecycleID: endedTerminal.surface.terminalLifecycleId
            )
        )
        XCTAssertEqual(
            workspace.endedRemoteTerminalLifecycleIDsBySurfaceId[endedSurfaceID],
            endedTerminal.surface.terminalLifecycleId
        )

        XCTAssertTrue(workspace.closePanel(endedSurfaceID, force: true))

        XCTAssertNil(workspace.panels[endedSurfaceID])
        XCTAssertNotNil(workspace.panels[siblingTerminal.id])
        XCTAssertNil(
            workspace.endedRemoteTerminalLifecycleIDsBySurfaceId[endedSurfaceID],
            "Permanent panel retirement must release its lifecycle tombstone"
        )
    }

    @MainActor
    func testTerminalConnectedRejectsStaleRelayGeneration() throws {
        let workspace = Workspace()
        workspace.configureRemoteConnection(
            remoteConfiguration(preserveAfterTerminalExit: false),
            autoConnect: false
        )
        let surfaceId = try seededTerminalSurfaceID(in: workspace)

        XCTAssertFalse(
            workspace.markRemoteTerminalSessionConnected(
                surfaceId: surfaceId,
                relayPort: 64008
            )
        )
        XCTAssertEqual(workspace.remoteConnectionState, .disconnected)
    }

    @MainActor
    func testReconfiguredRelayCannotReuseOldConnectedAuthority() throws {
        let workspace = Workspace()
        let firstConfiguration = remoteConfiguration(
            preserveAfterTerminalExit: false,
            relayPort: 64007
        )
        workspace.configureRemoteConnection(firstConfiguration, autoConnect: false)
        let surfaceId = try seededTerminalSurfaceID(in: workspace)
        XCTAssertTrue(
            workspace.markRemoteTerminalSessionConnected(
                surfaceId: surfaceId,
                relayPort: firstConfiguration.relayPort
            )
        )

        let replacementConfiguration = remoteConfiguration(
            preserveAfterTerminalExit: false,
            relayPort: 64008
        )
        workspace.configureRemoteConnection(replacementConfiguration, autoConnect: false)

        XCTAssertFalse(workspace.hasAuthoritativelyConnectedRemoteTerminal)
        workspace.applyRemoteConnectionStateUpdate(
            .reconnecting,
            detail: "Replacement relay reconnecting",
            target: "host"
        )
        XCTAssertEqual(workspace.remoteConnectionState, .reconnecting)
        XCTAssertFalse(
            workspace.markRemoteTerminalSessionConnected(
                surfaceId: surfaceId,
                relayPort: firstConfiguration.relayPort
            )
        )
        XCTAssertTrue(
            workspace.markRemoteTerminalSessionConnected(
                surfaceId: surfaceId,
                relayPort: replacementConfiguration.relayPort
            )
        )
    }

    @MainActor
    func testWindowDockTerminalPreservesOnlyItsSourceConfigurationPresentation() throws {
        let workspace = Workspace()
        let firstConfiguration = remoteConfiguration(
            preserveAfterTerminalExit: false,
            relayPort: 64007
        )
        workspace.configureRemoteConnection(firstConfiguration, autoConnect: false)
        let surfaceId = try seededTerminalSurfaceID(in: workspace)

        let dock = DockSplitStore(
            workspaceId: UUID(),
            scope: .global,
            baseDirectoryProvider: { nil }
        )
        defer { dock.closeAllPanels() }
        let dockPane = try XCTUnwrap(dock.bonsplitController.allPaneIds.first)
        let detached = try XCTUnwrap(workspace.detachSurface(panelId: surfaceId))
        XCTAssertNotNil(
            dock.attachDetachedSurface(detached, inPane: dockPane, focus: false)
        )

        XCTAssertTrue(
            workspace.markDockRemoteTerminalSessionConnected(
                surfaceId: surfaceId,
                authority: .relayPort(64007),
                dock: dock
            )
        )
        XCTAssertTrue(
            workspace.hasAuthoritativelyConnectedRemoteTerminal(in: [dock])
        )
        workspace.applyRemoteConnectionStateUpdate(
            .reconnecting,
            detail: "Auxiliary daemon reconnecting",
            target: "host",
            externalRemoteTerminalDocks: [dock]
        )
        XCTAssertEqual(workspace.remoteConnectionState, .connected)

        let replacementConfiguration = remoteConfiguration(
            preserveAfterTerminalExit: false,
            relayPort: 64008
        )
        workspace.configureRemoteConnection(replacementConfiguration, autoConnect: false)

        XCTAssertFalse(
            workspace.hasAuthoritativelyConnectedRemoteTerminal(in: [dock])
        )
        workspace.applyRemoteConnectionStateUpdate(
            .reconnecting,
            detail: "Replacement relay reconnecting",
            target: "host",
            externalRemoteTerminalDocks: [dock]
        )
        XCTAssertEqual(workspace.remoteConnectionState, .reconnecting)
        XCTAssertTrue(
            dock.markRemoteTerminalSessionConnected(
                panelId: surfaceId,
                authority: .relayPort(64008)
            )
        )
        XCTAssertTrue(
            workspace.hasAuthoritativelyConnectedRemoteTerminal(in: [dock])
        )
    }

    @MainActor
    func testWindowDockReadinessCannotRetargetAnotherWorkspacePresentation() throws {
        let sourceWorkspace = Workspace()
        let configuration = remoteConfiguration(
            preserveAfterTerminalExit: false,
            relayPort: 64007
        )
        sourceWorkspace.configureRemoteConnection(configuration, autoConnect: false)
        let surfaceId = try seededTerminalSurfaceID(in: sourceWorkspace)

        let dock = DockSplitStore(
            workspaceId: UUID(),
            scope: .global,
            baseDirectoryProvider: { nil }
        )
        defer { dock.closeAllPanels() }
        let dockPane = try XCTUnwrap(dock.bonsplitController.allPaneIds.first)
        let detached = try XCTUnwrap(sourceWorkspace.detachSurface(panelId: surfaceId))
        XCTAssertNotNil(
            dock.attachDetachedSurface(detached, inPane: dockPane, focus: false)
        )

        let unrelatedWorkspace = Workspace()
        unrelatedWorkspace.configureRemoteConnection(configuration, autoConnect: false)

        XCTAssertFalse(
            unrelatedWorkspace.markDockRemoteTerminalSessionConnected(
                surfaceId: surfaceId,
                authority: .relayPort(64007),
                dock: dock
            )
        )
        XCTAssertEqual(unrelatedWorkspace.remoteConnectionState, .disconnected)
        XCTAssertFalse(
            unrelatedWorkspace.hasAuthoritativelyConnectedRemoteTerminal(in: [dock])
        )
    }

    @MainActor
    func testWorkspaceDockMoveKeepsTerminalLaunchWorkspaceOwnership() throws {
        let sourceWorkspace = Workspace()
        let configuration = remoteConfiguration(
            preserveAfterTerminalExit: false,
            relayPort: 64007
        )
        sourceWorkspace.configureRemoteConnection(configuration, autoConnect: false)
        let surfaceId = try seededTerminalSurfaceID(in: sourceWorkspace)
        let terminal = try XCTUnwrap(sourceWorkspace.panels[surfaceId] as? TerminalPanel)

        let destinationWorkspace = Workspace()
        let dock = destinationWorkspace.requiredDockSplitForTesting
        defer { dock.closeAllPanels() }
        let dockPane = try XCTUnwrap(dock.bonsplitController.allPaneIds.first)
        let detached = try XCTUnwrap(sourceWorkspace.detachSurface(panelId: surfaceId))
        XCTAssertNotNil(
            dock.attachDetachedSurface(detached, inPane: dockPane, focus: false)
        )

        XCTAssertTrue(
            dock.ownsRemoteTerminalTransfer(
                panelId: surfaceId,
                presentationWorkspaceID: sourceWorkspace.id
            )
        )
        XCTAssertFalse(
            dock.ownsRemoteTerminalTransfer(
                panelId: surfaceId,
                presentationWorkspaceID: destinationWorkspace.id
            )
        )
        XCTAssertTrue(
            sourceWorkspace.markDockRemoteTerminalSessionConnected(
                surfaceId: surfaceId,
                authority: .relayPort(64007),
                terminalLifecycleID: terminal.surface.terminalLifecycleId,
                dock: dock
            )
        )
        XCTAssertTrue(
            sourceWorkspace.hasAuthoritativelyConnectedRemoteTerminal(in: [dock])
        )

        sourceWorkspace.applyRemoteConnectionStateUpdate(
            .reconnecting,
            detail: "Auxiliary daemon reconnecting",
            target: "host",
            externalRemoteTerminalDocks: [dock]
        )

        XCTAssertEqual(sourceWorkspace.remoteConnectionState, .connected)
    }

    @MainActor
    func testDockEndedGenerationRejectsLateConnectedCallback() throws {
        let workspace = Workspace()
        let configuration = remoteConfiguration(
            preserveAfterTerminalExit: false,
            relayPort: 64007
        )
        workspace.configureRemoteConnection(configuration, autoConnect: false)
        let surfaceId = try seededTerminalSurfaceID(in: workspace)
        let terminal = try XCTUnwrap(workspace.panels[surfaceId] as? TerminalPanel)
        let terminalLifecycleID = terminal.surface.terminalLifecycleId

        let dock = DockSplitStore(
            workspaceId: UUID(),
            scope: .global,
            baseDirectoryProvider: { nil }
        )
        defer { dock.closeAllPanels() }
        let dockPane = try XCTUnwrap(dock.bonsplitController.allPaneIds.first)
        let detached = try XCTUnwrap(workspace.detachSurface(panelId: surfaceId))
        XCTAssertNotNil(
            dock.attachDetachedSurface(detached, inPane: dockPane, focus: false)
        )

        XCTAssertTrue(
            dock.markRemoteTerminalSessionConnected(
                panelId: surfaceId,
                authority: .relayPort(64007),
                terminalLifecycleID: terminalLifecycleID
            )
        )
        XCTAssertTrue(
            dock.markRemoteTerminalSessionEnded(
                panelId: surfaceId,
                authority: .relayPort(64007),
                terminalLifecycleID: terminalLifecycleID
            )
        )
        XCTAssertFalse(
            dock.markRemoteTerminalSessionConnected(
                panelId: surfaceId,
                authority: .relayPort(64007),
                terminalLifecycleID: terminalLifecycleID
            )
        )
        XCTAssertEqual(
            dock.detachedSurfaceTransfersByPanelId[surfaceId]?.remoteTerminalSessionPhase,
            .ended
        )
    }

    @MainActor
    func testRemoteTerminalDockLookupIsScopedToPresentationWorkspace() throws {
        let sourceWorkspace = Workspace()
        sourceWorkspace.configureRemoteConnection(
            remoteConfiguration(preserveAfterTerminalExit: false),
            autoConnect: false
        )
        let unrelatedWorkspace = Workspace()
        unrelatedWorkspace.configureRemoteConnection(
            remoteConfiguration(preserveAfterTerminalExit: false),
            autoConnect: false
        )
        let sourceSurfaceID = try seededTerminalSurfaceID(in: sourceWorkspace)
        let unrelatedSurfaceID = try seededTerminalSurfaceID(in: unrelatedWorkspace)
        let sourceDock = DockSplitStore(
            workspaceId: UUID(),
            scope: .global,
            baseDirectoryProvider: { nil }
        )
        let unrelatedDock = DockSplitStore(
            workspaceId: UUID(),
            scope: .global,
            baseDirectoryProvider: { nil }
        )
        defer {
            sourceDock.closeAllPanels()
            unrelatedDock.closeAllPanels()
        }

        let sourceTransfer = try XCTUnwrap(
            sourceWorkspace.detachSurface(panelId: sourceSurfaceID)
        )
        let unrelatedTransfer = try XCTUnwrap(
            unrelatedWorkspace.detachSurface(panelId: unrelatedSurfaceID)
        )
        XCTAssertNotNil(sourceDock.attachDetachedSurface(
            sourceTransfer,
            inPane: try XCTUnwrap(sourceDock.bonsplitController.allPaneIds.first),
            focus: false
        ))
        XCTAssertNotNil(unrelatedDock.attachDetachedSurface(
            unrelatedTransfer,
            inPane: try XCTUnwrap(unrelatedDock.bonsplitController.allPaneIds.first),
            focus: false
        ))

        let sourceDocks = DockSplitStore.liveRemoteTerminalStores(
            presentationWorkspaceID: sourceWorkspace.id
        )
        XCTAssertEqual(sourceDocks.count, 1)
        XCTAssertTrue(sourceDocks.first === sourceDock)
        XCTAssertFalse(sourceDocks.contains { $0 === unrelatedDock })

        sourceDock.closeAllPanels()
        XCTAssertTrue(DockSplitStore.liveRemoteTerminalStores(
            presentationWorkspaceID: sourceWorkspace.id
        ).isEmpty)
    }

    @MainActor
    func testPendingEndedGenerationRejectsLateConnectedCallback() throws {
        let workspace = Workspace()
        let surfaceId = try seededTerminalSurfaceID(in: workspace)
        let terminal = try XCTUnwrap(workspace.panels[surfaceId] as? TerminalPanel)
        let terminalLifecycleID = terminal.surface.terminalLifecycleId

        XCTAssertTrue(
            workspace.markRemoteTerminalSessionConnected(
                surfaceId: surfaceId,
                authority: .relayPort(64007),
                terminalLifecycleID: terminalLifecycleID
            )
        )
        XCTAssertTrue(
            workspace.markRemoteTerminalSessionEnded(
                surfaceId: surfaceId,
                relayPort: 64007,
                terminalLifecycleID: terminalLifecycleID
            )
        )
        XCTAssertFalse(
            workspace.markRemoteTerminalSessionConnected(
                surfaceId: surfaceId,
                authority: .relayPort(64007),
                terminalLifecycleID: terminalLifecycleID
            )
        )
        XCTAssertNil(workspace.pendingRemoteTerminalConnectionsBySurfaceId[surfaceId])
        XCTAssertEqual(
            workspace.remoteTerminalSessionStatesBySurfaceId[surfaceId]?.phase,
            .ended
        )
    }

    @MainActor
    func testEndBeforeReadinessRecordsLifecycleTombstone() throws {
        let workspace = Workspace()
        let surfaceId = try seededTerminalSurfaceID(in: workspace)
        let terminal = try XCTUnwrap(workspace.panels[surfaceId] as? TerminalPanel)
        let terminalLifecycleID = terminal.surface.terminalLifecycleId

        XCTAssertTrue(
            workspace.markRemoteTerminalSessionEnded(
                surfaceId: surfaceId,
                relayPort: 64007,
                terminalLifecycleID: terminalLifecycleID
            )
        )
        XCTAssertFalse(
            workspace.markRemoteTerminalSessionConnected(
                surfaceId: surfaceId,
                authority: .relayPort(64007),
                terminalLifecycleID: terminalLifecycleID
            )
        )

        workspace.configureRemoteConnection(
            remoteConfiguration(preserveAfterTerminalExit: false),
            autoConnect: false
        )

        XCTAssertFalse(workspace.hasAuthoritativelyConnectedRemoteTerminal)
        XCTAssertEqual(workspace.remoteConnectionState, .disconnected)
    }

    @MainActor
    func testTerminalConnectedBeforeRemoteConfigurationIsAppliedAfterSeeding() throws {
        let workspace = Workspace()
        let surfaceId = try seededTerminalSurfaceID(in: workspace)

        XCTAssertTrue(
            workspace.markRemoteTerminalSessionConnected(
                surfaceId: surfaceId,
                relayPort: 64007
            )
        )
        XCTAssertFalse(workspace.hasAuthoritativelyConnectedRemoteTerminal)

        workspace.configureRemoteConnection(
            remoteConfiguration(preserveAfterTerminalExit: false),
            autoConnect: false
        )

        XCTAssertTrue(workspace.hasAuthoritativelyConnectedRemoteTerminal)
        XCTAssertEqual(workspace.remoteConnectionState, .connected)
    }

    @MainActor
    func testTerminalConnectedBeforeRemoteConfigurationRejectsStaleRelay() throws {
        let workspace = Workspace()
        let surfaceId = try seededTerminalSurfaceID(in: workspace)

        XCTAssertTrue(
            workspace.markRemoteTerminalSessionConnected(
                surfaceId: surfaceId,
                relayPort: 64008
            )
        )

        workspace.configureRemoteConnection(
            remoteConfiguration(preserveAfterTerminalExit: false),
            autoConnect: false
        )

        XCTAssertFalse(workspace.hasAuthoritativelyConnectedRemoteTerminal)
        XCTAssertEqual(workspace.remoteConnectionState, .disconnected)
    }

    @MainActor
    func testLegacySSHProxyOnlyErrorDowngradesAfterLastTerminalSessionEnds() throws {
        let workspace = Workspace()
        let config = remoteConfiguration(preserveAfterTerminalExit: false)
        workspace.configureRemoteConnection(config, autoConnect: false)

        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 1)

        try endSeededLegacyTerminalSession(in: workspace)

        let proxyError = "Remote proxy to host unavailable: Remote daemon transport failed: daemon transport keepalive timed out"
        workspace.applyRemoteConnectionStateUpdate(.error, detail: proxyError, target: "host")

        XCTAssertEqual(workspace.remoteConnectionState, .error)
        XCTAssertEqual(workspace.remoteStatusPayload()["connected"] as? Bool, false)
    }

    @MainActor
    func testProxyOnlyRetryDoesNotPinConnectedWithoutLiveTerminalSessions() throws {
        let workspace = Workspace()
        let config = remoteConfiguration(preserveAfterTerminalExit: false)
        workspace.configureRemoteConnection(config, autoConnect: false)

        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 1)

        try endSeededLegacyTerminalSession(in: workspace)

        let proxyError = "Remote proxy to host unavailable: Remote daemon transport failed: daemon transport keepalive timed out"
        workspace.applyRemoteConnectionStateUpdate(.error, detail: proxyError, target: "host")
        workspace.applyRemoteConnectionStateUpdate(.reconnecting, detail: "Reconnecting to host (retry 1)", target: "host")

        XCTAssertEqual(workspace.remoteConnectionState, .reconnecting)
    }

    private func remoteConfiguration(
        preserveAfterTerminalExit: Bool,
        relayPort: Int = 64007
    ) -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: "host",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: relayPort,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh-pty-attach",
            preserveAfterTerminalExit: preserveAfterTerminalExit
        )
    }

    @MainActor
    private func endSeededLegacyTerminalSession(in workspace: Workspace) throws {
        let surfaceId = try seededTerminalSurfaceID(in: workspace)
        workspace.markRemoteTerminalSessionEnded(surfaceId: surfaceId, relayPort: 64007)

        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 0)
        XCTAssertEqual(workspace.remoteConnectionState, .disconnected)
    }

    @MainActor
    private func seededTerminalSurfaceID(in workspace: Workspace) throws -> UUID {
        let terminalSurfaceIds = workspace.panels.compactMap { panelId, panel in
            panel is TerminalPanel ? panelId : nil
        }
        XCTAssertEqual(terminalSurfaceIds.count, 1)
        return try XCTUnwrap(terminalSurfaceIds.first)
    }
}
