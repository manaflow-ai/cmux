import Darwin
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class TabManagerSessionSnapshotTests: XCTestCase {
    func testSessionSnapshotSerializesWorkspacesAndRestoreRebuildsSelection() {
        let manager = TabManager()
        guard let firstWorkspace = manager.selectedWorkspace else {
            XCTFail("Expected initial workspace")
            return
        }
        firstWorkspace.setCustomTitle("First")

        let secondWorkspace = manager.addWorkspace(select: true)
        secondWorkspace.setCustomTitle("Second")
        XCTAssertEqual(manager.tabs.count, 2)
        XCTAssertEqual(manager.selectedTabId, secondWorkspace.id)

        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        XCTAssertEqual(snapshot.workspaces.count, 2)
        XCTAssertEqual(snapshot.selectedWorkspaceIndex, 1)

        let restored = TabManager()
        restored.restoreSessionSnapshot(snapshot)

        XCTAssertEqual(restored.tabs.count, 2)
        XCTAssertEqual(restored.selectedTabId, restored.tabs[1].id)
        XCTAssertEqual(restored.tabs[0].customTitle, "First")
        XCTAssertEqual(restored.tabs[1].customTitle, "Second")
    }

    func testRestoreSessionSnapshotWithNoWorkspacesKeepsSingleFallbackWorkspace() {
        let manager = TabManager()
        let emptySnapshot = SessionTabManagerSnapshot(
            selectedWorkspaceIndex: nil,
            workspaces: []
        )

        manager.restoreSessionSnapshot(emptySnapshot)

        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertNotNil(manager.selectedTabId)
    }

    func testRestoredPersistentSSHBrowserOnlyWorkspaceAutoConnectsWithoutForegroundAuthTerminal() {
        let browserPanelId = UUID()
        let browserOnlySnapshot = Self.persistentSSHWorkspaceSnapshot(
            panel: Self.browserPanelSnapshot(id: browserPanelId),
            focusedPanelId: browserPanelId
        )
        XCTAssertTrue(Workspace.shouldAutoConnectRestoredRemote(
            foregroundAuthToken: " token-a ",
            snapshot: browserOnlySnapshot,
            isRunningUnderAutomatedTests: false
        ))

        let terminalPanelId = UUID()
        let terminalSnapshot = Self.persistentSSHWorkspaceSnapshot(
            panel: Self.terminalPanelSnapshot(id: terminalPanelId),
            focusedPanelId: terminalPanelId
        )
        XCTAssertFalse(Workspace.shouldAutoConnectRestoredRemote(
            foregroundAuthToken: "token-a",
            snapshot: terminalSnapshot,
            isRunningUnderAutomatedTests: false
        ))
        XCTAssertTrue(Workspace.shouldAutoConnectRestoredRemote(
            foregroundAuthToken: nil,
            snapshot: terminalSnapshot,
            isRunningUnderAutomatedTests: false
        ))
        XCTAssertFalse(Workspace.shouldAutoConnectRestoredRemote(
            foregroundAuthToken: nil,
            snapshot: browserOnlySnapshot,
            isRunningUnderAutomatedTests: true
        ))
    }

    func testSessionSnapshotIncludesRemoteWorkspacesForRestore() throws {
        let manager = TabManager()
        let remoteWorkspace = manager.addWorkspace(select: true)
        let configuration = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64001,
            relayID: "relay-test",
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
        remoteWorkspace.configureRemoteConnection(configuration, autoConnect: false)
        let paneId = try XCTUnwrap(remoteWorkspace.bonsplitController.allPaneIds.first)
        _ = remoteWorkspace.newBrowserSurface(inPane: paneId, url: URL(string: "http://localhost:3000"), focus: false)

        let snapshot = manager.sessionSnapshot(includeScrollback: false)

        XCTAssertEqual(snapshot.workspaces.count, 2)
        XCTAssertEqual(snapshot.selectedWorkspaceIndex, 1)
        let remoteSnapshot = try XCTUnwrap(snapshot.workspaces.first { $0.processTitle == remoteWorkspace.title })
        XCTAssertEqual(remoteSnapshot.remote?.destination, "cmux-macmini")
    }

    func testSessionSnapshotSkipsNonRestorableRemoteWorkspaces() {
        let manager = TabManager()
        let localWorkspace = manager.tabs[0]
        localWorkspace.setCustomTitle("Local")
        let remoteWorkspace = manager.addWorkspace(select: true)
        remoteWorkspace.setCustomTitle("Cloud VM")
        let configuration = WorkspaceRemoteConfiguration(
            transport: .websocket,
            destination: "cloud-vm",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: 54321,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil
        )
        remoteWorkspace.configureRemoteConnection(configuration, autoConnect: false)

        let snapshot = manager.sessionSnapshot(includeScrollback: false)

        XCTAssertEqual(snapshot.workspaces.count, 1)
        XCTAssertEqual(snapshot.workspaces.first?.customTitle, "Local")
        XCTAssertNil(snapshot.workspaces.first?.remote)
        XCTAssertNil(snapshot.selectedWorkspaceIndex)
    }

    func testRestoringLocalWorkspaceSnapshotClearsStaleRemoteState() throws {
        let localSnapshot = try XCTUnwrap(TabManager().selectedWorkspace)
            .sessionSnapshot(includeScrollback: false)
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let configuration = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64001,
            relayID: "relay-test",
            relayToken: String(repeating: "c", count: 64),
            localSocketPath: "/tmp/cmux-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
        workspace.configureRemoteConnection(configuration, autoConnect: false)
        XCTAssertTrue(workspace.isRemoteWorkspace)

        workspace.restoreSessionSnapshot(localSnapshot)

        XCTAssertFalse(workspace.isRemoteWorkspace)
        XCTAssertNil(workspace.remoteConfiguration)
        XCTAssertFalse(workspace.hasActiveRemoteTerminalSessions)
    }

    func testSessionSnapshotRestoresSSHWorkspaceDescriptor() throws {
        let manager = TabManager()
        let remoteWorkspace = manager.addWorkspace(select: true)
        remoteWorkspace.setCustomTitle("Remote Mac mini")
        let identityFile = "~/.ssh/id_ed25519"
        let expandedIdentityFile = (identityFile as NSString).expandingTildeInPath
        let configuration = WorkspaceRemoteConfiguration(
            destination: "dev@example.com",
            port: 2222,
            identityFile: identityFile,
            sshOptions: [
                "ControlPath=/tmp/cmux-ssh-%C",
                "ControlMaster=auto",
                "ControlPersist=60s",
                "StrictHostKeyChecking=accept-new",
            ],
            localProxyPort: nil,
            relayPort: 64002,
            relayID: "relay-restore-test",
            relayToken: String(repeating: "d", count: 64),
            localSocketPath: "/tmp/cmux-restore-test.sock",
            terminalStartupCommand: "ssh dev@example.com"
        )
        remoteWorkspace.configureRemoteConnection(configuration, autoConnect: false)
        let remotePanelId = try XCTUnwrap(remoteWorkspace.focusedPanelId)
        remoteWorkspace.updatePanelDirectory(panelId: remotePanelId, directory: "/home/dev/project")

        let snapshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-session-restore-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: snapshotURL) }
        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: Date().timeIntervalSince1970,
            windows: [
                SessionWindowSnapshot(
                    frame: nil,
                    display: nil,
                    tabManager: manager.sessionSnapshot(includeScrollback: false),
                    sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
                ),
            ]
        )
        XCTAssertTrue(SessionPersistenceStore.save(snapshot, fileURL: snapshotURL))
        let persistedTabManager = try XCTUnwrap(
            SessionPersistenceStore.load(fileURL: snapshotURL)?.windows.first?.tabManager
        )
        let remoteSnapshot = try XCTUnwrap(
            persistedTabManager.workspaces.first { $0.customTitle == "Remote Mac mini" }?.remote
        )
        XCTAssertEqual(remoteSnapshot.destination, "dev@example.com")
        XCTAssertEqual(remoteSnapshot.port, 2222)
        XCTAssertEqual(remoteSnapshot.identityFile, expandedIdentityFile)
        XCTAssertEqual(remoteSnapshot.sshOptions, [
            "StrictHostKeyChecking=accept-new",
        ])

        let restored = TabManager()
        restored.restoreSessionSnapshot(persistedTabManager)

        let restoredWorkspace = try XCTUnwrap(
            restored.tabs.first { $0.customTitle == "Remote Mac mini" }
        )
        XCTAssertTrue(restoredWorkspace.isRemoteWorkspace)
        XCTAssertEqual(restoredWorkspace.remoteDisplayTarget, "dev@example.com:2222")
        XCTAssertTrue(restoredWorkspace.hasActiveRemoteTerminalSessions)
        let restoredPanelId = try XCTUnwrap(restoredWorkspace.focusedPanelId)
        XCTAssertEqual(restoredWorkspace.panelDirectories[restoredPanelId], "/home/dev/project")
        XCTAssertNil(restoredWorkspace.terminalPanel(for: restoredPanelId)?.requestedWorkingDirectory)
        XCTAssertEqual(
            restoredWorkspace.remoteConfiguration?.terminalStartupCommand,
            "ssh -p 2222 -i \(expandedIdentityFile) -o StrictHostKeyChecking=accept-new -tt dev@example.com"
        )
    }

    func testSessionSnapshotRestoresPersistentSSHPTYWithFreshAttachAfterRelaunch() throws {
        let manager = TabManager()
        let remoteWorkspace = manager.addWorkspace(select: true)
        remoteWorkspace.setCustomTitle("Persistent SSH")
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
            preserveAfterTerminalExit: true
        )
        remoteWorkspace.configureRemoteConnection(configuration, autoConnect: false)
        let remotePanelId = try XCTUnwrap(remoteWorkspace.focusedPanelId)
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
        XCTAssertEqual(
            persistedWorkspace.panels.first { $0.id == remotePanelId }?.terminal?.remotePTYSessionID,
            expectedSessionID
        )
        let expectedScrollback = try XCTUnwrap(
            persistedWorkspace.panels.first { $0.id == remotePanelId }?.terminal?.scrollback
        )
        XCTAssertTrue(expectedScrollback.contains("cmux perf synthetic scrollback"), expectedScrollback)

        let restored = TabManager()
        restored.restoreSessionSnapshot(persistedTabManager)

        let restoredWorkspace = try XCTUnwrap(restored.tabs.first { $0.customTitle == "Persistent SSH" })
        XCTAssertEqual(restoredWorkspace.remoteConfiguration?.preserveAfterTerminalExit, true)
        let restoredForegroundAuthToken = try XCTUnwrap(restoredWorkspace.remoteConfiguration?.foregroundAuthToken)
        XCTAssertFalse(restoredForegroundAuthToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let terminalStartupCommand = try XCTUnwrap(restoredWorkspace.remoteConfiguration?.terminalStartupCommand)
        XCTAssertTrue(terminalStartupCommand.contains("ssh-pty-attach"), terminalStartupCommand)
        XCTAssertTrue(terminalStartupCommand.contains("workspace.remote.foreground_auth_ready"), terminalStartupCommand)
        XCTAssertTrue(terminalStartupCommand.contains(restoredForegroundAuthToken), terminalStartupCommand)
        XCTAssertFalse(terminalStartupCommand.contains("--require-existing"), terminalStartupCommand)
        XCTAssertTrue(terminalStartupCommand.contains("254|255"), terminalStartupCommand)
        let restoredPanelId = try XCTUnwrap(restoredWorkspace.focusedPanelId)
        let restoredInitialCommand = try XCTUnwrap(
            restoredWorkspace.terminalPanel(for: restoredPanelId)?.surface.debugInitialCommand()
        )
        XCTAssertTrue(restoredInitialCommand.contains("ssh-pty-attach"), restoredInitialCommand)
        XCTAssertTrue(restoredInitialCommand.contains("workspace.remote.foreground_auth_ready"), restoredInitialCommand)
        XCTAssertTrue(restoredInitialCommand.contains(restoredForegroundAuthToken), restoredInitialCommand)
        XCTAssertFalse(restoredInitialCommand.contains("--require-existing"), restoredInitialCommand)
        XCTAssertTrue(restoredInitialCommand.contains("254|255"), restoredInitialCommand)
        XCTAssertFalse(restoredInitialCommand.contains(expectedSessionID), restoredInitialCommand)
        XCTAssertTrue(restoredInitialCommand.contains("CMUX_SURFACE_ID"), restoredInitialCommand)

        let roundTrip = restoredWorkspace.sessionSnapshot(includeScrollback: false)
        let restoredSessionID = Workspace.defaultSSHPTYSessionID(
            workspaceId: restoredWorkspace.id,
            panelId: restoredPanelId
        )
        XCTAssertEqual(roundTrip.remote?.preserveAfterTerminalExit, true)
        XCTAssertEqual(roundTrip.panels.first?.terminal?.remotePTYSessionID, restoredSessionID)
        XCTAssertNotEqual(restoredSessionID, expectedSessionID)
        XCTAssertEqual(
            persistedWorkspace.panels.first { $0.id == remotePanelId }?.terminal?.scrollback,
            expectedScrollback
        )
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

    private static func persistentSSHWorkspaceSnapshot(
        panel: SessionPanelSnapshot,
        focusedPanelId: UUID
    ) -> SessionWorkspaceSnapshot {
        SessionWorkspaceSnapshot(
            processTitle: "Persistent SSH",
            customTitle: "Persistent SSH",
            customDescription: nil,
            customColor: nil,
            isPinned: false,
            terminalScrollBarHidden: nil,
            currentDirectory: NSHomeDirectory(),
            focusedPanelId: focusedPanelId,
            layout: .pane(SessionPaneLayoutSnapshot(
                panelIds: [focusedPanelId],
                selectedPanelId: focusedPanelId
            )),
            panels: [panel],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil,
            remote: SessionRemoteWorkspaceSnapshot(
                transport: .ssh,
                destination: "cmux-macmini",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                preserveAfterTerminalExit: true,
                skipDaemonBootstrap: nil
            )
        )
    }

    private static func browserPanelSnapshot(id: UUID) -> SessionPanelSnapshot {
        SessionPanelSnapshot(
            id: id,
            type: .browser,
            title: "Browser",
            customTitle: nil,
            directory: nil,
            isPinned: false,
            isManuallyUnread: false,
            listeningPorts: [],
            ttyName: nil,
            terminal: nil,
            browser: SessionBrowserPanelSnapshot(
                urlString: "http://localhost:3000",
                profileID: nil,
                shouldRenderWebView: true,
                pageZoom: 1,
                developerToolsVisible: false,
                backHistoryURLStrings: nil,
                forwardHistoryURLStrings: nil
            ),
            markdown: nil,
            filePreview: nil,
            rightSidebarTool: nil
        )
    }

    private static func terminalPanelSnapshot(id: UUID) -> SessionPanelSnapshot {
        SessionPanelSnapshot(
            id: id,
            type: .terminal,
            title: "Terminal",
            customTitle: nil,
            directory: nil,
            isPinned: false,
            isManuallyUnread: false,
            listeningPorts: [],
            ttyName: nil,
            terminal: SessionTerminalPanelSnapshot(),
            browser: nil,
            markdown: nil,
            filePreview: nil,
            rightSidebarTool: nil
        )
    }
}
