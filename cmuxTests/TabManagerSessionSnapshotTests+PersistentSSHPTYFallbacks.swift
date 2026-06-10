import Darwin
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Persistent SSH PTY restore fallbacks and requirement validation
extension TabManagerSessionSnapshotTests {
    func testPersistentSSHPTYRestoreFallsBackToSnapshotPanelDefaultSessionIDWhenActiveMarkerExists() throws {
        let manager = TabManager()
        let remoteWorkspace = manager.addWorkspace(select: true)
        remoteWorkspace.setCustomTitle("Legacy Persistent SSH")
        let persistentDaemonSlot = "ssh-legacy-persist"
        let configuration = WorkspaceRemoteConfiguration(
            destination: "dev@example.com",
            port: 2222,
            identityFile: nil,
            sshOptions: [
                "StrictHostKeyChecking=accept-new",
            ],
            localProxyPort: nil,
            relayPort: 64004,
            relayID: "relay-legacy-persist",
            relayToken: String(repeating: "f", count: 64),
            localSocketPath: "/tmp/cmux-legacy-persist.sock",
            terminalStartupCommand: SSHPTYAttachStartupCommandBuilder.command(),
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: persistentDaemonSlot
        )
        remoteWorkspace.configureRemoteConnection(configuration, autoConnect: false)
        let originalPanelId = try XCTUnwrap(remoteWorkspace.focusedPanelId)
        let expectedSessionID = Workspace.defaultSSHPTYSessionID(
            workspaceId: remoteWorkspace.id,
            panelId: originalPanelId
        )

        var legacySnapshot = manager.sessionSnapshot(includeScrollback: false)
        let workspaceIndex = try XCTUnwrap(
            legacySnapshot.workspaces.firstIndex { $0.customTitle == "Legacy Persistent SSH" }
        )
        XCTAssertEqual(legacySnapshot.workspaces[workspaceIndex].workspaceId, remoteWorkspace.id)
        let panelIndex = try XCTUnwrap(
            legacySnapshot.workspaces[workspaceIndex].panels.firstIndex { $0.id == originalPanelId }
        )
        legacySnapshot.workspaces[workspaceIndex].panels[panelIndex].terminal?.remotePTYSessionID = nil
        legacySnapshot.workspaces[workspaceIndex].panels[panelIndex].terminal?.isRemoteTerminal = true

        let reservedSocketPath = reserveRemoteRestoreSocket()
        defer { cleanupRemoteRestoreSocket(reservedSocketPath) }

        let restored = TabManager()
        restored.restoreSessionSnapshot(legacySnapshot)

        let restoredWorkspace = try XCTUnwrap(restored.tabs.first { $0.customTitle == "Legacy Persistent SSH" })
        XCTAssertNotEqual(restoredWorkspace.id, remoteWorkspace.id)
        let restoredPanelId = try XCTUnwrap(restoredWorkspace.focusedPanelId)
        let restoredInitialCommand = try XCTUnwrap(
            restoredWorkspace.terminalPanel(for: restoredPanelId)?.surface.debugInitialCommand()
        )
        XCTAssertTrue(restoredInitialCommand.hasPrefix("/bin/sh -c "), restoredInitialCommand)
        XCTAssertTrue(restoredInitialCommand.contains("ssh-pty-attach"), restoredInitialCommand)
        XCTAssertTrue(restoredInitialCommand.contains("--require-existing"), restoredInitialCommand)
        XCTAssertTrue(restoredInitialCommand.contains(expectedSessionID), restoredInitialCommand)
        XCTAssertTrue(restoredWorkspace.remotePTYSessionIDMatches(panelId: restoredPanelId, sessionID: expectedSessionID))
        XCTAssertEqual(
            restoredWorkspace.sessionSnapshot(includeScrollback: false)
                .panels.first { $0.id == restoredPanelId }?.terminal?.remotePTYSessionID,
            expectedSessionID
        )
    }

