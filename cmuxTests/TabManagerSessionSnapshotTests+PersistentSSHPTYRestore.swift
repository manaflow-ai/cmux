import Darwin
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Persistent SSH PTY restore after relaunch and relay context ID rewrites
extension TabManagerSessionSnapshotTests {
    func testSessionSnapshotRestoresPersistentSSHPTYSessionAfterRelaunch() throws {
        let manager = TabManager()
        let remoteWorkspace = manager.addWorkspace(select: true)
        remoteWorkspace.setCustomTitle("Persistent SSH")
        let persistentDaemonSlot = "ssh-persist-test"
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
            persistentDaemonSlot: persistentDaemonSlot
        )
        remoteWorkspace.configureRemoteConnection(configuration, autoConnect: false)
        let remotePanelId = try XCTUnwrap(remoteWorkspace.focusedPanelId)
        remoteWorkspace.updatePanelDirectory(panelId: remotePanelId, directory: "/home/dev/persistent-project")
        let expectedSessionID = Workspace.defaultSSHPTYSessionID(
            workspaceId: remoteWorkspace.id,
            panelId: remotePanelId
        )
        let seededScrollback = remoteWorkspace.debugSeedSessionSnapshotScrollback(charactersPerTerminal: 160)
        XCTAssertEqual(seededScrollback.terminals, 1)

        let snapshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-pty-session-restore-\(UUID().uuidString).json")
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
        let persistedWorkspace = try XCTUnwrap(
            persistedTabManager.workspaces.first { $0.customTitle == "Persistent SSH" }
        )
        XCTAssertEqual(persistedWorkspace.remote?.preserveAfterTerminalExit, true)
        XCTAssertEqual(persistedWorkspace.remote?.relayPort, 64003)
        XCTAssertEqual(persistedWorkspace.remote?.persistentDaemonSlot, persistentDaemonSlot)
        XCTAssertEqual(
            persistedWorkspace.panels.first { $0.id == remotePanelId }?.terminal?.remotePTYSessionID,
            expectedSessionID
        )
        let expectedScrollback = try XCTUnwrap(
            persistedWorkspace.panels.first { $0.id == remotePanelId }?.terminal?.scrollback
        )
        XCTAssertTrue(expectedScrollback.contains("cmux perf synthetic scrollback"), expectedScrollback)

        let reservedSocketPath = reserveRemoteRestoreSocket()
        defer { cleanupRemoteRestoreSocket(reservedSocketPath) }

        let restored = TabManager()
        restored.restoreSessionSnapshot(persistedTabManager)

