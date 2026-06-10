import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Remote surface tracking, auth-ready reconnect, and PTY session ID tracking
extension WorkspaceRemoteConnectionTests {
    @MainActor
    func testRemoteTerminalSurfaceLookupTracksOnlyActiveSSHSurfaces() throws {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64007,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )

        workspace.configureRemoteConnection(config, autoConnect: false)

        let panelID = try XCTUnwrap(workspace.focusedTerminalPanel?.id)
        XCTAssertTrue(workspace.isRemoteTerminalSurface(panelID))

        workspace.markRemoteTerminalSessionEnded(surfaceId: panelID, relayPort: 64007)
        XCTAssertFalse(workspace.isRemoteTerminalSurface(panelID))
    }

    @MainActor
    func testForegroundSSHAuthReadyBeforeRemoteConfigureStartsDeferredConnect() {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64029,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini",
            foregroundAuthToken: "token-a"
        )

        workspace.notifyRemoteForegroundAuthenticationReady(token: "token-a")
        workspace.configureRemoteConnection(config, autoConnect: false)

        XCTAssertEqual(workspace.remoteConnectionState, .connecting)
        workspace.disconnectRemoteConnection(clearConfiguration: true)
    }

    @MainActor
    func testForegroundSSHAuthReadyReconnectsConfiguredDisconnectedRemoteWorkspace() {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64030,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini",
            foregroundAuthToken: "token-a"
        )

        workspace.configureRemoteConnection(config, autoConnect: false)
        XCTAssertEqual(workspace.remoteConnectionState, .disconnected)

        workspace.notifyRemoteForegroundAuthenticationReady(token: "token-a")

        XCTAssertEqual(workspace.remoteConnectionState, .connecting)
        workspace.disconnectRemoteConnection(clearConfiguration: true)
    }

    @MainActor
    func testForegroundSSHAuthReadyBufferedTokenDoesNotReconnectDifferentConfiguration() {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64031,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini",
            foregroundAuthToken: "token-b"
        )

        workspace.notifyRemoteForegroundAuthenticationReady(token: "token-a")
        workspace.configureRemoteConnection(config, autoConnect: false)

        XCTAssertEqual(workspace.remoteConnectionState, .disconnected)
    }

    @MainActor
    func testRemoteReconnectingStateIsExposedInStatusPayload() {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64033,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )

        workspace.configureRemoteConnection(config, autoConnect: false)
        workspace.applyRemoteConnectionStateUpdate(
            .reconnecting,
            detail: "Reconnecting to cmux-macmini",
            target: "cmux-macmini"
        )

        XCTAssertEqual(workspace.remoteConnectionState, .reconnecting)
        XCTAssertEqual(workspace.remoteStatusPayload()["state"] as? String, "reconnecting")
    }

    @MainActor
    func testForegroundSSHAuthReadyIgnoresMismatchedConfiguredToken() {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64032,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini",
            foregroundAuthToken: "token-a"
        )

        workspace.configureRemoteConnection(config, autoConnect: false)
        workspace.notifyRemoteForegroundAuthenticationReady(token: "token-b")

        XCTAssertEqual(workspace.remoteConnectionState, .disconnected)
    }

    @MainActor
    func testDetachAttachPreservesRemoteTerminalSurfaceTracking() throws {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64007,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )

        workspace.configureRemoteConnection(config, autoConnect: false)

        let originalPanelID = try XCTUnwrap(workspace.focusedTerminalPanel?.id)
        let originalPaneID = try XCTUnwrap(workspace.paneId(forPanelId: originalPanelID))
        let movedPanel = try XCTUnwrap(
            workspace.newTerminalSplit(from: originalPanelID, orientation: .horizontal)
        )

        XCTAssertTrue(workspace.isRemoteTerminalSurface(originalPanelID))
        XCTAssertTrue(workspace.isRemoteTerminalSurface(movedPanel.id))

        let detached = try XCTUnwrap(workspace.detachSurface(panelId: movedPanel.id))
        XCTAssertTrue(detached.isRemoteTerminal)
        XCTAssertEqual(detached.remoteRelayPort, config.relayPort)

        let restoredPanelID = workspace.attachDetachedSurface(
            detached,
            inPane: originalPaneID,
            focus: false
        )

        XCTAssertEqual(restoredPanelID, movedPanel.id)
        XCTAssertTrue(workspace.isRemoteTerminalSurface(movedPanel.id))
    }

    @MainActor
    func testDetachAttachPreservesPersistentPTYSessionIDAcrossWorkspaces() throws {
        let source = Workspace()
        let destination = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64008,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh-pty-attach",
            preserveAfterTerminalExit: true
        )
        source.configureRemoteConnection(config, autoConnect: false)
        destination.configureRemoteConnection(config, autoConnect: false)

        let sourcePanelID = try XCTUnwrap(source.focusedTerminalPanel?.id)
        let destinationPaneID = try XCTUnwrap(destination.bonsplitController.allPaneIds.first)
        let sessionID = "ssh-source-session"
        let movedPanel = try XCTUnwrap(
            source.newTerminalSplit(
                from: sourcePanelID,
                orientation: .horizontal,
                remotePTYSessionID: sessionID
            )
        )

        let detached = try XCTUnwrap(source.detachSurface(panelId: movedPanel.id))
        XCTAssertEqual(detached.remotePTYSessionID, sessionID)

        let restoredPanelID = destination.attachDetachedSurface(
            detached,
            inPane: destinationPaneID,
            focus: false
        )

        XCTAssertEqual(restoredPanelID, movedPanel.id)
        XCTAssertTrue(destination.isRemoteTerminalSurface(movedPanel.id))
        let snapshot = destination.sessionSnapshot(includeScrollback: false)
        XCTAssertEqual(
            snapshot.panels.first { $0.id == movedPanel.id }?.terminal?.remotePTYSessionID,
            sessionID
        )
    }

    @MainActor
    func testDetachAttachDoesNotAdoptPersistentPTYSessionIDAcrossNilRelayWorkspaces() throws {
        let source = Workspace()
        let destination = Workspace()
        let sourceConfig = WorkspaceRemoteConfiguration(
            destination: "source-host",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil,
            preserveAfterTerminalExit: true
        )
        let destinationConfig = WorkspaceRemoteConfiguration(
            destination: "destination-host",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil,
            preserveAfterTerminalExit: true
        )
        source.configureRemoteConnection(sourceConfig, autoConnect: false)
        destination.configureRemoteConnection(destinationConfig, autoConnect: false)

        let initialSourcePanelID = try XCTUnwrap(source.focusedTerminalPanel?.id)
        let sourcePaneID = try XCTUnwrap(source.bonsplitController.allPaneIds.first)
        let destinationPaneID = try XCTUnwrap(destination.bonsplitController.allPaneIds.first)
        let sessionID = "source-only-pty-session"
        let movedPanel = try XCTUnwrap(
            source.newTerminalSurface(
                inPane: sourcePaneID,
                focus: true,
                initialCommand: "cmux ssh-pty-attach",
                remotePTYSessionID: sessionID
            )
        )
        XCTAssertTrue(source.closePanel(initialSourcePanelID, force: true))
        XCTAssertTrue(source.isRemoteTerminalSurface(movedPanel.id))

        let detached = try XCTUnwrap(source.detachSurface(panelId: movedPanel.id))
        XCTAssertNil(detached.remoteRelayPort)
        XCTAssertEqual(detached.remotePTYSessionID, sessionID)
        XCTAssertEqual(detached.remoteCleanupConfiguration?.destination, "source-host")

        let restoredPanelID = destination.attachDetachedSurface(
            detached,
            inPane: destinationPaneID,
            focus: false
        )

        XCTAssertEqual(restoredPanelID, movedPanel.id)
        XCTAssertFalse(destination.isRemoteTerminalSurface(movedPanel.id))
        XCTAssertEqual(
            destination.transferredRemoteCleanupConfigurationsByPanelId[movedPanel.id]?.destination,
            "source-host"
        )
        let snapshot = destination.sessionSnapshot(includeScrollback: false)
        XCTAssertNil(snapshot.panels.first { $0.id == movedPanel.id }?.terminal?.remotePTYSessionID)
    }

    @MainActor
    func testExplicitRemotePTYSessionSurfaceTracksRemoteTerminalWithoutDefaultStartup() throws {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64009,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: nil,
            preserveAfterTerminalExit: true
        )
        workspace.configureRemoteConnection(config, autoConnect: false)

        let paneID = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let sessionID = "explicit-surface-session"
        let panel = try XCTUnwrap(
            workspace.newTerminalSurface(
                inPane: paneID,
                focus: false,
                initialCommand: "cmux ssh-pty-attach",
                remotePTYSessionID: sessionID
            )
        )

        XCTAssertTrue(workspace.isRemoteTerminalSurface(panel.id))
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 1)
        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        XCTAssertEqual(
            snapshot.panels.first { $0.id == panel.id }?.terminal?.remotePTYSessionID,
            sessionID
        )

        let outcome = workspace.markRemotePTYAttachEnded(surfaceId: panel.id, sessionID: sessionID)
        XCTAssertTrue(outcome.clearedRemotePTYSession)
        XCTAssertTrue(outcome.untrackedRemoteTerminal)
        XCTAssertFalse(workspace.isRemoteTerminalSurface(panel.id))
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 0)
    }

    @MainActor
    func testRemoteDisconnectClearsExplicitRemotePTYSessionIDBeforeReseed() throws {
        let workspace = Workspace()
        let explicitSessionConfig = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64011,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: nil,
            preserveAfterTerminalExit: true
        )
        workspace.configureRemoteConnection(explicitSessionConfig, autoConnect: false)

        let initialPanelID = try XCTUnwrap(workspace.focusedTerminalPanel?.id)
        let paneID = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let panel = try XCTUnwrap(
            workspace.newTerminalSurface(
                inPane: paneID,
                focus: true,
                initialCommand: "cmux ssh-pty-attach",
                remotePTYSessionID: "old-explicit-session"
            )
        )
        XCTAssertTrue(workspace.closePanel(initialPanelID, force: true))
        XCTAssertEqual(workspace.panels.count, 1)
        XCTAssertTrue(workspace.remotePTYSessionIDMatches(panelId: panel.id, sessionID: "old-explicit-session"))

        workspace.disconnectRemoteConnection(clearConfiguration: true)

        let reseededConfig = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64012,
            relayID: String(repeating: "c", count: 16),
            relayToken: String(repeating: "d", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh-pty-attach",
            preserveAfterTerminalExit: true
        )
        workspace.configureRemoteConnection(reseededConfig, autoConnect: false)

        let defaultSessionID = Workspace.defaultSSHPTYSessionID(workspaceId: workspace.id, panelId: panel.id)
        XCTAssertTrue(workspace.remotePTYSessionIDMatches(panelId: panel.id, sessionID: defaultSessionID))
        let outcome = workspace.markRemotePTYAttachEnded(surfaceId: panel.id, sessionID: defaultSessionID)
        XCTAssertTrue(outcome.clearedRemotePTYSession)
        XCTAssertTrue(outcome.untrackedRemoteTerminal)
    }

    @MainActor
    func testRemoteReconfigureClearsExplicitRemotePTYSessionIDForTrackedSurface() throws {
        let workspace = Workspace()
        let originalConfig = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64013,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: nil,
            preserveAfterTerminalExit: true
        )
        workspace.configureRemoteConnection(originalConfig, autoConnect: false)

        let paneID = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let panel = try XCTUnwrap(
            workspace.newTerminalSurface(
                inPane: paneID,
                focus: true,
                initialCommand: "cmux ssh-pty-attach",
                remotePTYSessionID: "old-explicit-session"
            )
        )
        XCTAssertTrue(workspace.remotePTYSessionIDMatches(panelId: panel.id, sessionID: "old-explicit-session"))

        let replacementConfig = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 2222,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64014,
            relayID: String(repeating: "c", count: 16),
            relayToken: String(repeating: "d", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh-pty-attach",
            preserveAfterTerminalExit: true
        )
        workspace.configureRemoteConnection(replacementConfig, autoConnect: false)

        let defaultSessionID = Workspace.defaultSSHPTYSessionID(workspaceId: workspace.id, panelId: panel.id)
        XCTAssertTrue(workspace.remotePTYSessionIDMatches(panelId: panel.id, sessionID: defaultSessionID))
    }

    @MainActor
    func testExplicitRemotePTYSessionSplitTracksRemoteTerminalWithoutDefaultStartup() throws {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64010,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: nil,
            preserveAfterTerminalExit: true
        )
        workspace.configureRemoteConnection(config, autoConnect: false)

        let sourcePanelID = try XCTUnwrap(workspace.focusedTerminalPanel?.id)
        let sessionID = "explicit-split-session"
        let panel = try XCTUnwrap(
            workspace.newTerminalSplit(
                from: sourcePanelID,
                orientation: .horizontal,
                initialCommand: "cmux ssh-pty-attach",
                remotePTYSessionID: sessionID
            )
        )

        XCTAssertTrue(workspace.isRemoteTerminalSurface(panel.id))
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 1)
        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        XCTAssertEqual(
            snapshot.panels.first { $0.id == panel.id }?.terminal?.remotePTYSessionID,
            sessionID
        )
    }

    @MainActor
    func testPersistentRemoteTerminalSeedsDefaultPTYSessionIDForSnapshot() throws {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64015,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh-pty-attach",
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: "ssh-seeded-default"
        )
        workspace.configureRemoteConnection(config, autoConnect: false)

        let panelID = try XCTUnwrap(workspace.focusedTerminalPanel?.id)
        let expectedSessionID = Workspace.defaultSSHPTYSessionID(workspaceId: workspace.id, panelId: panelID)

        XCTAssertTrue(workspace.remotePTYSessionIDMatches(panelId: panelID, sessionID: expectedSessionID))
        XCTAssertEqual(
            workspace.sessionSnapshot(includeScrollback: false)
                .panels.first { $0.id == panelID }?.terminal?.remotePTYSessionID,
            expectedSessionID
        )
    }

    @MainActor
    func testDetachAttachPreservesSurfaceTTYMetadata() throws {
        let source = Workspace()
        let destination = Workspace()

        let panelID = try XCTUnwrap(source.focusedTerminalPanel?.id)
        let sourcePaneID = try XCTUnwrap(source.paneId(forPanelId: panelID))
        let destinationPaneID = try XCTUnwrap(destination.bonsplitController.allPaneIds.first)
        source.surfaceTTYNames[panelID] = "/dev/ttys004"

        let detached = try XCTUnwrap(source.detachSurface(panelId: panelID))
        XCTAssertEqual(source.surfaceTTYNames[panelID], nil)

        let restoredPanelID = destination.attachDetachedSurface(
            detached,
            inPane: destinationPaneID,
            focus: false
        )

        XCTAssertEqual(restoredPanelID, panelID)
        XCTAssertEqual(destination.surfaceTTYNames[panelID], "/dev/ttys004")
        XCTAssertEqual(source.bonsplitController.tabs(inPane: sourcePaneID).count, 0)
    }

}