    func testPersistentSSHPTYRestoreDoesNotReattachEndedSnapshotPanel() throws {
        let manager = TabManager()
        let remoteWorkspace = manager.addWorkspace(select: true)
        remoteWorkspace.setCustomTitle("Ended Persistent SSH")
        let configuration = WorkspaceRemoteConfiguration(
            destination: "dev@example.com",
            port: 2222,
            identityFile: nil,
            sshOptions: [
                "StrictHostKeyChecking=accept-new",
            ],
            localProxyPort: nil,
            relayPort: 64019,
            relayID: "relay-ended-persist",
            relayToken: String(repeating: "a", count: 64),
            localSocketPath: "/tmp/cmux-ended-persist.sock",
            terminalStartupCommand: SSHPTYAttachStartupCommandBuilder.command(),
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: "ssh-ended-persist"
        )
        remoteWorkspace.configureRemoteConnection(configuration, autoConnect: false)
        let originalPanelId = try XCTUnwrap(remoteWorkspace.focusedPanelId)
        let endedSessionID = Workspace.defaultSSHPTYSessionID(
            workspaceId: remoteWorkspace.id,
            panelId: originalPanelId
        )

        let ended = remoteWorkspace.markRemotePTYAttachEnded(
            surfaceId: originalPanelId,
            sessionID: endedSessionID
        )
        XCTAssertTrue(ended.clearedRemotePTYSession)
        XCTAssertTrue(ended.untrackedRemoteTerminal)

        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        let persistedWorkspace = try XCTUnwrap(
            snapshot.workspaces.first { $0.customTitle == "Ended Persistent SSH" }
        )
        let persistedPanel = try XCTUnwrap(
            persistedWorkspace.panels.first { $0.id == originalPanelId }
        )
        XCTAssertEqual(persistedPanel.terminal?.isRemoteTerminal, false)
        XCTAssertNil(persistedPanel.terminal?.remotePTYSessionID)

        let reservedSocketPath = reserveRemoteRestoreSocket()
        defer { cleanupRemoteRestoreSocket(reservedSocketPath) }

        let restored = TabManager()
        restored.restoreSessionSnapshot(snapshot)

        let restoredWorkspace = try XCTUnwrap(restored.tabs.first { $0.customTitle == "Ended Persistent SSH" })
        let restoredPanelId = try XCTUnwrap(restoredWorkspace.focusedPanelId)
        let restoredInitialCommand = restoredWorkspace.terminalPanel(for: restoredPanelId)?.surface.debugInitialCommand()
        XCTAssertNil(restoredInitialCommand)
        XCTAssertNil(restoredWorkspace.terminalPanel(for: restoredPanelId)?.requestedWorkingDirectory)
        XCTAssertNil(
            restoredWorkspace.sessionSnapshot(includeScrollback: false)
                .panels.first { $0.id == restoredPanelId }?.terminal?.remotePTYSessionID
        )
    }

    func testPersistentSSHPTYRestorePreservesLocalTerminalWorkingDirectory() throws {
        let manager = TabManager()
        let remoteWorkspace = manager.addWorkspace(select: true)
        remoteWorkspace.setCustomTitle("Remote Workspace With Local Terminal")
        let configuration = WorkspaceRemoteConfiguration(
            destination: "dev@example.com",
            port: 2222,
            identityFile: nil,
            sshOptions: [
                "StrictHostKeyChecking=accept-new",
            ],
            localProxyPort: nil,
            relayPort: 64020,
            relayID: "relay-local-terminal",
            relayToken: String(repeating: "a", count: 64),
            localSocketPath: "/tmp/cmux-local-terminal.sock",
            terminalStartupCommand: SSHPTYAttachStartupCommandBuilder.command(),
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: "ssh-local-terminal"
        )
        remoteWorkspace.configureRemoteConnection(configuration, autoConnect: false)
        let paneId = try XCTUnwrap(remoteWorkspace.bonsplitController.allPaneIds.first)
        let localDirectory = "/tmp/cmux-local-terminal"
        let localPanel = try XCTUnwrap(
            remoteWorkspace.newTerminalSurface(
                inPane: paneId,
                focus: true,
                workingDirectory: localDirectory,
                suppressWorkspaceRemoteStartupCommand: true
            )
        )
        remoteWorkspace.setPanelCustomTitle(panelId: localPanel.id, title: "Local Shell")

        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        let persistedWorkspace = try XCTUnwrap(
            snapshot.workspaces.first { $0.customTitle == "Remote Workspace With Local Terminal" }
        )
        let persistedLocalPanel = try XCTUnwrap(
            persistedWorkspace.panels.first { $0.customTitle == "Local Shell" }
        )
        XCTAssertEqual(persistedLocalPanel.terminal?.isRemoteTerminal, false)
        XCTAssertEqual(persistedLocalPanel.terminal?.workingDirectory, localDirectory)

        let reservedSocketPath = reserveRemoteRestoreSocket()
        defer { cleanupRemoteRestoreSocket(reservedSocketPath) }

        let restored = TabManager()
        restored.restoreSessionSnapshot(snapshot)

        let restoredWorkspace = try XCTUnwrap(restored.tabs.first { $0.customTitle == "Remote Workspace With Local Terminal" })
        let restoredLocalPanel = try XCTUnwrap(
            restoredWorkspace.sessionSnapshot(includeScrollback: false)
                .panels.first { $0.customTitle == "Local Shell" }
        )
        let restoredPanel = try XCTUnwrap(restoredWorkspace.terminalPanel(for: restoredLocalPanel.id))
        XCTAssertNil(restoredPanel.surface.debugInitialCommand())
        XCTAssertEqual(restoredPanel.requestedWorkingDirectory, localDirectory)
    }