        let restoredWorkspace = try XCTUnwrap(restored.tabs.first { $0.customTitle == "Persistent SSH" })
        XCTAssertEqual(restoredWorkspace.remoteConfiguration?.preserveAfterTerminalExit, true)
        XCTAssertEqual(restoredWorkspace.remoteConfiguration?.relayPort, 64003)
        XCTAssertEqual(restoredWorkspace.remoteConfiguration?.persistentDaemonSlot, persistentDaemonSlot)
        XCTAssertEqual(restoredWorkspace.remoteConfiguration?.localSocketPath, reservedSocketPath)
        XCTAssertTrue(
            restoredWorkspace.remoteConfiguration?.sshOptions.contains("ControlPath=/tmp/cmux-ssh-\(getuid())-64003-%C") == true
        )
        XCTAssertNotEqual(restoredWorkspace.remoteConfiguration?.relayID, "relay-persist-test")
        XCTAssertNotEqual(restoredWorkspace.remoteConfiguration?.relayToken, String(repeating: "e", count: 64))
        let restoredRelayToken = try XCTUnwrap(restoredWorkspace.remoteConfiguration?.relayToken)
        XCTAssertEqual(restoredRelayToken.count, 64)
        XCTAssertNotNil(restoredRelayToken.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
        let restoredForegroundAuthToken = try XCTUnwrap(restoredWorkspace.remoteConfiguration?.foregroundAuthToken)
        XCTAssertFalse(restoredForegroundAuthToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let terminalStartupCommand = try XCTUnwrap(restoredWorkspace.remoteConfiguration?.terminalStartupCommand)
        XCTAssertTrue(terminalStartupCommand.hasPrefix("/bin/sh -c "), terminalStartupCommand)
        XCTAssertTrue(terminalStartupCommand.contains("ssh-pty-attach"), terminalStartupCommand)
        XCTAssertTrue(terminalStartupCommand.contains("workspace.remote.foreground_auth_ready"), terminalStartupCommand)
        XCTAssertTrue(terminalStartupCommand.contains(restoredForegroundAuthToken), terminalStartupCommand)
        XCTAssertFalse(terminalStartupCommand.contains(expectedSessionID), terminalStartupCommand)
        XCTAssertFalse(terminalStartupCommand.contains("--require-existing"), terminalStartupCommand)
        XCTAssertTrue(terminalStartupCommand.contains("--command-b64 "), terminalStartupCommand)
        XCTAssertTrue(terminalStartupCommand.contains("254|255"), terminalStartupCommand)
        let restoredDefaultRemoteCommand = try XCTUnwrap(
            Self.decodedSSHPTYCommandB64(in: terminalStartupCommand)
        )
        let restoredPanelId = try XCTUnwrap(restoredWorkspace.focusedPanelId)
        XCTAssertEqual(restoredWorkspace.panelDirectories[restoredPanelId], "/home/dev/persistent-project")
        XCTAssertNil(restoredWorkspace.terminalPanel(for: restoredPanelId)?.requestedWorkingDirectory)
        XCTAssertTrue(
            restoredDefaultRemoteCommand.contains("export CMUX_SOCKET_PATH=127.0.0.1:64003"),
            restoredDefaultRemoteCommand
        )
        XCTAssertTrue(
            restoredDefaultRemoteCommand.contains("export PATH=\"$HOME/.cmux/bin:$PATH\""),
            restoredDefaultRemoteCommand
        )
        XCTAssertTrue(restoredDefaultRemoteCommand.contains("CMUX_SHELL_INTEGRATION_DIR"), restoredDefaultRemoteCommand)
        XCTAssertTrue(
            restoredDefaultRemoteCommand.contains("cmux_workspace_id='__CMUX_WORKSPACE_ID__'"),
            restoredDefaultRemoteCommand
        )
        XCTAssertTrue(
            restoredDefaultRemoteCommand.contains("'__CMUX_''WORKSPACE_ID__'"),
            restoredDefaultRemoteCommand
        )
        XCTAssertFalse(
            restoredDefaultRemoteCommand.contains("[ -n '__CMUX_WORKSPACE_ID__' ]"),
            restoredDefaultRemoteCommand
        )
        XCTAssertTrue(
            restoredDefaultRemoteCommand.contains("cmux_surface_id='__CMUX_SURFACE_ID__'"),
            restoredDefaultRemoteCommand
        )
        XCTAssertTrue(
            restoredDefaultRemoteCommand.contains("'__CMUX_''SURFACE_ID__'"),
            restoredDefaultRemoteCommand
        )
        XCTAssertFalse(
            restoredDefaultRemoteCommand.contains("[ -n '__CMUX_SURFACE_ID__' ]"),
            restoredDefaultRemoteCommand
        )
        let substitutedRestoredDefaultRemoteCommand = restoredDefaultRemoteCommand
            .replacingOccurrences(of: "__CMUX_WORKSPACE_ID__", with: restoredWorkspace.id.uuidString)
            .replacingOccurrences(of: "__CMUX_SURFACE_ID__", with: restoredPanelId.uuidString)
        XCTAssertTrue(
            substitutedRestoredDefaultRemoteCommand.contains(
                "cmux_workspace_id='\(restoredWorkspace.id.uuidString)'"
            ),
            substitutedRestoredDefaultRemoteCommand
        )
        XCTAssertTrue(
            substitutedRestoredDefaultRemoteCommand.contains("cmux_surface_id='\(restoredPanelId.uuidString)'"),
            substitutedRestoredDefaultRemoteCommand
        )
        XCTAssertFalse(
            substitutedRestoredDefaultRemoteCommand.contains("CMUX_WORKSPACE_ID=__CMUX_WORKSPACE_ID__"),
            substitutedRestoredDefaultRemoteCommand
        )
        XCTAssertFalse(
            substitutedRestoredDefaultRemoteCommand.contains("CMUX_SURFACE_ID=__CMUX_SURFACE_ID__"),
            substitutedRestoredDefaultRemoteCommand
        )
        let restoredInitialCommand = try XCTUnwrap(
            restoredWorkspace.terminalPanel(for: restoredPanelId)?.surface.debugInitialCommand()
        )
        XCTAssertTrue(restoredInitialCommand.hasPrefix("/bin/sh -c "), restoredInitialCommand)
        XCTAssertTrue(restoredInitialCommand.contains("ssh-pty-attach"), restoredInitialCommand)
        XCTAssertTrue(restoredInitialCommand.contains("workspace.remote.foreground_auth_ready"), restoredInitialCommand)
        XCTAssertTrue(restoredInitialCommand.contains(restoredForegroundAuthToken), restoredInitialCommand)
        XCTAssertTrue(restoredInitialCommand.contains("--require-existing"), restoredInitialCommand)
        XCTAssertTrue(restoredInitialCommand.contains("254|255"), restoredInitialCommand)
        XCTAssertTrue(restoredInitialCommand.contains(expectedSessionID), restoredInitialCommand)
        XCTAssertTrue(restoredInitialCommand.contains("CMUX_SURFACE_ID"), restoredInitialCommand)
        XCTAssertFalse(restoredInitialCommand.contains("--command-b64 "), restoredInitialCommand)

        let roundTrip = restoredWorkspace.sessionSnapshot(includeScrollback: false)
        XCTAssertEqual(roundTrip.remote?.preserveAfterTerminalExit, true)
        XCTAssertEqual(roundTrip.remote?.relayPort, 64003)
        XCTAssertEqual(roundTrip.remote?.persistentDaemonSlot, persistentDaemonSlot)
        XCTAssertEqual(roundTrip.panels.first?.terminal?.remotePTYSessionID, expectedSessionID)
        XCTAssertEqual(
            persistedWorkspace.panels.first { $0.id == remotePanelId }?.terminal?.scrollback,
            expectedScrollback
        )
    }

    func testSessionSnapshotRestoresSplitPersistentSSHPTYWithoutDefaultAttachScaffold() throws {
        let manager = TabManager()
        let remoteWorkspace = manager.addWorkspace(select: true)
        remoteWorkspace.setCustomTitle("Persistent SSH Split")
        let persistentDaemonSlot = "ssh-persist-split"
        let configuration = WorkspaceRemoteConfiguration(
            destination: "dev@example.com",
            port: 2222,
            identityFile: "~/.ssh/id_ed25519",
            sshOptions: [
                "StrictHostKeyChecking=accept-new",
            ],
            localProxyPort: nil,
            relayPort: 64008,
            relayID: "relay-persist-split",
            relayToken: String(repeating: "c", count: 64),
            localSocketPath: "/tmp/cmux-persist-split.sock",
            terminalStartupCommand: SSHPTYAttachStartupCommandBuilder.command(),
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: persistentDaemonSlot
        )
        remoteWorkspace.configureRemoteConnection(configuration, autoConnect: false)
        let firstPanelId = try XCTUnwrap(remoteWorkspace.focusedPanelId)
        let secondPanel = try XCTUnwrap(
            remoteWorkspace.newTerminalSplit(from: firstPanelId, orientation: .horizontal, focus: true)
        )
        let expectedSessionIDs: Set<String> = [
            Workspace.defaultSSHPTYSessionID(workspaceId: remoteWorkspace.id, panelId: firstPanelId),
            Workspace.defaultSSHPTYSessionID(workspaceId: remoteWorkspace.id, panelId: secondPanel.id),
        ]

        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        let reservedSocketPath = reserveRemoteRestoreSocket()
        defer { cleanupRemoteRestoreSocket(reservedSocketPath) }

        let restored = TabManager()
        restored.restoreSessionSnapshot(snapshot)

        let restoredWorkspace = try XCTUnwrap(restored.tabs.first { $0.customTitle == "Persistent SSH Split" })
        XCTAssertEqual(restoredWorkspace.remoteConfiguration?.preserveAfterTerminalExit, true)
        XCTAssertEqual(restoredWorkspace.remoteConfiguration?.persistentDaemonSlot, persistentDaemonSlot)
        XCTAssertEqual(restoredWorkspace.activeRemoteTerminalSessionCount, 2)

        let restoredSnapshot = restoredWorkspace.sessionSnapshot(includeScrollback: false)
        let restoredTerminalPanels = restoredSnapshot.panels.filter { $0.terminal != nil }
        XCTAssertEqual(restoredTerminalPanels.count, 2)
        XCTAssertEqual(
            Set(restoredTerminalPanels.compactMap { $0.terminal?.remotePTYSessionID }),
            expectedSessionIDs
        )

        let workspaceDefaultCommand = try XCTUnwrap(restoredWorkspace.remoteConfiguration?.terminalStartupCommand)
        XCTAssertTrue(workspaceDefaultCommand.contains("--command-b64 "), workspaceDefaultCommand)
        XCTAssertFalse(workspaceDefaultCommand.contains("--require-existing"), workspaceDefaultCommand)

        for panelSnapshot in restoredTerminalPanels {
            let panel = try XCTUnwrap(restoredWorkspace.terminalPanel(for: panelSnapshot.id))
            let command = try XCTUnwrap(panel.surface.debugInitialCommand())
            XCTAssertTrue(command.contains("ssh-pty-attach"), command)
            XCTAssertTrue(command.contains("--require-existing"), command)
            XCTAssertFalse(command.contains("--command-b64 "), command)
            XCTAssertTrue(
                expectedSessionIDs.contains { command.contains($0) },
                command
            )
        }
    }

    func testPersistentSSHPTYRestoreRewritesStaleRemoteRelayContextIDs() throws {
        let manager = TabManager()
        let remoteWorkspace = manager.addWorkspace(select: true)
        remoteWorkspace.setCustomTitle("Relay Alias SSH")
        let persistentDaemonSlot = "ssh-relay-alias"
        let configuration = WorkspaceRemoteConfiguration(
            destination: "dev@example.com",
            port: 2222,
            identityFile: nil,
            sshOptions: [
                "StrictHostKeyChecking=accept-new",
            ],
            localProxyPort: nil,
            relayPort: 64006,
            relayID: "relay-alias-test",
            relayToken: String(repeating: "a", count: 64),
            localSocketPath: "/tmp/cmux-relay-alias.sock",
            terminalStartupCommand: SSHPTYAttachStartupCommandBuilder.command(),
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: persistentDaemonSlot
        )
        remoteWorkspace.configureRemoteConnection(configuration, autoConnect: false)
        let originalWorkspaceId = remoteWorkspace.id
        let originalPanelId = try XCTUnwrap(remoteWorkspace.focusedPanelId)
        let sessionID = Workspace.defaultSSHPTYSessionID(
            workspaceId: originalWorkspaceId,
            panelId: originalPanelId
        )

        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        let reservedSocketPath = reserveRemoteRestoreSocket()
        defer { cleanupRemoteRestoreSocket(reservedSocketPath) }

        let restored = TabManager()
        restored.restoreSessionSnapshot(snapshot)

        let restoredWorkspace = try XCTUnwrap(restored.tabs.first { $0.customTitle == "Relay Alias SSH" })
        let restoredPanelId = try XCTUnwrap(restoredWorkspace.focusedPanelId)
        XCTAssertNotEqual(restoredWorkspace.id, originalWorkspaceId)
        XCTAssertNotEqual(restoredPanelId, originalPanelId)

        let request: [String: Any] = [
            "id": "relay-alias-request",
            "method": "surface.report_tty",
            "params": [
                "workspace_id": originalWorkspaceId.uuidString,
                "surface_id": originalPanelId.uuidString,
                "panel_id": originalPanelId.uuidString,
                "preferred_panel_id": originalPanelId.uuidString,
                "target_panel_id": originalPanelId.uuidString,
                "created_panel_id": originalPanelId.uuidString,
                "tab_id": originalPanelId.uuidString,
                "before_panel_id": originalPanelId.uuidString,
                "before_surface_id": originalPanelId.uuidString,
                "after_panel_id": originalPanelId.uuidString,
                "after_surface_id": originalPanelId.uuidString,
                "workspace_ids": [originalWorkspaceId.uuidString],
                "panel_ids": [originalPanelId.uuidString],
                "surface_ids": [originalPanelId.uuidString],
                "tab_ids": [originalWorkspaceId.uuidString, originalPanelId.uuidString],
                "tab_id_groups": [[originalWorkspaceId.uuidString, originalPanelId.uuidString]],
                "session_id": sessionID,
                "caller": [
                    "workspace_id": originalWorkspaceId.uuidString,
                    "surface_id": originalPanelId.uuidString,
                    "panel_id": originalPanelId.uuidString,
                    "tab_id": originalWorkspaceId.uuidString,
                ],
            ],
        ]
        func decodedParams(from commandLine: Data) throws -> [String: Any] {
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: commandLine, options: []) as? [String: Any]
            )
            return try XCTUnwrap(payload["params"] as? [String: Any])
        }

