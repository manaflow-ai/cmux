import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class TabManagerSessionSnapshotTests: XCTestCase {
    private func waitForWorkspaceSessionRestore(
        _ manager: TabManager,
        expectedCustomTitle: String,
        timeout: TimeInterval = 2.0
    ) -> Bool {
        waitForWorkspaceSessionRestore(manager, timeout: timeout) { workspace in
            workspace.customTitle == expectedCustomTitle
        }
    }

    private func waitForWorkspaceSessionRestore(
        _ manager: TabManager,
        timeout: TimeInterval = 2.0,
        predicate: (Workspace) -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let workspace = manager.selectedWorkspace, predicate(workspace) {
                return true
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return manager.selectedWorkspace.map(predicate) ?? false
    }

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

    func testInitialWorkspaceRestoresWorkspaceSessionForWorkingDirectory() throws {
        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workspace-session-support-\(UUID().uuidString)", isDirectory: true)
        let workspaceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workspace-session-repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: appSupport)
            try? FileManager.default.removeItem(at: workspaceDirectory)
        }

        var workspaceSnapshot = try XCTUnwrap(TabManager().selectedWorkspace)
            .sessionSnapshot(includeScrollback: false)
        workspaceSnapshot.currentDirectory = workspaceDirectory.path
        workspaceSnapshot.customTitle = "Persisted Workspace"
        XCTAssertTrue(
            SessionPersistenceStore.saveWorkspaceSnapshot(
                workspaceSnapshot,
                workingDirectory: workspaceDirectory.path,
                bundleIdentifier: "dev.cmux.tests",
                appSupportDirectory: appSupport
            )
        )

        let manager = TabManager(
            initialWorkingDirectory: workspaceDirectory.path,
            autoWelcomeIfNeeded: false,
            workspaceSessionAppSupportDirectory: appSupport,
            workspaceSessionBundleIdentifier: "dev.cmux.tests"
        )

        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertTrue(waitForWorkspaceSessionRestore(manager, expectedCustomTitle: "Persisted Workspace"))
        XCTAssertEqual(manager.selectedWorkspace?.customTitle, "Persisted Workspace")
        XCTAssertEqual(manager.selectedWorkspace?.currentDirectory, workspaceDirectory.path)
    }

    func testInitialWorkspaceRestorePreservesExplicitTitle() throws {
        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workspace-session-support-\(UUID().uuidString)", isDirectory: true)
        let workspaceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workspace-session-repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: appSupport)
            try? FileManager.default.removeItem(at: workspaceDirectory)
        }

        var workspaceSnapshot = try XCTUnwrap(TabManager().selectedWorkspace)
            .sessionSnapshot(includeScrollback: false)
        workspaceSnapshot.currentDirectory = workspaceDirectory.path
        workspaceSnapshot.customTitle = "Persisted Workspace"
        workspaceSnapshot.customDescription = "Restored Description"
        XCTAssertTrue(
            SessionPersistenceStore.saveWorkspaceSnapshot(
                workspaceSnapshot,
                workingDirectory: workspaceDirectory.path,
                bundleIdentifier: "dev.cmux.tests",
                appSupportDirectory: appSupport
            )
        )

        let manager = TabManager(
            initialWorkspaceTitle: "Explicit Workspace",
            initialWorkingDirectory: workspaceDirectory.path,
            autoWelcomeIfNeeded: false,
            workspaceSessionAppSupportDirectory: appSupport,
            workspaceSessionBundleIdentifier: "dev.cmux.tests"
        )

        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertTrue(
            waitForWorkspaceSessionRestore(manager) { workspace in
                workspace.customDescription == "Restored Description"
            }
        )
        XCTAssertEqual(manager.selectedWorkspace?.customTitle, "Explicit Workspace")
        XCTAssertEqual(manager.selectedWorkspace?.customDescription, "Restored Description")
        XCTAssertEqual(manager.selectedWorkspace?.currentDirectory, workspaceDirectory.path)
    }

    func testInitialWorkspaceRestoreSkipsWhenWorkspaceMutatesBeforeAsyncRestoreApplies() throws {
        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workspace-session-support-\(UUID().uuidString)", isDirectory: true)
        let workspaceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workspace-session-repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: appSupport)
            try? FileManager.default.removeItem(at: workspaceDirectory)
        }

        var workspaceSnapshot = try XCTUnwrap(TabManager().selectedWorkspace)
            .sessionSnapshot(includeScrollback: false)
        workspaceSnapshot.currentDirectory = workspaceDirectory.path
        workspaceSnapshot.customTitle = "Persisted Workspace"
        workspaceSnapshot.customDescription = "Restored Description"
        XCTAssertTrue(
            SessionPersistenceStore.saveWorkspaceSnapshot(
                workspaceSnapshot,
                workingDirectory: workspaceDirectory.path,
                bundleIdentifier: "dev.cmux.tests",
                appSupportDirectory: appSupport
            )
        )

        let manager = TabManager(
            initialWorkingDirectory: workspaceDirectory.path,
            autoWelcomeIfNeeded: false,
            workspaceSessionAppSupportDirectory: appSupport,
            workspaceSessionBundleIdentifier: "dev.cmux.tests"
        )
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        workspace.setCustomTitle("User Change")

        XCTAssertFalse(
            waitForWorkspaceSessionRestore(manager, timeout: 1.0) { restored in
                restored.customTitle == "Persisted Workspace"
                    || restored.customDescription == "Restored Description"
            }
        )
        XCTAssertEqual(workspace.customTitle, "User Change")
        XCTAssertNil(workspace.customDescription)
        XCTAssertEqual(workspace.currentDirectory, workspaceDirectory.path)
    }

    func testInitialWorkspaceRestoreCanBeDisabledForExplicitLayouts() throws {
        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workspace-session-support-\(UUID().uuidString)", isDirectory: true)
        let workspaceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workspace-session-repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: appSupport)
            try? FileManager.default.removeItem(at: workspaceDirectory)
        }

        var workspaceSnapshot = try XCTUnwrap(TabManager().selectedWorkspace)
            .sessionSnapshot(includeScrollback: false)
        workspaceSnapshot.currentDirectory = workspaceDirectory.path
        workspaceSnapshot.customTitle = "Persisted Workspace"
        XCTAssertTrue(
            SessionPersistenceStore.saveWorkspaceSnapshot(
                workspaceSnapshot,
                workingDirectory: workspaceDirectory.path,
                bundleIdentifier: "dev.cmux.tests",
                appSupportDirectory: appSupport
            )
        )

        let manager = TabManager(
            initialWorkingDirectory: workspaceDirectory.path,
            autoWelcomeIfNeeded: false,
            workspaceSessionAppSupportDirectory: appSupport,
            workspaceSessionBundleIdentifier: "dev.cmux.tests",
            restoreWorkspaceSession: false
        )

        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertFalse(
            waitForWorkspaceSessionRestore(
                manager,
                expectedCustomTitle: "Persisted Workspace",
                timeout: 1.0
            )
        )
        XCTAssertNotEqual(manager.selectedWorkspace?.customTitle, "Persisted Workspace")
        XCTAssertEqual(manager.selectedWorkspace?.currentDirectory, workspaceDirectory.path)
    }

    func testWorkspaceRestoreClearsMissingSessionRootDirectory() throws {
        let manager = TabManager(initialWorkingDirectory: "/tmp/cmux-root")
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        XCTAssertEqual(workspace.workspaceSessionRootDirectory, "/tmp/cmux-root")

        var snapshot = workspace.sessionSnapshot(includeScrollback: false)
        snapshot.workspaceSessionRootDirectory = nil

        workspace.restoreSessionSnapshot(snapshot)

        XCTAssertNil(workspace.workspaceSessionRootDirectory)
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
