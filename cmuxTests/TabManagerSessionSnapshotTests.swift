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

    func testFocusHistoryNavigatesWithinWorkspacePanels() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let firstPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let secondPanelId = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)

        workspace.focusPanel(firstPanelId)
        workspace.focusPanel(secondPanelId)

        XCTAssertTrue(manager.canNavigateBack)

        manager.navigateBack()

        XCTAssertEqual(workspace.focusedPanelId, firstPanelId)
        XCTAssertTrue(manager.canNavigateForward)
    }

    func testFocusHistoryBackFallsBackWhenRecordedPanelWasClosed() throws {
        let manager = TabManager()
        let firstWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let pane = try XCTUnwrap(firstWorkspace.bonsplitController.allPaneIds.first)
        let closedPanelId = try XCTUnwrap(firstWorkspace.focusedPanelId)
        let fallbackPanelId = try XCTUnwrap(firstWorkspace.newTerminalSurface(inPane: pane, focus: true)?.id)

        firstWorkspace.focusPanel(closedPanelId)
        let secondWorkspace = manager.addWorkspace(select: true)
        _ = firstWorkspace.closePanel(closedPanelId, force: true)

        XCTAssertEqual(manager.selectedTabId, secondWorkspace.id)
        XCTAssertTrue(manager.canNavigateBack)

        manager.navigateBack()

        XCTAssertEqual(manager.selectedTabId, firstWorkspace.id)
        XCTAssertEqual(firstWorkspace.focusedPanelId, fallbackPanelId)
        XCTAssertNil(firstWorkspace.panels[closedPanelId])
    }

    func testFocusHistoryBackSkipsStaleEntriesThatResolveToCurrentPanel() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let closedPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let fallbackPanelId = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)

        workspace.focusPanel(closedPanelId)
        _ = workspace.closePanel(closedPanelId, force: true)
        drainMainQueue()

        XCTAssertEqual(workspace.focusedPanelId, fallbackPanelId)
        XCTAssertFalse(manager.canNavigateBack)

        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .tabManagerFocusHistoryRevisionDidChange,
            object: manager,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
        }

        manager.navigateBack()

        XCTAssertEqual(workspace.focusedPanelId, fallbackPanelId)
        XCTAssertEqual(notificationCount, 0)
    }

    func testGhosttyFocusSurfaceIdRecordsMappedPanelInFocusHistory() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let secondPanelId = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)
        let secondSurfaceId = try XCTUnwrap(workspace.surfaceIdFromPanelId(secondPanelId))
        XCTAssertNotEqual(secondSurfaceId.uuid, secondPanelId)

        let firstPanelId = try XCTUnwrap(workspace.panels.keys.first { $0 != secondPanelId })
        workspace.focusPanel(firstPanelId)
        let revision = manager.focusHistoryRevision

        NotificationCenter.default.post(
            name: .ghosttyDidFocusSurface,
            object: nil,
            userInfo: [
                GhosttyNotificationKey.tabId: workspace.id,
                GhosttyNotificationKey.surfaceId: secondSurfaceId.uuid,
            ]
        )
        drainMainQueue()

        XCTAssertGreaterThan(manager.focusHistoryRevision, revision)
    }

    func testFocusHistoryNavigatesBetweenFreshWorkspaces() throws {
        let manager = TabManager()
        let firstWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let secondWorkspace = manager.addWorkspace(select: true)

        XCTAssertEqual(manager.selectedTabId, secondWorkspace.id)
        XCTAssertTrue(manager.canNavigateBack)

        manager.navigateBack()

        XCTAssertEqual(manager.selectedTabId, firstWorkspace.id)
        XCTAssertTrue(manager.canNavigateForward)
        NotificationCenter.default.post(
            name: .ghosttyDidFocusSurface,
            object: nil,
            userInfo: [
                GhosttyNotificationKey.tabId: firstWorkspace.id,
                GhosttyNotificationKey.surfaceId: try XCTUnwrap(firstWorkspace.focusedPanelId),
            ]
        )
        drainMainQueue()
        XCTAssertTrue(manager.canNavigateForward)

        manager.navigateForward()

        XCTAssertEqual(manager.selectedTabId, secondWorkspace.id)
    }

    func testFocusHistoryRevisionPostsMenuInvalidationNotification() {
        let manager = TabManager()
        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .tabManagerFocusHistoryRevisionDidChange,
            object: manager,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
        }

        _ = manager.addWorkspace(select: true)

        XCTAssertGreaterThan(notificationCount, 0)
    }

    func testFocusHistoryNavigationNotificationSeesUpdatedDirectionState() throws {
        let manager = TabManager()
        let firstWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let secondWorkspace = manager.addWorkspace(select: true)
        XCTAssertEqual(manager.selectedTabId, secondWorkspace.id)
        XCTAssertTrue(manager.canNavigateBack)

        var observedCanNavigateForward = false
        let observer = NotificationCenter.default.addObserver(
            forName: .tabManagerFocusHistoryRevisionDidChange,
            object: manager,
            queue: nil
        ) { _ in
            observedCanNavigateForward = manager.canNavigateForward
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
        }

        manager.navigateBack()

        XCTAssertEqual(manager.selectedTabId, firstWorkspace.id)
        XCTAssertTrue(observedCanNavigateForward)
    }

    func testFocusHistoryBackMenuSnapshotLimitsBackStack() throws {
        let manager = TabManager()
        let firstWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        firstWorkspace.setCustomTitle("Workspace 0")

        for index in 1...14 {
            let workspace = manager.addWorkspace(select: true)
            workspace.setCustomTitle("Workspace \(index)")
        }

        let limitedSnapshot = manager.focusHistoryMenuSnapshot(direction: .back, maxItemCount: 5)

        XCTAssertTrue(limitedSnapshot.isLimited)
        XCTAssertEqual(limitedSnapshot.totalItemCount, 14)
        XCTAssertEqual(limitedSnapshot.items.count, 5)
        XCTAssertEqual(
            limitedSnapshot.items.map(\.workspaceTitle),
            ["Workspace 13", "Workspace 12", "Workspace 11", "Workspace 10", "Workspace 9"]
        )
        XCTAssertTrue(limitedSnapshot.items.allSatisfy { $0.position == .older })
        XCTAssertTrue(limitedSnapshot.items.allSatisfy(\.isNavigable))

        let fullSnapshot = manager.focusHistoryMenuSnapshot(direction: .back)
        XCTAssertFalse(fullSnapshot.isLimited)
        XCTAssertEqual(fullSnapshot.items.count, limitedSnapshot.totalItemCount)
    }

    func testFocusHistoryMenuSnapshotsSplitBackAndForwardStacks() throws {
        let manager = TabManager()
        let firstWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        firstWorkspace.setCustomTitle("First")
        let secondWorkspace = manager.addWorkspace(select: true)
        secondWorkspace.setCustomTitle("Second")
        let thirdWorkspace = manager.addWorkspace(select: true)
        thirdWorkspace.setCustomTitle("Third")

        manager.navigateBack()

        XCTAssertEqual(manager.selectedTabId, secondWorkspace.id)

        let backSnapshot = manager.focusHistoryMenuSnapshot(direction: .back)
        XCTAssertEqual(backSnapshot.items.map(\.workspaceTitle), ["First"])
        XCTAssertEqual(backSnapshot.items.map(\.position), [.older])
        XCTAssertTrue(backSnapshot.items.allSatisfy(\.isNavigable))

        let forwardSnapshot = manager.focusHistoryMenuSnapshot(direction: .forward)
        XCTAssertEqual(forwardSnapshot.items.map(\.workspaceTitle), ["Third"])
        XCTAssertEqual(forwardSnapshot.items.map(\.position), [.newer])
        XCTAssertTrue(forwardSnapshot.items.allSatisfy(\.isNavigable))
    }

    func testFocusHistoryMenuItemNavigatesToSelectedEntry() throws {
        let manager = TabManager()
        let firstWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        firstWorkspace.setCustomTitle("First")
        let secondWorkspace = manager.addWorkspace(select: true)
        secondWorkspace.setCustomTitle("Second")
        let thirdWorkspace = manager.addWorkspace(select: true)
        thirdWorkspace.setCustomTitle("Third")

        let snapshot = manager.focusHistoryMenuSnapshot(direction: .back)
        let firstItem = try XCTUnwrap(snapshot.items.first { $0.workspaceTitle == "First" })

        XCTAssertTrue(manager.navigateToFocusHistoryMenuItem(firstItem))
        XCTAssertEqual(manager.selectedTabId, firstWorkspace.id)

        let backSnapshot = manager.focusHistoryMenuSnapshot(direction: .back)
        XCTAssertTrue(backSnapshot.items.isEmpty)

        let forwardSnapshot = manager.focusHistoryMenuSnapshot(direction: .forward)
        XCTAssertEqual(forwardSnapshot.items.map(\.workspaceTitle), ["Second", "Third"])
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