    func testSessionSnapshotFallsBackWhenPersistentSSHPTYRestoreHasNoSocketPath() throws {
        TerminalController.shared.stop()
        defer { TerminalController.shared.stop() }

        let manager = TabManager()
        let remoteWorkspace = manager.addWorkspace(select: true)
        remoteWorkspace.setCustomTitle("Persistent SSH Without Socket")
        remoteWorkspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "dev@example.com",
                port: 2222,
                identityFile: nil,
                sshOptions: ["StrictHostKeyChecking=accept-new"],
                localProxyPort: nil,
                relayPort: 64018,
                relayID: "relay-no-socket",
                relayToken: String(repeating: "f", count: 64),
                localSocketPath: "/tmp/cmux-no-socket.sock",
                terminalStartupCommand: SSHPTYAttachStartupCommandBuilder.command(),
                preserveAfterTerminalExit: true,
                persistentDaemonSlot: "ssh-no-socket"
            ),
            autoConnect: false
        )

        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        XCTAssertNil(TerminalController.shared.currentSocketPathForRemoteRestore())

        let restored = TabManager()
        restored.restoreSessionSnapshot(snapshot)

        let restoredWorkspace = try XCTUnwrap(restored.tabs.first { $0.customTitle == "Persistent SSH Without Socket" })
        XCTAssertEqual(restoredWorkspace.remoteConfiguration?.preserveAfterTerminalExit, false)
        XCTAssertNil(restoredWorkspace.remoteConfiguration?.relayPort)
        XCTAssertNil(restoredWorkspace.remoteConfiguration?.localSocketPath)
        XCTAssertNil(restoredWorkspace.remoteConfiguration?.persistentDaemonSlot)
        let terminalStartupCommand = try XCTUnwrap(restoredWorkspace.remoteConfiguration?.terminalStartupCommand)
        XCTAssertFalse(terminalStartupCommand.contains("ssh-pty-attach"), terminalStartupCommand)
        XCTAssertTrue(terminalStartupCommand.contains("ssh -p 2222"), terminalStartupCommand)
    }

    func testSessionSnapshotFallsBackFromSkipBootstrapPersistentSSHPTYWithoutDaemonBridge() throws {
        let manager = TabManager()
        let remoteWorkspace = manager.addWorkspace(select: true)
        remoteWorkspace.setCustomTitle("Durable Persistent SSH")
        let configuration = WorkspaceRemoteConfiguration(
            destination: "dev@example.com",
            port: 2222,
            identityFile: nil,
            sshOptions: [
                "StrictHostKeyChecking=accept-new",
            ],
            localProxyPort: nil,
            relayPort: 64003,
            relayID: "relay-persist-test",
            relayToken: String(repeating: "e", count: 64),
            localSocketPath: "/tmp/cmux-persist-test.sock",
            terminalStartupCommand: SSHPTYAttachStartupCommandBuilder.command(),
            preserveAfterTerminalExit: true,
            skipDaemonBootstrap: true
        )
        remoteWorkspace.configureRemoteConnection(configuration, autoConnect: false)
        let remotePanelId = try XCTUnwrap(remoteWorkspace.focusedPanelId)
        let expectedSessionID = Workspace.defaultSSHPTYSessionID(workspaceId: remoteWorkspace.id, panelId: remotePanelId)

        let snapshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-pty-durable-restore-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: snapshotURL) }
        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: Date().timeIntervalSince1970,
            windows: [
                SessionWindowSnapshot(
                    frame: nil,
                    display: nil,
                    tabManager: manager.sessionSnapshot(includeScrollback: true),
                    sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
                ),
            ]
        )
        XCTAssertTrue(SessionPersistenceStore.save(snapshot, fileURL: snapshotURL))
        let persistedTabManager = try XCTUnwrap(
            SessionPersistenceStore.load(fileURL: snapshotURL)?.windows.first?.tabManager
        )

        let restored = TabManager()
        restored.restoreSessionSnapshot(persistedTabManager)

        let restoredWorkspace = try XCTUnwrap(restored.tabs.first { $0.customTitle == "Durable Persistent SSH" })
        XCTAssertEqual(restoredWorkspace.remoteConfiguration?.preserveAfterTerminalExit, false)
        XCTAssertNil(restoredWorkspace.remoteConfiguration?.foregroundAuthToken)
        XCTAssertFalse(restoredWorkspace.remoteConfiguration?.sshOptions.contains { $0.hasPrefix("ControlPath") } == true)
        let terminalStartupCommand = try XCTUnwrap(restoredWorkspace.remoteConfiguration?.terminalStartupCommand)
        XCTAssertFalse(terminalStartupCommand.contains("ssh-pty-attach"), terminalStartupCommand)
        XCTAssertFalse(terminalStartupCommand.contains("workspace.remote.foreground_auth_ready"), terminalStartupCommand)
        XCTAssertEqual(terminalStartupCommand, "ssh -p 2222 -o StrictHostKeyChecking=accept-new -tt dev@example.com")

        let restoredPanelId = try XCTUnwrap(restoredWorkspace.focusedPanelId)
        let restoredInitialCommand = try XCTUnwrap(
            restoredWorkspace.terminalPanel(for: restoredPanelId)?.surface.debugInitialCommand()
        )
        XCTAssertFalse(restoredInitialCommand.contains("ssh-pty-attach"), restoredInitialCommand)
        XCTAssertFalse(restoredInitialCommand.contains(expectedSessionID), restoredInitialCommand)
        XCTAssertEqual(restoredInitialCommand, terminalStartupCommand)

        let roundTrip = restoredWorkspace.sessionSnapshot(includeScrollback: false)
        XCTAssertNil(roundTrip.remote?.preserveAfterTerminalExit)
        XCTAssertNil(roundTrip.panels.first?.terminal?.remotePTYSessionID)
    }

    func testSessionRemoteWorkspaceSnapshotRequiresPersistentDaemonSlotForPTYRestore() throws {
        let snapshot = SessionRemoteWorkspaceSnapshot(
            transport: .ssh,
            destination: "dev@example.com",
            port: 2222,
            identityFile: nil,
            sshOptions: [
                "StrictHostKeyChecking=accept-new",
                "ControlMaster=auto",
                "ControlPersist=600",
            ],
            preserveAfterTerminalExit: true,
            skipDaemonBootstrap: nil,
            relayPort: 64003,
            persistentDaemonSlot: nil
        )

        let configuration = try XCTUnwrap(snapshot.workspaceConfiguration(localSocketPath: "/tmp/cmux-restore.sock"))

        XCTAssertEqual(configuration.preserveAfterTerminalExit, false)
        XCTAssertNil(configuration.foregroundAuthToken)
        XCTAssertNil(configuration.persistentDaemonSlot)
        XCTAssertNil(configuration.relayPort)
        XCTAssertNil(configuration.localSocketPath)
        XCTAssertFalse(configuration.sshOptions.contains { $0.hasPrefix("ControlPath") })
        XCTAssertFalse(configuration.terminalStartupCommand?.contains("ssh-pty-attach") == true)
        XCTAssertEqual(configuration.terminalStartupCommand, "ssh -p 2222 -o StrictHostKeyChecking=accept-new -tt dev@example.com")
    }

    func testSessionRemoteWorkspaceSnapshotRequiresRelayPortForPTYRestore() throws {
        let snapshot = SessionRemoteWorkspaceSnapshot(
            transport: .ssh,
            destination: "dev@example.com",
            port: 2222,
            identityFile: nil,
            sshOptions: [
                "StrictHostKeyChecking=accept-new",
                "ControlMaster=auto",
                "ControlPersist=600",
            ],
            preserveAfterTerminalExit: true,
            skipDaemonBootstrap: nil,
            relayPort: nil,
            persistentDaemonSlot: "ssh-restore-slot"
        )

        let configuration = try XCTUnwrap(snapshot.workspaceConfiguration(localSocketPath: "/tmp/cmux-restore.sock"))

        XCTAssertEqual(configuration.preserveAfterTerminalExit, false)
        XCTAssertNil(configuration.foregroundAuthToken)
        XCTAssertNil(configuration.persistentDaemonSlot)
        XCTAssertNil(configuration.relayPort)
        XCTAssertNil(configuration.localSocketPath)
        XCTAssertFalse(configuration.terminalStartupCommand?.contains("ssh-pty-attach") == true)
        XCTAssertEqual(configuration.terminalStartupCommand, "ssh -p 2222 -o StrictHostKeyChecking=accept-new -tt dev@example.com")
    }

    func testSessionRemoteWorkspaceSnapshotRequiresLocalSocketPathForPTYRestore() throws {
        let snapshot = SessionRemoteWorkspaceSnapshot(
            transport: .ssh,
            destination: "dev@example.com",
            port: 2222,
            identityFile: nil,
            sshOptions: [
                "StrictHostKeyChecking=accept-new",
                "ControlMaster=auto",
                "ControlPersist=600",
            ],
            preserveAfterTerminalExit: true,
            skipDaemonBootstrap: nil,
            relayPort: 64003,
            persistentDaemonSlot: "ssh-restore-slot"
        )

        let configuration = try XCTUnwrap(snapshot.workspaceConfiguration(localSocketPath: "   "))

        XCTAssertEqual(configuration.preserveAfterTerminalExit, false)
        XCTAssertNil(configuration.foregroundAuthToken)
        XCTAssertNil(configuration.persistentDaemonSlot)
        XCTAssertNil(configuration.relayPort)
        XCTAssertNil(configuration.localSocketPath)
        XCTAssertFalse(configuration.terminalStartupCommand?.contains("ssh-pty-attach") == true)
        XCTAssertEqual(configuration.terminalStartupCommand, "ssh -p 2222 -o StrictHostKeyChecking=accept-new -tt dev@example.com")
    }

    func testSessionRemoteWorkspaceSnapshotStripsTransientControlOptionsWhenPreservedRestoreFallsBack() throws {
        let snapshot = SessionRemoteWorkspaceSnapshot(
            transport: .ssh,
            destination: "dev@example.com",
            port: 2222,
            identityFile: nil,
            sshOptions: [
                "StrictHostKeyChecking=accept-new",
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-501-64003-%C",
            ],
            preserveAfterTerminalExit: true,
            skipDaemonBootstrap: nil,
            relayPort: 64003,
            persistentDaemonSlot: "ssh-restore-slot"
        )

        let configuration = try XCTUnwrap(
            snapshot.workspaceConfiguration(localSocketPath: nil, preserveSSHOptions: true)
        )

        XCTAssertEqual(configuration.preserveAfterTerminalExit, false)
        XCTAssertEqual(configuration.sshOptions, ["StrictHostKeyChecking=accept-new"])
        XCTAssertEqual(
            configuration.terminalStartupCommand,
            "ssh -p 2222 -o StrictHostKeyChecking=accept-new -tt dev@example.com"
        )
    }

    func testSessionRemoteWorkspaceSnapshotRequiresValidPersistentDaemonSlotForPTYRestore() throws {
        let snapshot = SessionRemoteWorkspaceSnapshot(
            transport: .ssh,
            destination: "dev@example.com",
            port: 2222,
            identityFile: nil,
            sshOptions: [
                "StrictHostKeyChecking=accept-new",
                "ControlMaster=auto",
                "ControlPersist=600",
            ],
            preserveAfterTerminalExit: true,
            skipDaemonBootstrap: nil,
            relayPort: 64003,
            persistentDaemonSlot: "../bad"
        )

        let configuration = try XCTUnwrap(snapshot.workspaceConfiguration(localSocketPath: "/tmp/cmux-restore.sock"))

        XCTAssertEqual(configuration.preserveAfterTerminalExit, false)
        XCTAssertNil(configuration.foregroundAuthToken)
        XCTAssertNil(configuration.persistentDaemonSlot)
        XCTAssertNil(configuration.relayPort)
        XCTAssertNil(configuration.localSocketPath)
        XCTAssertFalse(configuration.terminalStartupCommand?.contains("ssh-pty-attach") == true)
        XCTAssertEqual(configuration.terminalStartupCommand, "ssh -p 2222 -o StrictHostKeyChecking=accept-new -tt dev@example.com")
    }

    func testSessionRemoteWorkspaceSnapshotDropsInvalidSSHPortFromReconnectCommand() throws {
        let snapshot = SessionRemoteWorkspaceSnapshot(
            transport: .ssh,
            destination: "dev@example.com",
            port: 99_999,
            identityFile: nil,
            sshOptions: [],
            preserveAfterTerminalExit: nil,
            skipDaemonBootstrap: nil
        )

        let configuration = try XCTUnwrap(snapshot.workspaceConfiguration())

        XCTAssertNil(configuration.port)
        XCTAssertEqual(configuration.terminalStartupCommand, "ssh -tt dev@example.com")
    }

}
