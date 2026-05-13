import CoreGraphics
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

    func testTerminalSidekickStatePersistsAndRestoresWithTerminalSnapshot() throws {
        let wasBrowserDisabled = BrowserAvailabilitySettings.isDisabled()
        BrowserAvailabilitySettings.setDisabled(false)
        defer { BrowserAvailabilitySettings.setDisabled(wasBrowserDisabled) }

        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let terminalPanel = try XCTUnwrap(workspace.focusedTerminalPanel)
        let sidekickURL = try XCTUnwrap(URL(string: "data:text/html,Sidekick"))

        XCTAssertTrue(terminalPanel.openSidekick(url: sidekickURL))
        terminalPanel.setSidekickSplitRatio(0.45)

        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        let panelSnapshot = try XCTUnwrap(
            snapshot.workspaces.first?.panels.first { $0.id == terminalPanel.id }
        )
        let sidekickSnapshot = try XCTUnwrap(panelSnapshot.terminal?.sidekick)
        XCTAssertEqual(sidekickSnapshot.urlString, sidekickURL.absoluteString)
        XCTAssertTrue(sidekickSnapshot.isOpen)
        XCTAssertEqual(sidekickSnapshot.splitRatio, 0.45, accuracy: 0.001)

        let restored = TabManager()
        restored.restoreSessionSnapshot(snapshot)

        let restoredTerminal = try XCTUnwrap(restored.selectedWorkspace?.focusedTerminalPanel)
        XCTAssertEqual(restoredTerminal.sidekickState.urlString, sidekickURL.absoluteString)
        XCTAssertTrue(restoredTerminal.sidekickState.isOpen)
        XCTAssertEqual(restoredTerminal.sidekickState.splitRatio, 0.45, accuracy: 0.001)
        XCTAssertNotNil(restoredTerminal.sidekickBrowserPanel)
    }

    func testTerminalSidekickSplitRatioClampsWhenSetAndRestored() throws {
        let manager = TabManager()
        let terminalPanel = try XCTUnwrap(manager.selectedWorkspace?.focusedTerminalPanel)

        terminalPanel.setSidekickSplitRatio(0.1)
        XCTAssertEqual(terminalPanel.sidekickState.splitRatio, 0.25, accuracy: 0.001)

        terminalPanel.restoreSidekick(
            SessionTerminalSidekickSnapshot(
                urlString: nil,
                isOpen: false,
                splitRatio: 0.9
            )
        )

        XCTAssertEqual(terminalPanel.sidekickState.splitRatio, 0.7, accuracy: 0.001)
    }

    func testTerminalSidekickResizeRatioMatchesDisplayedMinimumSidekickWidth() throws {
        let totalWidth: CGFloat = 1000
        let ratio = try XCTUnwrap(
            TerminalSidekickLayout.splitRatio(
                totalWidth: totalWidth,
                startRatio: 0.25,
                translationWidth: 0
            )
        )

        let renderedSidekickWidth = TerminalSidekickLayout.sidekickWidth(
            totalWidth: totalWidth,
            splitRatio: ratio
        )
        let availableWidth = totalWidth - TerminalSidekickLayout.dividerWidth

        XCTAssertEqual(renderedSidekickWidth, 260, accuracy: 0.001)
        XCTAssertEqual(ratio, Double(renderedSidekickWidth / availableWidth), accuracy: 0.001)
    }

    func testTerminalSidekickResizeRatioPreservesMinimumTerminalWidth() throws {
        let totalWidth: CGFloat = 720
        let ratio = try XCTUnwrap(
            TerminalSidekickLayout.splitRatio(
                totalWidth: totalWidth,
                startRatio: 0.7,
                translationWidth: -400
            )
        )

        let renderedSidekickWidth = TerminalSidekickLayout.sidekickWidth(
            totalWidth: totalWidth,
            splitRatio: ratio
        )
        let renderedTerminalWidth = totalWidth - TerminalSidekickLayout.dividerWidth - renderedSidekickWidth

        XCTAssertEqual(renderedTerminalWidth, 280, accuracy: 0.001)
        XCTAssertEqual(
            ratio,
            Double(renderedSidekickWidth / (totalWidth - TerminalSidekickLayout.dividerWidth)),
            accuracy: 0.001
        )
    }

    func testTerminalSidekickRestoreStaysClosedWhenBrowserIsDisabled() throws {
        let wasBrowserDisabled = BrowserAvailabilitySettings.isDisabled()
        BrowserAvailabilitySettings.setDisabled(true)
        defer { BrowserAvailabilitySettings.setDisabled(wasBrowserDisabled) }

        let manager = TabManager()
        let terminalPanel = try XCTUnwrap(manager.selectedWorkspace?.focusedTerminalPanel)

        terminalPanel.restoreSidekick(
            SessionTerminalSidekickSnapshot(
                urlString: "https://sidekick.example/restored",
                isOpen: true,
                splitRatio: 0.4
            )
        )

        XCTAssertFalse(terminalPanel.sidekickState.isOpen)
        XCTAssertEqual(terminalPanel.sidekickState.urlString, "https://sidekick.example/restored")
        XCTAssertNil(terminalPanel.sidekickBrowserPanel)
    }

    func testTerminalSidekickManualNavigationDoesNotPreloadStoredURL() throws {
        let wasBrowserDisabled = BrowserAvailabilitySettings.isDisabled()
        BrowserAvailabilitySettings.setDisabled(false)
        defer { BrowserAvailabilitySettings.setDisabled(wasBrowserDisabled) }

        let manager = TabManager()
        let terminalPanel = try XCTUnwrap(manager.selectedWorkspace?.focusedTerminalPanel)

        terminalPanel.restoreSidekick(
            SessionTerminalSidekickSnapshot(
                urlString: "https://sidekick.example/stale",
                isOpen: false,
                splitRatio: 0.4
            )
        )
        terminalPanel.navigateSidekick(input: "https://sidekick.example/current")

        let browserPanel = try XCTUnwrap(terminalPanel.sidekickBrowserPanel)
        XCTAssertTrue(terminalPanel.sidekickState.isOpen)
        XCTAssertEqual(browserPanel.currentURL?.absoluteString, "https://sidekick.example/current")
    }

    func testTerminalSidekickRestoreNavigatesExistingPanelToSnapshotURL() throws {
        let wasBrowserDisabled = BrowserAvailabilitySettings.isDisabled()
        BrowserAvailabilitySettings.setDisabled(false)
        defer { BrowserAvailabilitySettings.setDisabled(wasBrowserDisabled) }

        let manager = TabManager()
        let terminalPanel = try XCTUnwrap(manager.selectedWorkspace?.focusedTerminalPanel)

        terminalPanel.restoreSidekick(
            SessionTerminalSidekickSnapshot(
                urlString: "https://sidekick.example/first",
                isOpen: true,
                splitRatio: 0.4
            )
        )
        let browserPanel = try XCTUnwrap(terminalPanel.sidekickBrowserPanel)
        XCTAssertEqual(browserPanel.currentURL?.absoluteString, "https://sidekick.example/first")

        terminalPanel.restoreSidekick(
            SessionTerminalSidekickSnapshot(
                urlString: "https://sidekick.example/second",
                isOpen: true,
                splitRatio: 0.4
            )
        )

        let restoredBrowserPanel = try XCTUnwrap(terminalPanel.sidekickBrowserPanel)
        XCTAssertTrue(browserPanel === restoredBrowserPanel)
        XCTAssertEqual(restoredBrowserPanel.currentURL?.absoluteString, "https://sidekick.example/second")
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

    func testSessionRemoteWorkspaceSnapshotDropsInvalidSSHPortFromReconnectCommand() throws {
        let snapshot = SessionRemoteWorkspaceSnapshot(
            transport: .ssh,
            destination: "dev@example.com",
            port: 99_999,
            identityFile: nil,
            sshOptions: [],
            skipDaemonBootstrap: nil
        )

        let configuration = try XCTUnwrap(snapshot.workspaceConfiguration())

        XCTAssertNil(configuration.port)
        XCTAssertEqual(configuration.terminalStartupCommand, "ssh -tt dev@example.com")
    }
}
