import Darwin
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - SSH workspace descriptor restore and snapshot factories
extension TabManagerSessionSnapshotTests {
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

        let localTerminalPanelId = UUID()
        var localTerminal = Self.terminalPanelSnapshot(id: localTerminalPanelId)
        localTerminal.terminal?.isRemoteTerminal = false
        var browserAndLocalTerminalSnapshot = browserOnlySnapshot
        browserAndLocalTerminalSnapshot.panels.append(localTerminal)
        if case .pane(var pane) = browserAndLocalTerminalSnapshot.layout {
            pane.panelIds.append(localTerminalPanelId)
            browserAndLocalTerminalSnapshot.layout = .pane(pane)
        }
        XCTAssertTrue(Workspace.shouldAutoConnectRestoredRemote(
            foregroundAuthToken: "token-a",
            snapshot: browserAndLocalTerminalSnapshot,
            isRunningUnderAutomatedTests: false
        ))

        let restoredAttachPanelId = UUID()
        var restoredAttachTerminal = Self.terminalPanelSnapshot(id: restoredAttachPanelId)
        restoredAttachTerminal.terminal?.isRemoteTerminal = false
        restoredAttachTerminal.terminal?.remotePTYSessionID = " ssh-restored-session "
        var browserAndRestoredAttachSnapshot = browserOnlySnapshot
        browserAndRestoredAttachSnapshot.panels.append(restoredAttachTerminal)
        if case .pane(var pane) = browserAndRestoredAttachSnapshot.layout {
            pane.panelIds.append(restoredAttachPanelId)
            browserAndRestoredAttachSnapshot.layout = .pane(pane)
        }
        XCTAssertFalse(Workspace.shouldAutoConnectRestoredRemote(
            foregroundAuthToken: "token-a",
            snapshot: browserAndRestoredAttachSnapshot,
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

    func testSessionSnapshotRestoresSSHWorkspaceDescriptor() throws {
        let manager = TabManager()
        let remoteWorkspace = manager.addWorkspace(select: true)
        remoteWorkspace.setCustomTitle("Remote Mac mini")
        let identityFile = "~/.ssh/id_ed25519"
        let expandedIdentityFile = (identityFile as NSString).expandingTildeInPath
        let originalAgentSocketPath = "/tmp/cmux-original-restore-agent.sock"
        let restoredAgentSocketPath = "/tmp/cmux-current-restore-agent-\(UUID().uuidString).sock"
        XCTAssertTrue(FileManager.default.createFile(atPath: restoredAgentSocketPath, contents: Data()))
        defer { try? FileManager.default.removeItem(atPath: restoredAgentSocketPath) }
        let previousAgentSocketPath = getenv("SSH_AUTH_SOCK").map { String(cString: $0) }
        setenv("SSH_AUTH_SOCK", restoredAgentSocketPath, 1)
        defer {
            if let previousAgentSocketPath {
                setenv("SSH_AUTH_SOCK", previousAgentSocketPath, 1)
            } else {
                unsetenv("SSH_AUTH_SOCK")
            }
        }
        let configuration = WorkspaceRemoteConfiguration(
            destination: "dev@example.com",
            port: 2222,
            identityFile: identityFile,
            sshOptions: [
                "ControlPath=/tmp/cmux-ssh-%C",
                "ControlMaster=auto",
                "ControlPersist=60s",
                "StrictHostKeyChecking=accept-new",
                "ForwardAgent=yes",
            ],
            localProxyPort: nil,
            relayPort: 64002,
            relayID: "relay-restore-test",
            relayToken: String(repeating: "d", count: 64),
            localSocketPath: "/tmp/cmux-restore-test.sock",
            terminalStartupCommand: "ssh dev@example.com",
            agentSocketPath: originalAgentSocketPath
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
            "ForwardAgent=yes",
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
            "ssh -p 2222 -i \(expandedIdentityFile) -o StrictHostKeyChecking=accept-new -o ForwardAgent=yes -tt dev@example.com"
        )
        XCTAssertEqual(restoredWorkspace.remoteConfiguration?.agentSocketPath, restoredAgentSocketPath)
        XCTAssertEqual(restoredWorkspace.remoteConfiguration?.sshTerminalStartupEnvironment?["SSH_AUTH_SOCK"], restoredAgentSocketPath)
        XCTAssertEqual(restoredWorkspace.remoteConfiguration?.sshProcessEnvironment?["SSH_AUTH_SOCK"], restoredAgentSocketPath)
    }

    func testSessionSnapshotRestoreOmitsSSHAgentEnvironmentWhenSocketUnavailable() throws {
        let manager = TabManager()
        let remoteWorkspace = manager.addWorkspace(select: true)
        remoteWorkspace.setCustomTitle("Remote Without Agent")
        let originalAgentSocketPath = "/tmp/cmux-original-missing-agent.sock"
        let previousAgentSocketPath = getenv("SSH_AUTH_SOCK").map { String(cString: $0) }
        defer {
            if let previousAgentSocketPath {
                setenv("SSH_AUTH_SOCK", previousAgentSocketPath, 1)
            } else {
                unsetenv("SSH_AUTH_SOCK")
            }
        }
        let configuration = WorkspaceRemoteConfiguration(
            destination: "dev@example.com",
            port: 2222,
            identityFile: nil,
            sshOptions: [
                "ForwardAgent=yes",
            ],
            localProxyPort: nil,
            relayPort: 64002,
            relayID: "relay-missing-agent-test",
            relayToken: String(repeating: "f", count: 64),
            localSocketPath: "/tmp/cmux-missing-agent-test.sock",
            terminalStartupCommand: "ssh dev@example.com",
            agentSocketPath: originalAgentSocketPath
        )
        remoteWorkspace.configureRemoteConnection(configuration, autoConnect: false)

        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        let remoteSnapshot = try XCTUnwrap(
            snapshot.workspaces.first { $0.customTitle == "Remote Without Agent" }?.remote
        )
        XCTAssertEqual(remoteSnapshot.sshOptions, ["ForwardAgent=yes"])

        unsetenv("SSH_AUTH_SOCK")
        let restored = TabManager()
        restored.restoreSessionSnapshot(snapshot)

        let restoredWorkspace = try XCTUnwrap(
            restored.tabs.first { $0.customTitle == "Remote Without Agent" }
        )
        XCTAssertEqual(
            restoredWorkspace.remoteConfiguration?.terminalStartupCommand,
            "ssh -p 2222 -o ForwardAgent=yes -tt dev@example.com"
        )
        XCTAssertNil(restoredWorkspace.remoteConfiguration?.agentSocketPath)
        XCTAssertNil(restoredWorkspace.remoteConfiguration?.sshTerminalStartupEnvironment?["SSH_AUTH_SOCK"])
        XCTAssertNil(restoredWorkspace.remoteConfiguration?.sshProcessEnvironment?["SSH_AUTH_SOCK"])
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
