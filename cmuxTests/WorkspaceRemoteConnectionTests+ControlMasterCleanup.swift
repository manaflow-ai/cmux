import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Control master cleanup on session end and workspace close
extension WorkspaceRemoteConnectionTests {
    @MainActor
    func testRemoteTerminalSessionEndRequestsControlMasterCleanupWhenWorkspaceDemotes() throws {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 2222,
            identityFile: "/Users/test/.ssh/id_ed25519",
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-%C",
                "StrictHostKeyChecking=accept-new",
            ],
            localProxyPort: nil,
            relayPort: 64012,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
        let cleanupRequested = expectation(description: "control master cleanup requested")
        var capturedArguments: [String] = []

        Workspace.runSSHControlMasterCommandOverrideForTesting = { arguments in
            capturedArguments = arguments
            cleanupRequested.fulfill()
        }
        defer { Workspace.runSSHControlMasterCommandOverrideForTesting = nil }

        workspace.configureRemoteConnection(config, autoConnect: false)

        let panelID = try XCTUnwrap(workspace.focusedTerminalPanel?.id)
        workspace.markRemoteTerminalSessionEnded(surfaceId: panelID, relayPort: 64012)

        wait(for: [cleanupRequested], timeout: 1.0)

        XCTAssertFalse(workspace.isRemoteWorkspace)
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 0)
        XCTAssertEqual(
            capturedArguments,
            [
                "-o", "BatchMode=yes",
                "-o", "ControlMaster=no",
                "-p", "2222",
                "-i", "/Users/test/.ssh/id_ed25519",
                "-o", "ControlPath=/tmp/cmux-ssh-%C",
                "-o", "StrictHostKeyChecking=accept-new",
                "-O", "exit",
                "cmux-macmini",
            ]
        )
    }

    @MainActor
    func testRemoteTerminalSessionEndPreservesPersistentPTYWorkspace() throws {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 2222,
            identityFile: "/Users/test/.ssh/id_ed25519",
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-%C",
                "StrictHostKeyChecking=accept-new",
            ],
            localProxyPort: nil,
            relayPort: 64012,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini",
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: "ssh-persist-end"
        )
        let cleanupRequested = expectation(description: "control master cleanup requested")
        cleanupRequested.isInverted = true

        Workspace.runSSHControlMasterCommandOverrideForTesting = { _ in
            cleanupRequested.fulfill()
        }
        defer { Workspace.runSSHControlMasterCommandOverrideForTesting = nil }

        workspace.configureRemoteConnection(config, autoConnect: false)

        let panelID = try XCTUnwrap(workspace.focusedTerminalPanel?.id)
        let expectedSessionID = Workspace.defaultSSHPTYSessionID(workspaceId: workspace.id, panelId: panelID)
        workspace.markRemoteTerminalSessionEnded(surfaceId: panelID, relayPort: 64012)

        wait(for: [cleanupRequested], timeout: 0.2)

        XCTAssertTrue(workspace.isRemoteWorkspace)
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 0)
        XCTAssertEqual(workspace.remoteConfiguration?.preserveAfterTerminalExit, true)
        XCTAssertEqual(workspace.remoteConfiguration?.persistentDaemonSlot, "ssh-persist-end")
        XCTAssertEqual(
            workspace.sessionSnapshot(includeScrollback: false)
                .panels.first { $0.id == panelID }?.terminal?.remotePTYSessionID,
            expectedSessionID
        )

        workspace.teardownAllPanels()
        XCTAssertTrue(workspace.panels.isEmpty)
        XCTAssertTrue(workspace.isRemoteWorkspace)
        XCTAssertEqual(workspace.remoteConfiguration?.preserveAfterTerminalExit, true)
    }

    @MainActor
    func testTeardownRemoteConnectionRequestsControlMasterCleanupWhileStillConnecting() {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-%C",
            ],
            localProxyPort: nil,
            relayPort: 64014,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
        let cleanupRequested = expectation(description: "control master cleanup requested")
        var capturedArguments: [String] = []

        Workspace.runSSHControlMasterCommandOverrideForTesting = { arguments in
            capturedArguments = arguments
            cleanupRequested.fulfill()
        }
        defer { Workspace.runSSHControlMasterCommandOverrideForTesting = nil }

        workspace.configureRemoteConnection(config, autoConnect: false)
        workspace.applyRemoteConnectionStateUpdate(
            .connecting,
            detail: "Connecting to cmux-macmini",
            target: "cmux-macmini"
        )

        workspace.teardownRemoteConnection()

        wait(for: [cleanupRequested], timeout: 1.0)

        XCTAssertFalse(workspace.isRemoteWorkspace)
        XCTAssertEqual(
            capturedArguments,
            [
                "-o", "BatchMode=yes",
                "-o", "ControlMaster=no",
                "-o", "ControlPath=/tmp/cmux-ssh-%C",
                "-O", "exit",
                "cmux-macmini",
            ]
        )
    }

    @MainActor
    func testTeardownRemoteConnectionRequestsControlMasterCleanupWithoutExplicitControlPath() {
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
            terminalStartupCommand: "ssh cmux-macmini"
        )
        let cleanupRequested = expectation(description: "control master cleanup requested")
        var capturedArguments: [String] = []

        Workspace.runSSHControlMasterCommandOverrideForTesting = { arguments in
            capturedArguments = arguments
            cleanupRequested.fulfill()
        }
        defer { Workspace.runSSHControlMasterCommandOverrideForTesting = nil }

        workspace.configureRemoteConnection(config, autoConnect: false)
        workspace.applyRemoteConnectionStateUpdate(
            .connecting,
            detail: "Connecting to cmux-macmini",
            target: "cmux-macmini"
        )

        workspace.teardownRemoteConnection()

        wait(for: [cleanupRequested], timeout: 1.0)

        XCTAssertFalse(workspace.isRemoteWorkspace)
        XCTAssertEqual(
            capturedArguments,
            [
                "-o", "BatchMode=yes",
                "-o", "ControlMaster=no",
                "-O", "exit",
                "cmux-macmini",
            ]
        )
    }

    @MainActor
    func testClosingRemoteWorkspaceRequestsControlMasterCleanup() throws {
        let manager = TabManager()
        let remainingWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let remoteWorkspace = manager.addWorkspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 2222,
            identityFile: "/Users/test/.ssh/id_ed25519",
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-%C",
                "StrictHostKeyChecking=accept-new",
            ],
            localProxyPort: nil,
            relayPort: 64018,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
        let cleanupRequested = expectation(description: "control master cleanup requested")
        var capturedArguments: [String] = []

        Workspace.runSSHControlMasterCommandOverrideForTesting = { arguments in
            capturedArguments = arguments
            cleanupRequested.fulfill()
        }
        defer { Workspace.runSSHControlMasterCommandOverrideForTesting = nil }

        remoteWorkspace.configureRemoteConnection(config, autoConnect: false)

        manager.closeWorkspace(remoteWorkspace)

        wait(for: [cleanupRequested], timeout: 1.0)

        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertEqual(manager.tabs.first?.id, remainingWorkspace.id)
        XCTAssertFalse(manager.tabs.contains(where: { $0.id == remoteWorkspace.id }))
        XCTAssertFalse(remoteWorkspace.isRemoteWorkspace)
        XCTAssertEqual(
            capturedArguments,
            [
                "-o", "BatchMode=yes",
                "-o", "ControlMaster=no",
                "-p", "2222",
                "-i", "/Users/test/.ssh/id_ed25519",
                "-o", "ControlPath=/tmp/cmux-ssh-%C",
                "-o", "StrictHostKeyChecking=accept-new",
                "-O", "exit",
                "cmux-macmini",
            ]
        )
    }

    @MainActor
    func testDetachLastRemoteSurfacePreservesRemoteSessionWithoutCleanup() throws {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-%C",
            ],
            localProxyPort: nil,
            relayPort: 64016,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
        let cleanupRequested = expectation(description: "control master cleanup requested")
        cleanupRequested.isInverted = true

        Workspace.runSSHControlMasterCommandOverrideForTesting = { _ in
            cleanupRequested.fulfill()
        }
        defer { Workspace.runSSHControlMasterCommandOverrideForTesting = nil }

        workspace.configureRemoteConnection(config, autoConnect: false)

        let paneID = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let panelID = try XCTUnwrap(workspace.focusedTerminalPanel?.id)
        let detached = try XCTUnwrap(workspace.detachSurface(panelId: panelID))

        wait(for: [cleanupRequested], timeout: 1.0)

        XCTAssertTrue(detached.isRemoteTerminal)
        XCTAssertTrue(workspace.isRemoteWorkspace)
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 0)

        let reattachedSurfaceID = workspace.attachDetachedSurface(detached, inPane: paneID, focus: false)

        XCTAssertNotNil(reattachedSurfaceID)
        XCTAssertTrue(workspace.isRemoteWorkspace)
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 1)
        XCTAssertTrue(workspace.isRemoteTerminalSurface(detached.panelId))
    }

    @MainActor
    func testClosingSourceWorkspaceAfterDetachingRemoteSurfaceSkipsControlMasterCleanup() throws {
        let manager = TabManager()
        let sourceWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let destinationWorkspace = manager.addWorkspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-%C",
            ],
            localProxyPort: nil,
            relayPort: 64017,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
        let cleanupRequested = expectation(description: "control master cleanup requested")
        cleanupRequested.isInverted = true

        Workspace.runSSHControlMasterCommandOverrideForTesting = { _ in
            cleanupRequested.fulfill()
        }
        defer { Workspace.runSSHControlMasterCommandOverrideForTesting = nil }

        sourceWorkspace.configureRemoteConnection(config, autoConnect: false)

        let panelID = try XCTUnwrap(sourceWorkspace.focusedTerminalPanel?.id)
        let detached = try XCTUnwrap(sourceWorkspace.detachSurface(panelId: panelID))
        let destinationPaneID = try XCTUnwrap(destinationWorkspace.bonsplitController.allPaneIds.first)

        let restoredPanelID = destinationWorkspace.attachDetachedSurface(
            detached,
            inPane: destinationPaneID,
            focus: false
        )

        XCTAssertNotNil(restoredPanelID)
        XCTAssertTrue(destinationWorkspace.panels.keys.contains(detached.panelId))
        XCTAssertTrue(sourceWorkspace.panels.isEmpty)

        manager.closeWorkspace(sourceWorkspace)

        wait(for: [cleanupRequested], timeout: 1.0)

        XCTAssertFalse(manager.tabs.contains(where: { $0.id == sourceWorkspace.id }))
        XCTAssertTrue(destinationWorkspace.panels.keys.contains(detached.panelId))
    }

    @MainActor
    func testClosingMixedSourceWorkspaceAfterDetachingLastRemoteSurfaceSkipsControlMasterCleanup() throws {
        let manager = TabManager()
        let sourceWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let destinationWorkspace = manager.addWorkspace()
        let sourcePaneID = try XCTUnwrap(sourceWorkspace.bonsplitController.allPaneIds.first)
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-%C",
            ],
            localProxyPort: nil,
            relayPort: 64018,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
        let cleanupRequested = expectation(description: "control master cleanup requested")
        cleanupRequested.isInverted = true

        Workspace.runSSHControlMasterCommandOverrideForTesting = { _ in
            cleanupRequested.fulfill()
        }
        defer { Workspace.runSSHControlMasterCommandOverrideForTesting = nil }

        sourceWorkspace.configureRemoteConnection(config, autoConnect: false)
        _ = sourceWorkspace.newBrowserSurface(inPane: sourcePaneID, url: URL(string: "https://example.com"), focus: false)

        let panelID = try XCTUnwrap(sourceWorkspace.focusedTerminalPanel?.id)
        let detached = try XCTUnwrap(sourceWorkspace.detachSurface(panelId: panelID))
        let destinationPaneID = try XCTUnwrap(destinationWorkspace.bonsplitController.allPaneIds.first)

        let restoredPanelID = destinationWorkspace.attachDetachedSurface(
            detached,
            inPane: destinationPaneID,
            focus: false
        )

        XCTAssertNotNil(restoredPanelID)
        XCTAssertEqual(sourceWorkspace.panels.count, 1)
        XCTAssertTrue(destinationWorkspace.panels.keys.contains(detached.panelId))

        manager.closeWorkspace(sourceWorkspace)

        wait(for: [cleanupRequested], timeout: 1.0)

        XCTAssertFalse(manager.tabs.contains(where: { $0.id == sourceWorkspace.id }))
        XCTAssertTrue(destinationWorkspace.panels.keys.contains(detached.panelId))
    }

    @MainActor
    func testTransferredRemoteSurfaceCleansUpControlMasterWhenSessionEndsInLocalWorkspace() throws {
        let manager = TabManager()
        let sourceWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let destinationWorkspace = manager.addWorkspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-%C",
            ],
            localProxyPort: nil,
            relayPort: 64019,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
        let cleanupRequested = expectation(description: "control master cleanup requested")
        var cleanupArguments: [[String]] = []

        Workspace.runSSHControlMasterCommandOverrideForTesting = { arguments in
            cleanupArguments.append(arguments)
            cleanupRequested.fulfill()
        }
        defer { Workspace.runSSHControlMasterCommandOverrideForTesting = nil }

        sourceWorkspace.configureRemoteConnection(config, autoConnect: false)

        let panelID = try XCTUnwrap(sourceWorkspace.focusedTerminalPanel?.id)
        let detached = try XCTUnwrap(sourceWorkspace.detachSurface(panelId: panelID))
        let destinationPaneID = try XCTUnwrap(destinationWorkspace.bonsplitController.allPaneIds.first)

        let restoredPanelID = destinationWorkspace.attachDetachedSurface(
            detached,
            inPane: destinationPaneID,
            focus: false
        )

        XCTAssertNotNil(restoredPanelID)
        XCTAssertFalse(destinationWorkspace.isRemoteWorkspace)
        XCTAssertEqual(destinationWorkspace.activeRemoteTerminalSessionCount, 0)

        manager.closeWorkspace(sourceWorkspace)
        destinationWorkspace.markRemoteTerminalSessionEnded(surfaceId: detached.panelId, relayPort: config.relayPort)

        wait(for: [cleanupRequested], timeout: 1.0)

        XCTAssertEqual(cleanupArguments.count, 1)
        XCTAssertEqual(cleanupArguments.first?.suffix(2), ["exit", "cmux-macmini"])
    }

    @MainActor
    func testRemoteTerminalSessionEndSkipsControlMasterCleanupWhenBrowserPanelsKeepWorkspaceRemote() throws {
        let workspace = Workspace()
        let paneID = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let initialTerminalID = try XCTUnwrap(workspace.focusedTerminalPanel?.id)
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-%C",
            ],
            localProxyPort: nil,
            relayPort: 64013,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
        let cleanupRequested = expectation(description: "control master cleanup requested")
        cleanupRequested.isInverted = true

        Workspace.runSSHControlMasterCommandOverrideForTesting = { _ in
            cleanupRequested.fulfill()
        }
        defer { Workspace.runSSHControlMasterCommandOverrideForTesting = nil }

        workspace.configureRemoteConnection(config, autoConnect: false)
        _ = workspace.newBrowserSurface(inPane: paneID, url: URL(string: "https://example.com"), focus: false)

        workspace.markRemoteTerminalSessionEnded(surfaceId: initialTerminalID, relayPort: 64013)

        wait(for: [cleanupRequested], timeout: 1.0)

        XCTAssertTrue(workspace.isRemoteWorkspace)
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 0)
    }

    @MainActor
    func testClosingInitialRemoteTerminalPaneKeepsSiblingRemotePaneAlive() throws {
        let workspace = Workspace()
        let initialTerminalID = try XCTUnwrap(workspace.focusedTerminalPanel?.id)
        let configuration = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-%C",
            ],
            localProxyPort: nil,
            relayPort: 64020,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
        var cleanupArguments: [[String]] = []
        let cleanupRequested = expectation(description: "control master cleanup requested")
        cleanupRequested.isInverted = true

        Workspace.runSSHControlMasterCommandOverrideForTesting = { arguments in
            cleanupArguments.append(arguments)
            cleanupRequested.fulfill()
        }
        defer { Workspace.runSSHControlMasterCommandOverrideForTesting = nil }

        workspace.configureRemoteConnection(configuration, autoConnect: false)
        let siblingTerminal = try XCTUnwrap(
            workspace.newTerminalSplit(from: initialTerminalID, orientation: .horizontal)
        )

        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 2)
        XCTAssertTrue(workspace.isRemoteTerminalSurface(initialTerminalID))
        XCTAssertTrue(workspace.isRemoteTerminalSurface(siblingTerminal.id))

        XCTAssertTrue(workspace.closePanel(initialTerminalID, force: true))

        XCTAssertNil(workspace.panels[initialTerminalID])
        XCTAssertNotNil(workspace.panels[siblingTerminal.id])
        XCTAssertTrue(workspace.isRemoteWorkspace)
        XCTAssertFalse(workspace.isRemoteTerminalSurface(initialTerminalID))
        XCTAssertTrue(workspace.isRemoteTerminalSurface(siblingTerminal.id))
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 1)
        wait(for: [cleanupRequested], timeout: 0.2)
        XCTAssertTrue(cleanupArguments.isEmpty)
    }

}