        let requestData = try JSONSerialization.data(withJSONObject: request, options: []) + Data([0x0A])
        let rewrittenData = restoredWorkspace.rewriteRemoteRelayCommandLine(requestData)
        let params = try decodedParams(from: rewrittenData)
        let requestDataWithoutNewline = try JSONSerialization.data(withJSONObject: request, options: [])
        let rewrittenDataWithoutNewline = restoredWorkspace.rewriteRemoteRelayCommandLine(requestDataWithoutNewline)
        XCTAssertEqual(rewrittenData.last, UInt8(0x0A))
        XCTAssertNotEqual(rewrittenDataWithoutNewline.last, UInt8(0x0A))

        XCTAssertEqual(params["workspace_id"] as? String, restoredWorkspace.id.uuidString)
        XCTAssertEqual(params["surface_id"] as? String, restoredPanelId.uuidString)
        XCTAssertEqual(params["panel_id"] as? String, restoredPanelId.uuidString)
        XCTAssertEqual(params["preferred_panel_id"] as? String, restoredPanelId.uuidString)
        XCTAssertEqual(params["target_panel_id"] as? String, restoredPanelId.uuidString)
        XCTAssertEqual(params["created_panel_id"] as? String, restoredPanelId.uuidString)
        XCTAssertEqual(params["tab_id"] as? String, restoredPanelId.uuidString)
        XCTAssertEqual(params["before_panel_id"] as? String, restoredPanelId.uuidString)
        XCTAssertEqual(params["before_surface_id"] as? String, restoredPanelId.uuidString)
        XCTAssertEqual(params["after_panel_id"] as? String, restoredPanelId.uuidString)
        XCTAssertEqual(params["after_surface_id"] as? String, restoredPanelId.uuidString)
        XCTAssertEqual(params["workspace_ids"] as? [String], [restoredWorkspace.id.uuidString])
        XCTAssertEqual(params["panel_ids"] as? [String], [restoredPanelId.uuidString])
        XCTAssertEqual(params["surface_ids"] as? [String], [restoredPanelId.uuidString])
        XCTAssertEqual(params["tab_ids"] as? [String], [restoredWorkspace.id.uuidString, restoredPanelId.uuidString])
        XCTAssertEqual(params["tab_id_groups"] as? [[String]], [[restoredWorkspace.id.uuidString, restoredPanelId.uuidString]])
        XCTAssertEqual(params["session_id"] as? String, sessionID)

        let caller = try XCTUnwrap(params["caller"] as? [String: Any])
        XCTAssertEqual(caller["workspace_id"] as? String, restoredWorkspace.id.uuidString)
        XCTAssertEqual(caller["surface_id"] as? String, restoredPanelId.uuidString)
        XCTAssertEqual(caller["panel_id"] as? String, restoredPanelId.uuidString)
        XCTAssertEqual(caller["tab_id"] as? String, restoredWorkspace.id.uuidString)

        XCTAssertEqual(
            restoredWorkspace.sessionSnapshot(includeScrollback: false)
                .panels.first { $0.id == restoredPanelId }?.terminal?.remotePTYSessionID,
            sessionID
        )
        let refreshedRelayConfiguration = WorkspaceRemoteConfiguration(
            destination: " dev@example.com ",
            port: 2222,
            identityFile: nil,
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-\(getuid())-64006-%C",
                "StrictHostKeyChecking=accept-new",
            ],
            localProxyPort: nil,
            relayPort: 64006,
            relayID: "relay-alias-test-refreshed",
            relayToken: String(repeating: "c", count: 64),
            localSocketPath: "/tmp/cmux-relay-alias-refreshed.sock",
            terminalStartupCommand: SSHPTYAttachStartupCommandBuilder.command(),
            foregroundAuthToken: "foreground-auth-refreshed",
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: persistentDaemonSlot
        )
        restoredWorkspace.configureRemoteConnection(refreshedRelayConfiguration, autoConnect: false)
        XCTAssertTrue(restoredWorkspace.remotePTYSessionIDMatches(panelId: restoredPanelId, sessionID: sessionID))
        XCTAssertEqual(
            restoredWorkspace.sessionSnapshot(includeScrollback: false)
                .panels.first { $0.id == restoredPanelId }?.terminal?.remotePTYSessionID,
            sessionID
        )
        let refreshedRelayParams = try decodedParams(
            from: restoredWorkspace.rewriteRemoteRelayCommandLine(requestData)
        )
        XCTAssertEqual(refreshedRelayParams["workspace_id"] as? String, restoredWorkspace.id.uuidString)
        XCTAssertEqual(refreshedRelayParams["surface_id"] as? String, restoredPanelId.uuidString)
        XCTAssertEqual(refreshedRelayParams["panel_id"] as? String, restoredPanelId.uuidString)

        restoredWorkspace.disconnectRemoteConnection(clearConfiguration: false)
        XCTAssertEqual(
            restoredWorkspace.sessionSnapshot(includeScrollback: false)
                .panels.first { $0.id == restoredPanelId }?.terminal?.remotePTYSessionID,
            sessionID
        )
        let preservedDisconnectParams = try decodedParams(
            from: restoredWorkspace.rewriteRemoteRelayCommandLine(requestData)
        )
        XCTAssertEqual(preservedDisconnectParams["workspace_id"] as? String, restoredWorkspace.id.uuidString)
        XCTAssertEqual(preservedDisconnectParams["surface_id"] as? String, restoredPanelId.uuidString)
        XCTAssertEqual(preservedDisconnectParams["panel_id"] as? String, restoredPanelId.uuidString)
        let preservedCaller = try XCTUnwrap(preservedDisconnectParams["caller"] as? [String: Any])
        XCTAssertEqual(preservedCaller["workspace_id"] as? String, restoredWorkspace.id.uuidString)
        XCTAssertEqual(preservedCaller["surface_id"] as? String, restoredPanelId.uuidString)
        XCTAssertEqual(preservedCaller["panel_id"] as? String, restoredPanelId.uuidString)

        restoredWorkspace.configureRemoteConnection(configuration, autoConnect: false)
        XCTAssertTrue(restoredWorkspace.remotePTYSessionIDMatches(panelId: restoredPanelId, sessionID: sessionID))
        let reconfiguredParams = try decodedParams(from: restoredWorkspace.rewriteRemoteRelayCommandLine(requestData))
        XCTAssertEqual(reconfiguredParams["workspace_id"] as? String, restoredWorkspace.id.uuidString)
        XCTAssertEqual(reconfiguredParams["surface_id"] as? String, restoredPanelId.uuidString)
        XCTAssertEqual(reconfiguredParams["panel_id"] as? String, restoredPanelId.uuidString)

        restoredWorkspace.disconnectRemoteConnection(clearConfiguration: true)
        XCTAssertNil(
            restoredWorkspace.sessionSnapshot(includeScrollback: false)
                .panels.first { $0.id == restoredPanelId }?.terminal?.remotePTYSessionID
        )
        let clearedParams = try decodedParams(from: restoredWorkspace.rewriteRemoteRelayCommandLine(requestData))
        XCTAssertEqual(clearedParams["workspace_id"] as? String, originalWorkspaceId.uuidString)
        XCTAssertEqual(clearedParams["surface_id"] as? String, originalPanelId.uuidString)
        XCTAssertEqual(clearedParams["panel_id"] as? String, originalPanelId.uuidString)
    }

    func testRemoteRelayAmbiguousTabIDAliasesPreferWorkspaceOnCollision() throws {
        let staleID = UUID()
        let restoredWorkspaceID = UUID()
        let restoredPanelID = UUID()
        let request: [String: Any] = [
            "id": "relay-ambiguous-alias-request",
            "method": "surface.report_tty",
            "params": [
                "workspace_id": staleID.uuidString,
                "surface_id": staleID.uuidString,
                "tab_id": staleID.uuidString,
                "tab_ids": [staleID.uuidString],
            ],
        ]
        let requestData = try JSONSerialization.data(withJSONObject: request, options: [])

        let rewrittenData = Workspace.rewriteRemoteRelayCommandLine(
            requestData,
            workspaceAliases: [staleID: restoredWorkspaceID],
            surfaceAliases: [staleID: restoredPanelID]
        )
        let rewritten = try XCTUnwrap(JSONSerialization.jsonObject(with: rewrittenData) as? [String: Any])
        let params = try XCTUnwrap(rewritten["params"] as? [String: Any])

        XCTAssertEqual(params["workspace_id"] as? String, restoredWorkspaceID.uuidString)
        XCTAssertEqual(params["surface_id"] as? String, restoredPanelID.uuidString)
        XCTAssertEqual(params["tab_id"] as? String, restoredWorkspaceID.uuidString)
        XCTAssertEqual(params["tab_ids"] as? [String], [restoredWorkspaceID.uuidString])
    }

    func testPersistentSSHPTYRestoreRewritesMovedSourceWorkspaceContextID() throws {
        let manager = TabManager()
        let sourceWorkspace = manager.addWorkspace(select: true)
        sourceWorkspace.setCustomTitle("Moved Relay Source")
        let destinationWorkspace = manager.addWorkspace(select: false)
        destinationWorkspace.setCustomTitle("Moved Relay Destination")
        let persistentDaemonSlot = "ssh-relay-moved-alias"
        let configuration = WorkspaceRemoteConfiguration(
            destination: "dev@example.com",
            port: 2222,
            identityFile: nil,
            sshOptions: [
                "StrictHostKeyChecking=accept-new",
            ],
            localProxyPort: nil,
            relayPort: 64008,
            relayID: "relay-moved-alias-test",
            relayToken: String(repeating: "d", count: 64),
            localSocketPath: "/tmp/cmux-relay-moved-alias.sock",
            terminalStartupCommand: SSHPTYAttachStartupCommandBuilder.command(),
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: persistentDaemonSlot
        )
        sourceWorkspace.configureRemoteConnection(configuration, autoConnect: false)
        destinationWorkspace.configureRemoteConnection(configuration, autoConnect: false)

        let sourceWorkspaceId = sourceWorkspace.id
        let sourcePanelId = try XCTUnwrap(sourceWorkspace.focusedPanelId)
        let sessionID = Workspace.defaultSSHPTYSessionID(
            workspaceId: sourceWorkspaceId,
            panelId: sourcePanelId
        )
        let detached = try XCTUnwrap(sourceWorkspace.detachSurface(panelId: sourcePanelId))
        let destinationPaneId = try XCTUnwrap(destinationWorkspace.bonsplitController.allPaneIds.first)
        let movedPanelId = try XCTUnwrap(
            destinationWorkspace.attachDetachedSurface(
                detached,
                inPane: destinationPaneId,
                focus: true
            )
        )
        XCTAssertEqual(movedPanelId, sourcePanelId)
        XCTAssertEqual(
            destinationWorkspace.sessionSnapshot(includeScrollback: false)
                .panels.first { $0.id == movedPanelId }?.terminal?.remotePTYSessionID,
            sessionID
        )

        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        let reservedSocketPath = reserveRemoteRestoreSocket()
        defer { cleanupRemoteRestoreSocket(reservedSocketPath) }

        let restored = TabManager()
        restored.restoreSessionSnapshot(snapshot)

        let restoredWorkspace = try XCTUnwrap(
            restored.tabs.first { $0.customTitle == "Moved Relay Destination" }
        )
        let restoredSnapshot = restoredWorkspace.sessionSnapshot(includeScrollback: false)
        let restoredPanelId = try XCTUnwrap(
            restoredSnapshot.panels.first { $0.terminal?.remotePTYSessionID == sessionID }?.id
        )
        XCTAssertNotEqual(restoredWorkspace.id, destinationWorkspace.id)
        XCTAssertNotEqual(restoredWorkspace.id, sourceWorkspaceId)
        XCTAssertNotEqual(restoredPanelId, sourcePanelId)

        let request: [String: Any] = [
            "id": "relay-moved-alias-request",
            "method": "surface.report_tty",
            "params": [
                "workspace_id": sourceWorkspaceId.uuidString,
                "surface_id": sourcePanelId.uuidString,
                "panel_id": sourcePanelId.uuidString,
                "tab_id": sourceWorkspaceId.uuidString,
                "session_id": sessionID,
                "caller": [
                    "workspace_id": sourceWorkspaceId.uuidString,
                    "surface_id": sourcePanelId.uuidString,
                    "panel_id": sourcePanelId.uuidString,
                    "tab_id": sourceWorkspaceId.uuidString,
                ],
            ],
        ]
        let requestData = try JSONSerialization.data(withJSONObject: request, options: []) + Data([0x0A])
        let rewrittenData = restoredWorkspace.rewriteRemoteRelayCommandLine(requestData)
        let rewritten = try XCTUnwrap(JSONSerialization.jsonObject(with: rewrittenData, options: []) as? [String: Any])
        let params = try XCTUnwrap(rewritten["params"] as? [String: Any])

        XCTAssertEqual(params["workspace_id"] as? String, restoredWorkspace.id.uuidString)
        XCTAssertEqual(params["surface_id"] as? String, restoredPanelId.uuidString)
        XCTAssertEqual(params["panel_id"] as? String, restoredPanelId.uuidString)
        XCTAssertEqual(params["tab_id"] as? String, restoredWorkspace.id.uuidString)
        XCTAssertEqual(params["session_id"] as? String, sessionID)

        let caller = try XCTUnwrap(params["caller"] as? [String: Any])
        XCTAssertEqual(caller["workspace_id"] as? String, restoredWorkspace.id.uuidString)
        XCTAssertEqual(caller["surface_id"] as? String, restoredPanelId.uuidString)
        XCTAssertEqual(caller["panel_id"] as? String, restoredPanelId.uuidString)
        XCTAssertEqual(caller["tab_id"] as? String, restoredWorkspace.id.uuidString)
    }

    func testPersistentSSHPTYReattachRewritesStaleRemoteRelayContextIDs() throws {
        let manager = TabManager()
        let remoteWorkspace = manager.addWorkspace(select: true)
        remoteWorkspace.setCustomTitle("Relay Alias Reattach SSH")
        let persistentDaemonSlot = "ssh-relay-reattach-alias"
        let configuration = WorkspaceRemoteConfiguration(
            destination: "dev@example.com",
            port: 2222,
            identityFile: nil,
            sshOptions: [
                "StrictHostKeyChecking=accept-new",
            ],
            localProxyPort: nil,
            relayPort: 64007,
            relayID: "relay-reattach-alias-test",
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-relay-reattach-alias.sock",
            terminalStartupCommand: SSHPTYAttachStartupCommandBuilder.command(),
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: persistentDaemonSlot
        )
        remoteWorkspace.configureRemoteConnection(configuration, autoConnect: false)
        let originalWorkspaceId = remoteWorkspace.id
        let originalPanelId = try XCTUnwrap(remoteWorkspace.focusedPanelId)
        let sessionID = Workspace.defaultSSHPTYSessionID(
            workspaceId: originalWorkspaceId,
            panelId: originalPanelId
        )

        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        let reservedSocketPath = reserveRemoteRestoreSocket()
        defer { cleanupRemoteRestoreSocket(reservedSocketPath) }

        let restored = TabManager()
        restored.restoreSessionSnapshot(snapshot)

        let restoredWorkspace = try XCTUnwrap(restored.tabs.first { $0.customTitle == "Relay Alias Reattach SSH" })
        let restoredPanelId = try XCTUnwrap(restoredWorkspace.focusedPanelId)
        let ended = restoredWorkspace.markRemotePTYAttachEnded(surfaceId: restoredPanelId, sessionID: sessionID)
        XCTAssertTrue(ended.clearedRemotePTYSession)
        XCTAssertTrue(ended.untrackedRemoteTerminal)

        let paneId = try XCTUnwrap(restoredWorkspace.bonsplitController.allPaneIds.first)
        let attachStartupCommand = Workspace.sshPTYAttachStartupCommand(sessionID: sessionID)
        XCTAssertTrue(attachStartupCommand.hasPrefix("/bin/sh -c "), attachStartupCommand)
        let reattachedPanel = try XCTUnwrap(
            restoredWorkspace.newTerminalSurface(
                inPane: paneId,
                focus: true,
                initialCommand: attachStartupCommand,
                remotePTYSessionID: sessionID
            )
        )
        XCTAssertNotEqual(reattachedPanel.id, restoredPanelId)

        let request: [String: Any] = [
            "id": "relay-reattach-alias-request",
            "method": "surface.report_tty",
            "params": [
                "workspace_id": originalWorkspaceId.uuidString,
                "surface_id": originalPanelId.uuidString,
                "panel_id": originalPanelId.uuidString,
                "preferred_panel_id": originalPanelId.uuidString,
                "target_panel_id": originalPanelId.uuidString,
                "created_panel_id": originalPanelId.uuidString,
                "tab_id": originalPanelId.uuidString,
                "before_panel_id": originalPanelId.uuidString,
                "before_surface_id": originalPanelId.uuidString,
                "after_panel_id": originalPanelId.uuidString,
                "after_surface_id": originalPanelId.uuidString,
                "workspace_ids": [originalWorkspaceId.uuidString],
                "panel_ids": [originalPanelId.uuidString],
                "surface_ids": [originalPanelId.uuidString],
                "tab_ids": [originalWorkspaceId.uuidString, originalPanelId.uuidString],
                "session_id": sessionID,
            ],
        ]
        let requestData = try JSONSerialization.data(withJSONObject: request, options: []) + Data([0x0A])
        let rewrittenData = restoredWorkspace.rewriteRemoteRelayCommandLine(requestData)
        let rewritten = try XCTUnwrap(JSONSerialization.jsonObject(with: rewrittenData, options: []) as? [String: Any])
        let params = try XCTUnwrap(rewritten["params"] as? [String: Any])

        XCTAssertEqual(params["workspace_id"] as? String, restoredWorkspace.id.uuidString)
        XCTAssertEqual(params["surface_id"] as? String, reattachedPanel.id.uuidString)
        XCTAssertEqual(params["panel_id"] as? String, reattachedPanel.id.uuidString)
        XCTAssertEqual(params["preferred_panel_id"] as? String, reattachedPanel.id.uuidString)
        XCTAssertEqual(params["target_panel_id"] as? String, reattachedPanel.id.uuidString)
        XCTAssertEqual(params["created_panel_id"] as? String, reattachedPanel.id.uuidString)
        XCTAssertEqual(params["tab_id"] as? String, reattachedPanel.id.uuidString)
        XCTAssertEqual(params["before_panel_id"] as? String, reattachedPanel.id.uuidString)
        XCTAssertEqual(params["before_surface_id"] as? String, reattachedPanel.id.uuidString)
        XCTAssertEqual(params["after_panel_id"] as? String, reattachedPanel.id.uuidString)
        XCTAssertEqual(params["after_surface_id"] as? String, reattachedPanel.id.uuidString)
        XCTAssertEqual(params["workspace_ids"] as? [String], [restoredWorkspace.id.uuidString])
        XCTAssertEqual(params["panel_ids"] as? [String], [reattachedPanel.id.uuidString])
        XCTAssertEqual(params["surface_ids"] as? [String], [reattachedPanel.id.uuidString])
        XCTAssertEqual(params["tab_ids"] as? [String], [restoredWorkspace.id.uuidString, reattachedPanel.id.uuidString])
        XCTAssertEqual(params["session_id"] as? String, sessionID)
    }

    private static func decodedSSHPTYCommandB64(in command: String) -> String? {
        let marker = "--command-b64 "
        guard let markerRange = command.range(of: marker) else { return nil }
        let suffix = command[markerRange.upperBound...]
        guard let token = suffix.split(whereSeparator: { $0.isWhitespace }).first else { return nil }
        let encoded = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return String(data: data, encoding: .utf8)
    }

}
