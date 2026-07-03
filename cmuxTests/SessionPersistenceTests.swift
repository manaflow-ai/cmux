import CMUXAgentLaunch
import CmuxCore
import CmuxFoundation
import CmuxWorkspaces
import Darwin
import XCTest
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SessionPersistenceTests: XCTestCase {
    private struct LegacyPersistedWindowGeometry: Codable {
        let frame: SessionRectSnapshot
        let display: SessionDisplaySnapshot?
    }

    /// Builds the session snapshot repository under test. The legacy
    /// `SessionPersistenceStore` namespace enum took `bundleIdentifier` /
    /// `appSupportDirectory` per call; `SessionSnapshotRepository` binds them
    /// at construction, so each test constructs the store with the same
    /// scoping it previously passed per call.
    private func sessionStore(
        bundleIdentifier: String? = "com.cmuxterm.tests",
        appSupportDirectory: URL? = nil
    ) -> SessionSnapshotRepository<AppSessionSnapshot> {
        SessionSnapshotRepository(
            schemaVersion: SessionSnapshotSchema.currentVersion,
            bundleIdentifier: bundleIdentifier,
            appSupportDirectory: appSupportDirectory
        )
    }

    @MainActor
    func testWorkspaceSessionSnapshotRestoresMarkdownPanel() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-markdown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let markdownURL = root.appendingPathComponent("note.md")
        try "# hello\n".write(to: markdownURL, atomically: true, encoding: .utf8)

        let workspace = Workspace()
        let paneId = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let panel = try XCTUnwrap(
            workspace.newMarkdownSurface(
                inPane: paneId,
                filePath: markdownURL.path,
                focus: true
            )
        )
        workspace.setCustomTitle("Docs")
        workspace.setPanelCustomTitle(panelId: panel.id, title: "Readme")

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)

        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
        let restoredPanel = try XCTUnwrap(restored.markdownPanel(for: restoredPanelId))
        XCTAssertEqual(restoredPanel.filePath, markdownURL.path)
        XCTAssertEqual(restored.customTitle, "Docs")
        XCTAssertEqual(restored.panelTitle(panelId: restoredPanelId), "Readme")
    }

    @MainActor
    func testSessionSnapshotSkipsTransientRemoteListeningPorts() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
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
        workspace.surfaceListeningPorts[panelId] = [6969]

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let panelSnapshot = try XCTUnwrap(snapshot.panels.first { $0.id == panelId })

        XCTAssertTrue(panelSnapshot.listeningPorts.isEmpty)
    }

    @MainActor
    func testWorkspaceSessionSnapshotRestoresPaneNotificationsIntoStore() throws {
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let originalNotificationStore = appDelegate.notificationStore
        appDelegate.notificationStore = store
        store.replaceNotificationsForTesting([])
        defer {
            store.replaceNotificationsForTesting([])
            appDelegate.notificationStore = originalNotificationStore
        }

        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let liveSurfaceId = UUID()
        let notification = TerminalNotification(
            id: UUID(),
            tabId: workspace.id,
            surfaceId: liveSurfaceId,
            panelId: panelId,
            title: "Agent finished",
            subtitle: "codex",
            body: "Tests passed",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            isRead: false,
            paneFlash: true
        )
        store.replaceNotificationsForTesting([notification])

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let panelSnapshot = try XCTUnwrap(snapshot.panels.first { $0.id == panelId })
        XCTAssertEqual(panelSnapshot.notifications?.first?.body, "Tests passed")

        store.replaceNotificationsForTesting([])
        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)

        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
        let restoredNotification = try XCTUnwrap(store.latestNotification(forTabId: restored.id))
        XCTAssertEqual(restoredNotification.surfaceId, restoredPanelId)
        XCTAssertEqual(restoredNotification.panelId, restoredPanelId)
        XCTAssertEqual(restoredNotification.title, "Agent finished")
        XCTAssertEqual(restoredNotification.body, "Tests passed")
        XCTAssertFalse(restoredNotification.isRead)
        XCTAssertTrue(store.hasUnreadNotification(forTabId: restored.id, surfaceId: restoredPanelId))
        let restoredSurfaceId = try XCTUnwrap(restored.surfaceIdFromPanelId(restoredPanelId))
        XCTAssertEqual(restored.bonsplitController.tab(restoredSurfaceId)?.showsNotificationBadge, true)
        XCTAssertEqual(store.unreadCount(forTabId: restored.id), 1)
        XCTAssertFalse(restored.hasRestoredUnreadIndicator(panelId: restoredPanelId))
        XCTAssertTrue(store.notificationMenuSnapshot.hasNotifications)
        XCTAssertTrue(store.notificationMenuSnapshot.hasUnreadNotifications)
    }

    @MainActor
    func testRestoreSessionNotificationsKeepsNotificationIdsUniqueWhenSnapshotIsDuplicated() throws {
        let store = TerminalNotificationStore.shared
        store.replaceNotificationsForTesting([])
        defer { store.replaceNotificationsForTesting([]) }

        let duplicateId = UUID()
        let liveWorkspaceId = UUID()
        let restoredWorkspaceId = UUID()
        let existing = TerminalNotification(
            id: duplicateId,
            tabId: liveWorkspaceId,
            surfaceId: nil,
            title: "Existing",
            subtitle: "codex",
            body: "Already in the running app",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            isRead: false
        )
        let restored = TerminalNotification(
            id: duplicateId,
            tabId: restoredWorkspaceId,
            surfaceId: nil,
            title: "Restored",
            subtitle: "codex",
            body: "From the previous launch snapshot",
            createdAt: Date(timeIntervalSince1970: 1_700_000_001),
            isRead: false
        )

        store.replaceNotificationsForTesting([existing])
        store.restoreSessionNotifications([restored], forTabId: restoredWorkspaceId)

        XCTAssertEqual(store.notifications.count, 2)
        XCTAssertEqual(Set(store.notifications.map(\.id)).count, 2)
        XCTAssertTrue(store.notifications.contains { $0.tabId == liveWorkspaceId && $0.id == duplicateId })
        XCTAssertTrue(store.notifications.contains { $0.tabId == restoredWorkspaceId && $0.id != duplicateId })
    }

    func testSaveAndLoadRoundTripWithCustomSnapshotPath() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let snapshotURL = tempDir.appendingPathComponent("session.json", isDirectory: false)
        let snapshot = makeSnapshot(version: SessionSnapshotSchema.currentVersion)
        let store = sessionStore()

        XCTAssertTrue(store.save(snapshot, fileURL: snapshotURL))

        let loaded = store.load(fileURL: snapshotURL)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.version, SessionSnapshotSchema.currentVersion)
        XCTAssertEqual(loaded?.windows.count, 1)
        XCTAssertEqual(loaded?.windows.first?.sidebar.selection, .tabs)
        let frame = try XCTUnwrap(loaded?.windows.first?.frame)
        XCTAssertEqual(frame.x, 10, accuracy: 0.001)
        XCTAssertEqual(frame.y, 20, accuracy: 0.001)
        XCTAssertEqual(frame.width, 900, accuracy: 0.001)
        XCTAssertEqual(frame.height, 700, accuracy: 0.001)
        XCTAssertEqual(loaded?.windows.first?.display?.displayID, 42)
        let visibleFrame = try XCTUnwrap(loaded?.windows.first?.display?.visibleFrame)
        XCTAssertEqual(visibleFrame.y, 25, accuracy: 0.001)
    }

    func testLoadReopenSessionSnapshotRequiresPreviousSnapshotFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleIdentifier = "dev.cmux.tests.\(UUID().uuidString)"
        let store = sessionStore(bundleIdentifier: bundleIdentifier, appSupportDirectory: tempDir)
        let activeSnapshotURL = try XCTUnwrap(store.defaultSnapshotFileURL())
        let previousSnapshotURL = try XCTUnwrap(store.manualRestoreSnapshotFileURL())

        XCTAssertTrue(
            store.save(
                makeSnapshot(version: SessionSnapshotSchema.currentVersion),
                fileURL: activeSnapshotURL
            )
        )
        XCTAssertNil(store.loadReopenSessionSnapshot(fileURL: nil))

        var previousSnapshot = makeSnapshot(version: SessionSnapshotSchema.currentVersion)
        previousSnapshot.windows[0].sidebar.width = 321
        XCTAssertTrue(store.save(previousSnapshot, fileURL: previousSnapshotURL))

        let loaded = try XCTUnwrap(store.loadReopenSessionSnapshot(fileURL: nil))
        XCTAssertEqual(loaded.windows.first?.sidebar.width, 321)
    }

    private struct SnapshotBackupFixture {
        let tempDir: URL
        let bundleIdentifier: String
        let store: SessionSnapshotRepository<AppSessionSnapshot>
        let primaryURL: URL
        let backupURL: URL

        func writeCorruptPrimary() throws {
            try FileManager.default.createDirectory(
                at: primaryURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("{\"version\": 9999, \"windows\": [truncated-mid-w".utf8).write(to: primaryURL)
        }
    }

    private func makeSnapshotBackupFixture(backupSnapshot: AppSessionSnapshot) throws -> SnapshotBackupFixture {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let bundleIdentifier = "dev.cmux.tests.\(UUID().uuidString)"
        let store = sessionStore(bundleIdentifier: bundleIdentifier, appSupportDirectory: tempDir)
        let fixture = SnapshotBackupFixture(
            tempDir: tempDir,
            bundleIdentifier: bundleIdentifier,
            store: store,
            primaryURL: try XCTUnwrap(store.defaultSnapshotFileURL()),
            backupURL: try XCTUnwrap(store.manualRestoreSnapshotFileURL())
        )
        XCTAssertTrue(store.save(backupSnapshot, fileURL: fixture.backupURL))
        return fixture
    }

    func testSyncManualRestoreCachePreservesBackupWhenPrimarySnapshotIsCorrupt() throws {
        let fixture = try makeSnapshotBackupFixture(
            backupSnapshot: makeSnapshot(version: SessionSnapshotSchema.currentVersion)
        )
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }
        try fixture.writeCorruptPrimary()

        fixture.store.syncManualRestoreSnapshotCache()

        XCTAssertNotNil(
            fixture.store.load(fileURL: fixture.backupURL),
            "A corrupt primary snapshot must not destroy the restore-session backup"
        )
    }

    func testSyncManualRestoreCacheRemovesBackupWhenPrimarySnapshotIsMissing() throws {
        let fixture = try makeSnapshotBackupFixture(
            backupSnapshot: makeSnapshot(version: SessionSnapshotSchema.currentVersion)
        )
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }

        fixture.store.syncManualRestoreSnapshotCache()

        XCTAssertNil(
            fixture.store.load(fileURL: fixture.backupURL),
            "A genuinely absent primary snapshot still clears the stale backup"
        )
    }

    func testStartupSnapshotLoadRecoversFromBackupWhenPrimarySnapshotIsCorrupt() throws {
        var backupSnapshot = makeSnapshot(version: SessionSnapshotSchema.currentVersion)
        backupSnapshot.windows[0].sidebar.width = 321
        let fixture = try makeSnapshotBackupFixture(backupSnapshot: backupSnapshot)
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }
        try fixture.writeCorruptPrimary()

        let loaded = fixture.store.loadStartupSnapshot()

        XCTAssertEqual(
            loaded?.windows.first?.sidebar.width,
            321,
            "Startup restore must fall back to the backup snapshot when the primary is corrupt"
        )
    }

    func testStartupSnapshotLoadReturnsNilWhenPrimarySnapshotIsMissing() throws {
        let fixture = try makeSnapshotBackupFixture(
            backupSnapshot: makeSnapshot(version: SessionSnapshotSchema.currentVersion)
        )
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }

        XCTAssertNil(
            fixture.store.loadStartupSnapshot(),
            "A clean start without a primary snapshot must not resurrect the backup"
        )
    }

    func testSaveAndLoadRoundTripPreservesWorkspaceCustomColor() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let snapshotURL = tempDir.appendingPathComponent("session.json", isDirectory: false)
        var snapshot = makeSnapshot(version: SessionSnapshotSchema.currentVersion)
        snapshot.windows[0].tabManager.workspaces[0].customColor = "#C0392B"
        let store = sessionStore()

        XCTAssertTrue(store.save(snapshot, fileURL: snapshotURL))

        let loaded = store.load(fileURL: snapshotURL)
        XCTAssertEqual(
            loaded?.windows.first?.tabManager.workspaces.first?.customColor,
            "#C0392B"
        )
    }

    func testSaveSkipsRewritingIdenticalSnapshotData() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let snapshotURL = tempDir.appendingPathComponent("session.json", isDirectory: false)
        let snapshot = makeSnapshot(version: SessionSnapshotSchema.currentVersion)
        let store = sessionStore()

        XCTAssertTrue(store.save(snapshot, fileURL: snapshotURL))
        let firstFileNumber = try fileNumber(for: snapshotURL)

        XCTAssertTrue(store.save(snapshot, fileURL: snapshotURL))
        let secondFileNumber = try fileNumber(for: snapshotURL)

        XCTAssertEqual(
            secondFileNumber,
            firstFileNumber,
            "Saving identical session data should not replace the snapshot file"
        )
    }

    func testWorkspaceCustomColorDecodeSupportsMissingLegacyField() throws {
        var snapshot = makeSnapshot(version: SessionSnapshotSchema.currentVersion)
        snapshot.windows[0].tabManager.workspaces[0].customColor = nil

        let encoder = JSONEncoder()
        let data = try encoder.encode(snapshot)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("\"customColor\""))

        let decoded = try JSONDecoder().decode(AppSessionSnapshot.self, from: data)
        XCTAssertNil(decoded.windows.first?.tabManager.workspaces.first?.customColor)
    }

    func testLoadRejectsSchemaVersionMismatch() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let snapshotURL = tempDir.appendingPathComponent("session.json", isDirectory: false)
        let store = sessionStore()
        XCTAssertTrue(store.save(makeSnapshot(version: SessionSnapshotSchema.currentVersion + 1), fileURL: snapshotURL))

        XCTAssertNil(store.load(fileURL: snapshotURL))
    }

    func testDefaultSnapshotPathSanitizesBundleIdentifier() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let path = sessionStore(
            bundleIdentifier: "com.example/unsafe id",
            appSupportDirectory: tempDir
        ).defaultSnapshotFileURL()

        XCTAssertNotNil(path)
        XCTAssertTrue(path?.path.contains("com.example_unsafe_id") == true)
    }

    func testRestorePolicySkipsWhenLaunchHasExplicitArguments() {
        let shouldRestore = SessionRestorePolicy.shouldAttemptRestore(
            arguments: ["/Applications/cmux.app/Contents/MacOS/cmux", "--window", "window:1"],
            environment: [:]
        )

        XCTAssertFalse(shouldRestore)
    }

    func testRestorePolicyAllowsFinderStyleLaunchArgumentsOnly() {
        let shouldRestore = SessionRestorePolicy.shouldAttemptRestore(
            arguments: ["/Applications/cmux.app/Contents/MacOS/cmux", "-psn_0_12345"],
            environment: [:]
        )

        XCTAssertTrue(shouldRestore)
    }

    func testRestorePolicySkipsWhenRunningUnderXCTest() {
        let shouldRestore = SessionRestorePolicy.shouldAttemptRestore(
            arguments: ["/Applications/cmux.app/Contents/MacOS/cmux"],
            environment: ["XCTestConfigurationFilePath": "/tmp/xctest.xctestconfiguration"]
        )

        XCTAssertFalse(shouldRestore)
    }

    func testSidebarWidthSanitizationClampsToPolicyRange() {
        XCTAssertEqual(
            SessionPersistencePolicy.sanitizedSidebarWidth(-20),
            SessionPersistencePolicy.minimumSidebarWidth,
            accuracy: 0.001
        )
        XCTAssertEqual(
            SessionPersistencePolicy.sanitizedSidebarWidth(10_000),
            SessionPersistencePolicy.maximumSidebarWidth,
            accuracy: 0.001
        )
        XCTAssertEqual(
            SessionPersistencePolicy.sanitizedSidebarWidth(nil),
            SessionPersistencePolicy.defaultSidebarWidth,
            accuracy: 0.001
        )
    }

    func testSessionRectSnapshotEncodesXYWidthHeightKeys() throws {
        let snapshot = SessionRectSnapshot(x: 101.25, y: 202.5, width: 903.75, height: 704.5)
        let data = try JSONEncoder().encode(snapshot)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Double])

        XCTAssertEqual(Set(object.keys), Set(["x", "y", "width", "height"]))
        XCTAssertEqual(try XCTUnwrap(object["x"]), 101.25, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(object["y"]), 202.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(object["width"]), 903.75, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(object["height"]), 704.5, accuracy: 0.001)
    }

    func testSessionBrowserPanelSnapshotHistoryRoundTrip() throws {
        let profileID = try XCTUnwrap(UUID(uuidString: "8F03A658-5A84-428B-AD03-5A6D04692F64"))
        let source = SessionBrowserPanelSnapshot(
            urlString: "https://example.com/current",
            profileID: profileID,
            shouldRenderWebView: true,
            pageZoom: 1.2,
            developerToolsVisible: true,
            isMuted: true,
            omnibarVisible: false,
            backHistoryURLStrings: [
                "https://example.com/a",
                "https://example.com/b"
            ],
            forwardHistoryURLStrings: [
                "https://example.com/d"
            ]
        )

        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(SessionBrowserPanelSnapshot.self, from: data)
        XCTAssertEqual(decoded.urlString, source.urlString)
        XCTAssertEqual(decoded.profileID, source.profileID)
        XCTAssertEqual(decoded.isMuted, source.isMuted)
        XCTAssertEqual(decoded.omnibarVisible, false)
        XCTAssertEqual(decoded.backHistoryURLStrings, source.backHistoryURLStrings)
        XCTAssertEqual(decoded.forwardHistoryURLStrings, source.forwardHistoryURLStrings)
    }

    func testSessionBrowserPanelSnapshotHistoryDecodesWhenKeysAreMissing() throws {
        let json = """
        {
          "urlString": "https://example.com/current",
          "shouldRenderWebView": true,
          "pageZoom": 1.0,
          "developerToolsVisible": false
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(SessionBrowserPanelSnapshot.self, from: json)
        XCTAssertEqual(decoded.urlString, "https://example.com/current")
        XCTAssertNil(decoded.profileID)
        XCTAssertFalse(decoded.isMuted)
        XCTAssertNil(decoded.omnibarVisible)
        XCTAssertNil(decoded.backHistoryURLStrings)
        XCTAssertNil(decoded.forwardHistoryURLStrings)
    }

    func testScrollbackReplayEnvironmentWritesReplayFile() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-scrollback-replay-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let environment = SessionScrollbackReplayStore.replayEnvironment(
            for: "line one\nline two\n",
            tempDirectory: tempDir
        )

        let path = environment[SessionScrollbackReplayStore.environmentKey]
        XCTAssertNotNil(path)
        XCTAssertTrue(path?.hasPrefix(tempDir.path) == true)

        guard let path else { return }
        let contents = try? String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(contents, "line one\nline two\n")
    }

    func testScrollbackReplayEnvironmentSkipsWhitespaceOnlyContent() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-scrollback-replay-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let environment = SessionScrollbackReplayStore.replayEnvironment(
            for: " \n\t  ",
            tempDirectory: tempDir
        )

        XCTAssertTrue(environment.isEmpty)
    }

    func testScrollbackReplayEnvironmentPreservesANSIColorSequences() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-scrollback-replay-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let red = "\u{001B}[31m"
        let reset = "\u{001B}[0m"
        let source = "\(red)RED\(reset)\n"
        let environment = SessionScrollbackReplayStore.replayEnvironment(
            for: source,
            tempDirectory: tempDir
        )

        guard let path = environment[SessionScrollbackReplayStore.environmentKey] else {
            XCTFail("Expected replay file path")
            return
        }

        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            XCTFail("Expected replay file contents")
            return
        }

        XCTAssertTrue(contents.contains("\(red)RED\(reset)"))
        XCTAssertTrue(contents.hasPrefix(reset))
        XCTAssertTrue(contents.hasSuffix(reset))
    }

    // Regression for https://github.com/manaflow-ai/cmux/issues/5165.
    //
    // Ghostty's `write_screen_file:copy,vt` export (used to capture session
    // scrollback) prepends OSC 10 / OSC 11 sequences that bake the capture-time
    // theme's default foreground/background. Replaying those into a freshly
    // launched terminal reconfigures the live terminal's dynamic colors, so
    // restored default-colored cells keep the OLD theme instead of tracking the
    // active one — producing white-on-white scrollback after a theme change.
    // The active theme owns default fg/bg, so the restored history must not carry
    // these terminal-color OSC sequences.
    func testScrollbackReplayStripsThemeBakedDefaultColorOSCSequences() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-scrollback-replay-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let esc = "\u{001B}"
        // Captured under a dark theme: default fg baked white, default bg baked dark.
        let setForeground = "\(esc)]10;rgb:ff/ff/ff\(esc)\\"
        let setBackground = "\(esc)]11;rgb:28/2c/34\(esc)\\"
        // A BEL-terminated cursor-color OSC, the other dynamic-color terminator form.
        let setCursor = "\(esc)]12;rgb:c0/c1/b5\u{0007}"
        // Palette set/reset and a dynamic-color reset are equally theme state that
        // restored history must not re-impose, so they are stripped too.
        let setPalette = "\(esc)]4;1;rgb:aa/00/00\(esc)\\"
        let resetPalette = "\(esc)]104;1\(esc)\\"
        let resetForeground = "\(esc)]110;\(esc)\\"
        let red = "\(esc)[31m"
        let reset = "\(esc)[0m"
        // OSC 8 hyperlinks are scrollback content, not terminal color config; keep them.
        let hyperlink = "\(esc)]8;;https://example.com\(esc)\\link\(esc)]8;;\(esc)\\"
        let source = "\(setForeground)\(setBackground)\(setCursor)"
            + "\(setPalette)\(resetPalette)\(resetForeground)plain default text\n"
            + "\(red)RED\(reset) \(hyperlink)\n"

        let environment = SessionScrollbackReplayStore.replayEnvironment(
            for: source,
            tempDirectory: tempDir
        )

        guard let path = environment[SessionScrollbackReplayStore.environmentKey] else {
            XCTFail("Expected replay file path")
            return
        }
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            XCTFail("Expected replay file contents")
            return
        }

        // Terminal-color OSC sequences must be stripped so the active theme owns
        // default fg/bg/cursor and restored default cells track it.
        XCTAssertFalse(contents.contains("\(esc)]10;"), "OSC 10 (set foreground) must be stripped")
        XCTAssertFalse(contents.contains("\(esc)]11;"), "OSC 11 (set background) must be stripped")
        XCTAssertFalse(contents.contains("\(esc)]12;"), "OSC 12 (set cursor color) must be stripped")
        XCTAssertFalse(contents.contains("\(esc)]4;"), "OSC 4 (set palette entry) must be stripped")
        XCTAssertFalse(contents.contains("\(esc)]104;"), "OSC 104 (reset palette entry) must be stripped")
        XCTAssertFalse(contents.contains("\(esc)]110;"), "OSC 110 (reset foreground) must be stripped")
        XCTAssertFalse(contents.contains("rgb:ff/ff/ff"), "baked default-color payload must be gone")
        XCTAssertFalse(contents.contains("rgb:aa/00/00"), "baked palette payload must be gone")

        // Explicit SGR colors, plain text, and hyperlinks are preserved verbatim.
        XCTAssertTrue(contents.contains("plain default text"))
        XCTAssertTrue(contents.contains("\(red)RED\(reset)"))
        XCTAssertTrue(contents.contains(hyperlink), "non-color OSC sequences must be preserved")
    }

    func testSessionScrollbackPersistenceHonorsReportedShellState() {
        XCTAssertTrue(
            Workspace.shouldPersistSessionScrollback(
                shellActivityState: .promptIdle,
                fallbackNeedsConfirmClose: true
            )
        )
        XCTAssertFalse(
            Workspace.shouldPersistSessionScrollback(
                shellActivityState: .commandRunning,
                fallbackNeedsConfirmClose: false
            )
        )
        XCTAssertFalse(
            Workspace.shouldPersistSessionScrollback(
                shellActivityState: .unknown,
                fallbackNeedsConfirmClose: true
            )
        )
        XCTAssertTrue(
            Workspace.shouldPersistSessionScrollback(
                shellActivityState: nil,
                fallbackNeedsConfirmClose: false
            )
        )
    }

    func testTruncatedScrollbackAvoidsLeadingPartialANSICSISequence() {
        let maxChars = SessionPersistencePolicy.maxScrollbackCharactersPerTerminal
        let source = "\u{001B}[31m"
            + String(repeating: "X", count: maxChars - 7)
            + "\u{001B}[0m"

        guard let truncated = SessionPersistencePolicy.truncatedScrollback(source) else {
            XCTFail("Expected truncated scrollback")
            return
        }

        XCTAssertFalse(truncated.hasPrefix("31m"))
        XCTAssertFalse(truncated.hasPrefix("[31m"))
        XCTAssertFalse(truncated.hasPrefix("m"))
    }

    func testNormalizedExportedScreenPathAcceptsAbsoluteAndFileURL() {
        XCTAssertEqual(
            TerminalController.normalizedExportedScreenPath("/tmp/cmux-screen.txt"),
            "/tmp/cmux-screen.txt"
        )
        XCTAssertEqual(
            TerminalController.normalizedExportedScreenPath(" file:///tmp/cmux-screen.txt "),
            "/tmp/cmux-screen.txt"
        )
    }

    func testNormalizedExportedScreenPathRejectsRelativeAndWhitespace() {
        XCTAssertNil(TerminalController.normalizedExportedScreenPath("relative/path.txt"))
        XCTAssertNil(TerminalController.normalizedExportedScreenPath("   "))
        XCTAssertNil(TerminalController.normalizedExportedScreenPath(nil))
    }

    func testNormalizedMobileVTExportTextSplitsGhosttyCRLFRows() {
        let normalized = TerminalController.normalizedMobileVTExportText("first\r\nsecond\r\nthird")
        let rows = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        XCTAssertEqual(rows, ["first", "second", "third"])
    }

    func testShouldRemoveExportedScreenDirectoryOnlyWithinTemporaryRoot() {
        let tempRoot = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("cmux-export-tests-\(UUID().uuidString)", isDirectory: true)
        let tempFile = tempRoot
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("screen.txt", isDirectory: false)
        let outsideFile = URL(fileURLWithPath: "/Users/example/screen.txt")

        XCTAssertTrue(
            TerminalController.shouldRemoveExportedScreenDirectory(
                fileURL: tempFile,
                temporaryDirectory: tempRoot
            )
        )
        XCTAssertFalse(
            TerminalController.shouldRemoveExportedScreenDirectory(
                fileURL: outsideFile,
                temporaryDirectory: tempRoot
            )
        )
    }

    func testShouldRemoveExportedScreenFileOnlyWithinTemporaryRoot() {
        let tempRoot = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("cmux-export-tests-\(UUID().uuidString)", isDirectory: true)
        let tempFile = tempRoot
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("screen.txt", isDirectory: false)
        let outsideFile = URL(fileURLWithPath: "/Users/example/screen.txt")

        XCTAssertTrue(
            TerminalController.shouldRemoveExportedScreenFile(
                fileURL: tempFile,
                temporaryDirectory: tempRoot
            )
        )
        XCTAssertFalse(
            TerminalController.shouldRemoveExportedScreenFile(
                fileURL: outsideFile,
                temporaryDirectory: tempRoot
            )
        )
    }

    func testWindowUnregisterSnapshotPersistencePolicy() {
        XCTAssertTrue(AppDelegate.shouldPersistSnapshotOnWindowUnregister(isTerminatingApp: false))
        XCTAssertFalse(AppDelegate.shouldPersistSnapshotOnWindowUnregister(isTerminatingApp: true))
    }

    func testMainWindowRegistrationSnapshotSavePolicySkipsStartupRestore() {
        XCTAssertTrue(
            AppDelegate.shouldSaveSessionSnapshotAfterMainWindowRegistration(
                isTerminatingApp: false,
                didApplyStartupSessionRestore: false,
                isApplyingSessionRestore: false
            )
        )
        XCTAssertFalse(
            AppDelegate.shouldSaveSessionSnapshotAfterMainWindowRegistration(
                isTerminatingApp: true,
                didApplyStartupSessionRestore: false,
                isApplyingSessionRestore: false
            )
        )
        XCTAssertFalse(
            AppDelegate.shouldSaveSessionSnapshotAfterMainWindowRegistration(
                isTerminatingApp: false,
                didApplyStartupSessionRestore: true,
                isApplyingSessionRestore: false
            )
        )
        XCTAssertFalse(
            AppDelegate.shouldSaveSessionSnapshotAfterMainWindowRegistration(
                isTerminatingApp: false,
                didApplyStartupSessionRestore: false,
                isApplyingSessionRestore: true
            )
        )
    }

    func testShouldSkipSessionSaveDuringRestorePolicy() {
        XCTAssertTrue(
            AppDelegate.shouldSkipSessionSaveDuringRestore(
                isApplyingSessionRestore: true,
                includeScrollback: false
            )
        )
        XCTAssertFalse(
            AppDelegate.shouldSkipSessionSaveDuringRestore(
                isApplyingSessionRestore: true,
                includeScrollback: true
            )
        )
        XCTAssertFalse(
            AppDelegate.shouldSkipSessionSaveDuringRestore(
                isApplyingSessionRestore: false,
                includeScrollback: false
            )
        )
    }

    func testSessionAutosaveTickPolicySkipsWhenTerminating() {
        XCTAssertTrue(
            AppDelegate.shouldRunSessionAutosaveTick(isTerminatingApp: false)
        )
        XCTAssertFalse(
            AppDelegate.shouldRunSessionAutosaveTick(isTerminatingApp: true)
        )
    }

    func testApplicationResignDoesNotTriggerSessionSnapshotSave() {
        XCTAssertFalse(
            AppDelegate.shouldSaveSessionSnapshotOnApplicationResign(isTerminatingApp: false)
        )
        XCTAssertFalse(
            AppDelegate.shouldSaveSessionSnapshotOnApplicationResign(isTerminatingApp: true)
        )
    }

    func testSessionSnapshotSynchronousWritePolicy() {
        XCTAssertFalse(
            AppDelegate.shouldWriteSessionSnapshotSynchronously(
                isTerminatingApp: false,
                includeScrollback: false
            )
        )
        XCTAssertFalse(
            AppDelegate.shouldWriteSessionSnapshotSynchronously(
                isTerminatingApp: false,
                includeScrollback: true
            )
        )
        XCTAssertFalse(
            AppDelegate.shouldWriteSessionSnapshotSynchronously(
                isTerminatingApp: true,
                includeScrollback: false
            )
        )
        XCTAssertTrue(
            AppDelegate.shouldWriteSessionSnapshotSynchronously(
                isTerminatingApp: true,
                includeScrollback: true
            )
        )
    }

    func testRestoreCompletionSavePolicySkipsManualReopen() {
        XCTAssertTrue(
            AppDelegate.shouldSaveSessionSnapshotOnRestoreCompletion(
                isManualReopen: false
            )
        )
        XCTAssertFalse(
            AppDelegate.shouldSaveSessionSnapshotOnRestoreCompletion(
                isManualReopen: true
            )
        )
    }

    func testUnchangedAutosaveFingerprintSkipsWithinStalenessWindow() {
        let now = Date()
        XCTAssertTrue(
            AppDelegate.shouldSkipSessionAutosaveForUnchangedFingerprint(
                isTerminatingApp: false,
                includeScrollback: false,
                previousFingerprint: 1234,
                currentFingerprint: 1234,
                lastPersistedAt: now.addingTimeInterval(-5),
                now: now,
                maximumAutosaveSkippableInterval: 60
            )
        )
    }

    func testUnchangedAutosaveFingerprintDoesNotSkipAfterStalenessWindow() {
        let now = Date()
        XCTAssertFalse(
            AppDelegate.shouldSkipSessionAutosaveForUnchangedFingerprint(
                isTerminatingApp: false,
                includeScrollback: false,
                previousFingerprint: 1234,
                currentFingerprint: 1234,
                lastPersistedAt: now.addingTimeInterval(-120),
                now: now,
                maximumAutosaveSkippableInterval: 60
            )
        )
    }

    func testUnchangedAutosaveFingerprintNeverSkipsTerminatingOrScrollbackWrites() {
        let now = Date()
        XCTAssertFalse(
            AppDelegate.shouldSkipSessionAutosaveForUnchangedFingerprint(
                isTerminatingApp: true,
                includeScrollback: false,
                previousFingerprint: 1234,
                currentFingerprint: 1234,
                lastPersistedAt: now.addingTimeInterval(-1),
                now: now
            )
        )
        XCTAssertFalse(
            AppDelegate.shouldSkipSessionAutosaveForUnchangedFingerprint(
                isTerminatingApp: false,
                includeScrollback: true,
                previousFingerprint: 1234,
                currentFingerprint: 1234,
                lastPersistedAt: now.addingTimeInterval(-1),
                now: now
            )
        )
    }

    func testSessionAutosaveFingerprintIncludesRestorableAgentMetadata() throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let baselineFingerprint = TabManager.restorableAgentSnapshotFingerprint(nil)

        let firstIndex = try makeRestorableAgentIndex(
            workspaceId: workspaceId,
            panelId: panelId,
            sessionId: "codex-session-1",
            arguments: [
                "/usr/local/bin/codex",
                "--model",
                "gpt-5.4",
                "resume",
                "codex-session-1",
            ]
        )
        let firstFingerprint = TabManager.restorableAgentSnapshotFingerprint(
            try XCTUnwrap(firstIndex.snapshot(workspaceId: workspaceId, panelId: panelId))
        )

        let secondIndex = try makeRestorableAgentIndex(
            workspaceId: workspaceId,
            panelId: panelId,
            sessionId: "codex-session-2",
            arguments: [
                "/usr/local/bin/codex",
                "--model",
                "gpt-5.4-mini",
                "resume",
                "codex-session-2",
            ]
        )
        let secondFingerprint = TabManager.restorableAgentSnapshotFingerprint(
            try XCTUnwrap(secondIndex.snapshot(workspaceId: workspaceId, panelId: panelId))
        )

        XCTAssertNotEqual(baselineFingerprint, firstFingerprint)
        XCTAssertNotEqual(firstFingerprint, secondFingerprint)
    }

    func testRestorableAgentIndexSkipsHookRecordWithDeadRecordedPID() throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let index = try makeRestorableAgentIndex(
            workspaceId: workspaceId,
            panelId: panelId,
            sessionId: "codex-dead-pid-session",
            arguments: [
                "/usr/local/bin/codex",
                "--model",
                "gpt-5.4",
            ],
            pid: Int(Int32.max)
        )

        XCTAssertNil(index.snapshot(workspaceId: workspaceId, panelId: panelId))
    }

    func testResolvedWindowFramePrefersSavedDisplayIdentity() {
        let savedFrame = SessionRectSnapshot(x: 1_200, y: 100, width: 600, height: 400)
        let savedDisplay = SessionDisplaySnapshot(
            displayID: 2,
            frame: SessionRectSnapshot(x: 1_000, y: 0, width: 1_000, height: 800),
            visibleFrame: SessionRectSnapshot(x: 1_000, y: 0, width: 1_000, height: 800)
        )

        // Display 1 and 2 swapped horizontal positions between snapshot and restore.
        let display1 = AppDelegate.SessionDisplayGeometry(
            displayID: 1,
            frame: CGRect(x: 1_000, y: 0, width: 1_000, height: 800),
            visibleFrame: CGRect(x: 1_000, y: 0, width: 1_000, height: 800)
        )
        let display2 = AppDelegate.SessionDisplayGeometry(
            displayID: 2,
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )

        let restored = AppDelegate.resolvedWindowFrame(
            from: savedFrame,
            display: savedDisplay,
            availableDisplays: [display1, display2],
            fallbackDisplay: display1
        )

        XCTAssertNotNil(restored)
        guard let restored else { return }
        XCTAssertTrue(display2.visibleFrame.intersects(restored))
        XCTAssertFalse(display1.visibleFrame.intersects(restored))
        XCTAssertEqual(restored.width, 600, accuracy: 0.001)
        XCTAssertEqual(restored.height, 400, accuracy: 0.001)
        XCTAssertEqual(restored.minX, 200, accuracy: 0.001)
        XCTAssertEqual(restored.minY, 100, accuracy: 0.001)
    }

    func testResolvedWindowFrameKeepsIntersectingFrameWithoutDisplayMetadata() {
        let savedFrame = SessionRectSnapshot(x: 120, y: 80, width: 500, height: 350)
        let display = AppDelegate.SessionDisplayGeometry(
            displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )

        let restored = AppDelegate.resolvedWindowFrame(
            from: savedFrame,
            display: nil,
            availableDisplays: [display],
            fallbackDisplay: display
        )

        XCTAssertNotNil(restored)
        guard let restored else { return }
        XCTAssertEqual(restored.minX, 120, accuracy: 0.001)
        XCTAssertEqual(restored.minY, 80, accuracy: 0.001)
        XCTAssertEqual(restored.width, 500, accuracy: 0.001)
        XCTAssertEqual(restored.height, 350, accuracy: 0.001)
    }

    func testResolvedStartupPrimaryWindowFrameFallsBackToPersistedGeometryWhenPrimaryMissing() {
        let fallbackFrame = SessionRectSnapshot(x: 180, y: 140, width: 900, height: 640)
        let fallbackDisplay = SessionDisplaySnapshot(
            displayID: 1,
            frame: SessionRectSnapshot(x: 0, y: 0, width: 1_600, height: 1_000),
            visibleFrame: SessionRectSnapshot(x: 0, y: 0, width: 1_600, height: 1_000)
        )
        let display = AppDelegate.SessionDisplayGeometry(
            displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 1_600, height: 1_000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_600, height: 1_000)
        )

        let restored = AppDelegate.resolvedStartupPrimaryWindowFrame(
            primarySnapshot: nil,
            fallbackFrame: fallbackFrame,
            fallbackDisplaySnapshot: fallbackDisplay,
            availableDisplays: [display],
            fallbackDisplay: display
        )

        XCTAssertNotNil(restored)
        guard let restored else { return }
        XCTAssertEqual(restored.minX, 180, accuracy: 0.001)
        XCTAssertEqual(restored.minY, 140, accuracy: 0.001)
        XCTAssertEqual(restored.width, 900, accuracy: 0.001)
        XCTAssertEqual(restored.height, 640, accuracy: 0.001)
    }

    func testResolvedStartupPrimaryWindowFramePrefersPrimarySnapshotOverFallback() {
        let primarySnapshot = SessionWindowSnapshot(
            frame: SessionRectSnapshot(x: 220, y: 160, width: 980, height: 700),
            display: SessionDisplaySnapshot(
                displayID: 1,
                frame: SessionRectSnapshot(x: 0, y: 0, width: 1_600, height: 1_000),
                visibleFrame: SessionRectSnapshot(x: 0, y: 0, width: 1_600, height: 1_000)
            ),
            tabManager: SessionTabManagerSnapshot(selectedWorkspaceIndex: nil, workspaces: []),
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: 220)
        )
        let fallbackFrame = SessionRectSnapshot(x: 40, y: 30, width: 700, height: 500)
        let fallbackDisplay = SessionDisplaySnapshot(
            displayID: 1,
            frame: SessionRectSnapshot(x: 0, y: 0, width: 1_600, height: 1_000),
            visibleFrame: SessionRectSnapshot(x: 0, y: 0, width: 1_600, height: 1_000)
        )
        let display = AppDelegate.SessionDisplayGeometry(
            displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 1_600, height: 1_000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_600, height: 1_000)
        )

        let restored = AppDelegate.resolvedStartupPrimaryWindowFrame(
            primarySnapshot: primarySnapshot,
            fallbackFrame: fallbackFrame,
            fallbackDisplaySnapshot: fallbackDisplay,
            availableDisplays: [display],
            fallbackDisplay: display
        )

        XCTAssertNotNil(restored)
        guard let restored else { return }
        XCTAssertEqual(restored.minX, 220, accuracy: 0.001)
        XCTAssertEqual(restored.minY, 160, accuracy: 0.001)
        XCTAssertEqual(restored.width, 980, accuracy: 0.001)
        XCTAssertEqual(restored.height, 700, accuracy: 0.001)
    }

    func testDecodedPersistedWindowGeometryDataAcceptsCurrentSchema() throws {
        let data = try JSONEncoder().encode(
            AppDelegate.PersistedWindowGeometry(
                version: AppDelegate.persistedWindowGeometrySchemaVersion,
                frame: SessionRectSnapshot(x: 220, y: 160, width: 980, height: 700),
                display: SessionDisplaySnapshot(
                    displayID: 1,
                    frame: SessionRectSnapshot(x: 0, y: 0, width: 1_600, height: 1_000),
                    visibleFrame: SessionRectSnapshot(x: 0, y: 0, width: 1_600, height: 1_000)
                )
            )
        )

        let decoded = try XCTUnwrap(AppDelegate.decodedPersistedWindowGeometryData(data))
        XCTAssertEqual(decoded.version, AppDelegate.persistedWindowGeometrySchemaVersion)
        XCTAssertEqual(decoded.frame.x, 220, accuracy: 0.001)
        XCTAssertEqual(decoded.frame.y, 160, accuracy: 0.001)
        XCTAssertEqual(decoded.frame.width, 980, accuracy: 0.001)
        XCTAssertEqual(decoded.frame.height, 700, accuracy: 0.001)
        XCTAssertEqual(decoded.display?.displayID, 1)
    }

    func testDecodedPersistedWindowGeometryDataRejectsLegacyUnversionedPayload() throws {
        let data = try JSONEncoder().encode(
            LegacyPersistedWindowGeometry(
                frame: SessionRectSnapshot(x: 180, y: 140, width: 900, height: 640),
                display: SessionDisplaySnapshot(
                    displayID: 1,
                    frame: SessionRectSnapshot(x: 0, y: 0, width: 1_600, height: 1_000),
                    visibleFrame: SessionRectSnapshot(x: 0, y: 0, width: 1_600, height: 1_000)
                )
            )
        )

        XCTAssertNil(AppDelegate.decodedPersistedWindowGeometryData(data))
    }

    func testDecodedPersistedWindowGeometryDataRejectsDifferentSchemaVersion() throws {
        let data = try JSONEncoder().encode(
            AppDelegate.PersistedWindowGeometry(
                version: AppDelegate.persistedWindowGeometrySchemaVersion + 1,
                frame: SessionRectSnapshot(x: 220, y: 160, width: 980, height: 700),
                display: nil
            )
        )

        XCTAssertNil(AppDelegate.decodedPersistedWindowGeometryData(data))
    }

    func testResolvedWindowFrameCentersInFallbackDisplayWhenOffscreen() {
        let savedFrame = SessionRectSnapshot(x: 4_000, y: 4_000, width: 900, height: 700)
        let display = AppDelegate.SessionDisplayGeometry(
            displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )

        let restored = AppDelegate.resolvedWindowFrame(
            from: savedFrame,
            display: nil,
            availableDisplays: [display],
            fallbackDisplay: display
        )

        XCTAssertNotNil(restored)
        guard let restored else { return }
        XCTAssertTrue(display.visibleFrame.contains(restored))
        XCTAssertEqual(restored.minX, 50, accuracy: 0.001)
        XCTAssertEqual(restored.minY, 50, accuracy: 0.001)
        XCTAssertEqual(restored.width, 900, accuracy: 0.001)
        XCTAssertEqual(restored.height, 700, accuracy: 0.001)
    }

    func testResolvedWindowFramePreservesExactGeometryWhenDisplayIsUnchanged() {
        let savedFrame = SessionRectSnapshot(x: 1_303, y: -90, width: 1_280, height: 1_410)
        let savedDisplay = SessionDisplaySnapshot(
            displayID: 2,
            frame: SessionRectSnapshot(x: 0, y: 0, width: 2_560, height: 1_440),
            visibleFrame: SessionRectSnapshot(x: 0, y: 0, width: 2_560, height: 1_410)
        )
        let display = AppDelegate.SessionDisplayGeometry(
            displayID: 2,
            frame: CGRect(x: 0, y: 0, width: 2_560, height: 1_440),
            visibleFrame: CGRect(x: 0, y: 0, width: 2_560, height: 1_410)
        )

        let restored = AppDelegate.resolvedWindowFrame(
            from: savedFrame,
            display: savedDisplay,
            availableDisplays: [display],
            fallbackDisplay: display
        )

        XCTAssertNotNil(restored)
        guard let restored else { return }
        XCTAssertEqual(restored.minX, 1_303, accuracy: 0.001)
        XCTAssertEqual(restored.minY, -90, accuracy: 0.001)
        XCTAssertEqual(restored.width, 1_280, accuracy: 0.001)
        XCTAssertEqual(restored.height, 1_410, accuracy: 0.001)
    }

    func testResolvedWindowFramePreservesExactGeometryWhenDisplayChangesButWindowRemainsAccessible() {
        let savedFrame = SessionRectSnapshot(x: 1_100, y: -20, width: 1_280, height: 1_000)
        let savedDisplay = SessionDisplaySnapshot(
            displayID: 2,
            frame: SessionRectSnapshot(x: 0, y: 0, width: 2_560, height: 1_440),
            visibleFrame: SessionRectSnapshot(x: 0, y: 0, width: 2_560, height: 1_410)
        )
        let adjustedDisplay = AppDelegate.SessionDisplayGeometry(
            displayID: 2,
            frame: CGRect(x: 0, y: 0, width: 2_560, height: 1_440),
            visibleFrame: CGRect(x: 0, y: 40, width: 2_560, height: 1_360)
        )

        let restored = AppDelegate.resolvedWindowFrame(
            from: savedFrame,
            display: savedDisplay,
            availableDisplays: [adjustedDisplay],
            fallbackDisplay: adjustedDisplay
        )

        XCTAssertNotNil(restored)
        guard let restored else { return }
        XCTAssertEqual(restored.minX, 1_100, accuracy: 0.001)
        XCTAssertEqual(restored.minY, -20, accuracy: 0.001)
        XCTAssertEqual(restored.width, 1_280, accuracy: 0.001)
        XCTAssertEqual(restored.height, 1_000, accuracy: 0.001)
    }

    func testResolvedWindowFrameClampsWhenDisplayGeometryChangesEvenWithSameDisplayID() {
        let savedFrame = SessionRectSnapshot(x: 1_303, y: -90, width: 1_280, height: 1_410)
        let savedDisplay = SessionDisplaySnapshot(
            displayID: 2,
            frame: SessionRectSnapshot(x: 0, y: 0, width: 2_560, height: 1_440),
            visibleFrame: SessionRectSnapshot(x: 0, y: 0, width: 2_560, height: 1_410)
        )
        let resizedDisplay = AppDelegate.SessionDisplayGeometry(
            displayID: 2,
            frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_920, height: 1_050)
        )

        let restored = AppDelegate.resolvedWindowFrame(
            from: savedFrame,
            display: savedDisplay,
            availableDisplays: [resizedDisplay],
            fallbackDisplay: resizedDisplay
        )

        XCTAssertNotNil(restored)
        guard let restored else { return }
        XCTAssertTrue(resizedDisplay.visibleFrame.contains(restored))
        XCTAssertNotEqual(restored.minX, 1_303, "Changed display geometry should clamp/remap frame")
        XCTAssertNotEqual(restored.minY, -90, "Changed display geometry should clamp/remap frame")
    }

    func testResolvedSnapshotTerminalScrollbackPrefersCaptured() {
        let resolved = Workspace.resolvedSnapshotTerminalScrollback(
            capturedScrollback: "captured-value",
            fallbackScrollback: "fallback-value"
        )

        XCTAssertEqual(resolved, "captured-value")
    }

    func testResolvedSnapshotTerminalScrollbackFallsBackWhenCaptureMissing() {
        let resolved = Workspace.resolvedSnapshotTerminalScrollback(
            capturedScrollback: nil,
            fallbackScrollback: "fallback-value"
        )

        XCTAssertEqual(resolved, "fallback-value")
    }

    func testResolvedSnapshotTerminalScrollbackTruncatesFallback() {
        let oversizedFallback = String(
            repeating: "x",
            count: SessionPersistencePolicy.maxScrollbackCharactersPerTerminal + 37
        )
        let resolved = Workspace.resolvedSnapshotTerminalScrollback(
            capturedScrollback: nil,
            fallbackScrollback: oversizedFallback
        )

        XCTAssertEqual(
            resolved?.count,
            SessionPersistencePolicy.maxScrollbackCharactersPerTerminal
        )
    }

    func testResolvedSnapshotTerminalScrollbackSkipsFallbackWhenRestoreIsUnsafe() {
        let resolved = Workspace.resolvedSnapshotTerminalScrollback(
            capturedScrollback: nil,
            fallbackScrollback: "fallback-value",
            allowFallbackScrollback: false
        )

        XCTAssertNil(resolved)
    }

    func testRestorableAgentRestoreSuppressesSavedScrollbackReplay() {
        let agent = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "claude-session-123",
            workingDirectory: "/tmp/repo",
            launchCommand: nil
        )

        XCTAssertFalse(Workspace.shouldReplaySessionScrollback(restorableAgent: agent))
        XCTAssertTrue(Workspace.shouldReplaySessionScrollback(restorableAgent: nil))
    }

    @MainActor
    func testRestoredAgentAutoResumeClearsSnapshotWhenShellReturnsToPrompt() throws {
        let source = Workspace()
        let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
        let sourceIndex = try makeRestorableAgentIndex(
            workspaceId: source.id,
            panelId: sourcePanelId,
            sessionId: "codex-restored-session",
            arguments: [
                "/usr/local/bin/codex",
                "--model",
                "gpt-5.4",
            ]
        )
        let snapshot = source.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: sourceIndex
        )

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)

        restored.updatePanelShellActivityState(panelId: restoredPanelId, state: .commandRunning)
        let autoResumeSnapshot = restored.sessionSnapshot(includeScrollback: false)
        XCTAssertEqual(autoResumeSnapshot.panels.first?.terminal?.agent?.sessionId, "codex-restored-session")

        restored.updatePanelShellActivityState(panelId: restoredPanelId, state: .promptIdle)
        let exitedAgentSnapshot = restored.sessionSnapshot(includeScrollback: false)
        XCTAssertNil(exitedAgentSnapshot.panels.first?.terminal?.agent)
    }

    @MainActor
    func testRestoredAntigravityAgentAutoResumeUsesConversationCommand() throws {
        let source = Workspace()
        let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
        let sourceIndex = try makeRestorableAgentIndex(
            kind: .antigravity,
            workspaceId: source.id,
            panelId: sourcePanelId,
            sessionId: "antigravity-conversation-123",
            arguments: [
                "/usr/local/bin/agy",
                "--conversation",
                "old-conversation",
                "--sandbox",
                "danger-full-access",
                "startup prompt should not replay",
            ],
            environment: [:]
        )
        let snapshot = source.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: sourceIndex
        )

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
        restored.updatePanelShellActivityState(panelId: restoredPanelId, state: .commandRunning)

        let agent = try XCTUnwrap(
            restored.sessionSnapshot(includeScrollback: false).panels.first?.terminal?.agent
        )
        XCTAssertEqual(agent.kind, .custom("antigravity"))
        XCTAssertEqual(agent.sessionId, "antigravity-conversation-123")
        XCTAssertEqual(
            agent.resumeCommand,
            "cd -- '/tmp/repo' 2>/dev/null || [ ! -d '/tmp/repo' ] && '/usr/local/bin/agy' '--conversation' 'antigravity-conversation-123' '--sandbox' 'danger-full-access'"
        )
    }

    @MainActor
    func testRestoredAgentWithoutResumeCommandInvalidatesOnFirstCommand() throws {
        let source = Workspace()
        let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
        let sourceIndex = try makeRestorableAgentIndex(
            kind: .claude,
            workspaceId: source.id,
            panelId: sourcePanelId,
            sessionId: "claude-print-session",
            arguments: [
                "/usr/local/bin/claude",
                "--print",
            ]
        )
        let snapshot = source.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: sourceIndex
        )

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
        XCTAssertNil(restored.sessionSnapshot(includeScrollback: false).panels.first?.terminal?.agent?.resumeCommand)

        restored.updatePanelShellActivityState(panelId: restoredPanelId, state: .commandRunning)
        let userCommandSnapshot = restored.sessionSnapshot(includeScrollback: false)
        XCTAssertNil(userCommandSnapshot.panels.first?.terminal?.agent)
    }

    @MainActor
    func testPruneSurfaceMetadataRemovesRestoredAgentBookkeeping() throws {
        let source = Workspace()
        let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
        let sourceIndex = try makeRestorableAgentIndex(
            workspaceId: source.id,
            panelId: sourcePanelId,
            sessionId: "codex-prune-pending-session",
            arguments: [
                "/usr/local/bin/codex",
                "--model",
                "gpt-5.4",
            ]
        )
        let snapshot = source.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: sourceIndex
        )

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
        restored.pruneSurfaceMetadata(validSurfaceIds: [])

        let postPruneIndex = try makeRestorableAgentIndex(
            workspaceId: restored.id,
            panelId: restoredPanelId,
            sessionId: "codex-post-prune-session",
            arguments: [
                "/usr/local/bin/codex",
                "--model",
                "gpt-5.4-mini",
            ]
        )
        let postPruneSnapshot = restored.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: postPruneIndex
        )
        XCTAssertEqual(
            postPruneSnapshot.panels.first?.terminal?.agent?.sessionId,
            "codex-post-prune-session"
        )

        restored.updatePanelShellActivityState(panelId: restoredPanelId, state: .promptIdle)
        restored.updatePanelShellActivityState(panelId: restoredPanelId, state: .commandRunning)
        let userCommandSnapshot = restored.sessionSnapshot(includeScrollback: false)
        XCTAssertNil(userCommandSnapshot.panels.first?.terminal?.agent)

        let staleWorkspace = Workspace()
        let stalePanelId = try XCTUnwrap(staleWorkspace.focusedPanelId)
        let staleIndex = try makeRestorableAgentIndex(
            workspaceId: staleWorkspace.id,
            panelId: stalePanelId,
            sessionId: "codex-prune-invalidated-session",
            arguments: [
                "/usr/local/bin/codex",
                "--model",
                "gpt-5.4",
            ]
        )
        _ = staleWorkspace.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: staleIndex
        )

        staleWorkspace.updatePanelShellActivityState(panelId: stalePanelId, state: .promptIdle)
        staleWorkspace.updatePanelShellActivityState(panelId: stalePanelId, state: .commandRunning)
        let staleSnapshot = staleWorkspace.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: staleIndex
        )
        XCTAssertNil(staleSnapshot.panels.first?.terminal?.agent)

        staleWorkspace.pruneSurfaceMetadata(validSurfaceIds: [])
        let acceptedSnapshot = staleWorkspace.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: staleIndex
        )
        XCTAssertEqual(
            acceptedSnapshot.panels.first?.terminal?.agent?.sessionId,
            "codex-prune-invalidated-session"
        )
    }

    @MainActor
    func testUserCommandInvalidatesStaleRestoredAgentForAllProviders() throws {
        let scenarios: [(kind: RestorableAgentKind, arguments: [String])] = [
            (
                .claude,
                [
                    "/usr/local/bin/claude",
                    "--model",
                    "sonnet",
                ]
            ),
            (
                .codex,
                [
                    "/usr/local/bin/codex",
                    "--model",
                    "gpt-5.4",
                ]
            ),
            (
                .pi,
                [
                    "/usr/local/bin/pi",
                    "--model",
                    "anthropic/claude-sonnet-4-5",
                ]
            ),
            (
                .cursor,
                [
                    "/usr/local/bin/cursor-agent",
                    "--model",
                    "gpt-5.4",
                ]
            ),
            (
                .gemini,
                [
                    "/usr/local/bin/gemini",
                    "--model",
                    "gemini-2.5-pro",
                ]
            ),
            (
                .kiro,
                [
                    "/usr/local/bin/kiro-cli",
                    "chat",
                    "--agent",
                    "cmux",
                ]
            ),
            (
                .opencode,
                [
                    "/usr/local/bin/opencode",
                    "--model",
                    "anthropic/claude-sonnet-4-5",
                ]
            ),
            (
                .rovodev,
                [
                    "/usr/local/bin/acli",
                    "rovodev",
                    "run",
                    "--yolo",
                ]
            ),
            (.hermesAgent, ["/usr/local/bin/hermes", "--tui", "--model", "anthropic/claude-sonnet-4.6"]),
            (
                .copilot,
                [
                    "/usr/local/bin/copilot",
                    "--model",
                    "gpt-5.4",
                ]
            ),
            (
                .codebuddy,
                [
                    "/usr/local/bin/codebuddy",
                    "--model",
                    "gpt-5.4",
                ]
            ),
            (
                .factory,
                [
                    "/usr/local/bin/droid",
                    "--cwd",
                    "/tmp/repo",
                ]
            ),
            (
                .qoder,
                [
                    "/usr/local/bin/qodercli",
                    "--model",
                    "gemini-2.5-pro",
                ]
            ),
        ]

        for scenario in scenarios {
            let workspace = Workspace()
            let panelId = try XCTUnwrap(workspace.focusedPanelId)
            let staleIndex = try makeRestorableAgentIndex(
                kind: scenario.kind,
                workspaceId: workspace.id,
                panelId: panelId,
                sessionId: "\(scenario.kind.rawValue)-old-session",
                arguments: scenario.arguments
            )
            let initialSnapshot = workspace.sessionSnapshot(
                includeScrollback: false,
                restorableAgentIndex: staleIndex
            )
            let expectedKind: RestorableAgentKind = scenario.kind == .pi ? .custom("pi") : scenario.kind
            XCTAssertEqual(initialSnapshot.panels.first?.terminal?.agent?.kind, expectedKind)

            workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)
            workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)

            let staleSnapshot = workspace.sessionSnapshot(
                includeScrollback: false,
                restorableAgentIndex: staleIndex
            )
            XCTAssertNil(staleSnapshot.panels.first?.terminal?.agent, expectedKind.rawValue)
        }
    }

    @MainActor
    func testUserCommandInvalidatesStaleRestoredAgentButAcceptsNewHookFlags() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let staleIndex = try makeRestorableAgentIndex(
            workspaceId: workspace.id,
            panelId: panelId,
            sessionId: "codex-old-session",
            arguments: [
                "/usr/local/bin/codex",
                "--model",
                "gpt-5.4",
            ]
        )
        let initialSnapshot = workspace.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: staleIndex
        )
        XCTAssertEqual(initialSnapshot.panels.first?.terminal?.agent?.sessionId, "codex-old-session")

        workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)
        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)

        let staleSnapshot = workspace.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: staleIndex
        )
        XCTAssertNil(staleSnapshot.panels.first?.terminal?.agent)

        let newIndex = try makeRestorableAgentIndex(
            workspaceId: workspace.id,
            panelId: panelId,
            sessionId: "codex-new-session",
            arguments: [
                "/usr/local/bin/codex",
                "--model",
                "gpt-5.4-mini",
                "--sandbox",
                "danger-full-access",
            ]
        )
        let newSnapshot = workspace.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: newIndex
        )
        let newAgent = try XCTUnwrap(newSnapshot.panels.first?.terminal?.agent)
        XCTAssertEqual(newAgent.sessionId, "codex-new-session")
        XCTAssertEqual(
            newAgent.launchCommand?.arguments,
            [
                "/usr/local/bin/codex",
                "--model",
                "gpt-5.4-mini",
                "--sandbox",
                "danger-full-access",
            ]
        )
    }

    @MainActor
    func testObservedRunningAgentInvalidatesWhenShellReturnsToPrompt() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)

        let runningIndex = try makeRestorableAgentIndex(
            workspaceId: workspace.id,
            panelId: panelId,
            sessionId: "codex-running-session",
            arguments: [
                "/usr/local/bin/codex",
                "--model",
                "gpt-5.4",
            ]
        )
        let runningSnapshot = workspace.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: runningIndex
        )
        XCTAssertEqual(runningSnapshot.panels.first?.terminal?.agent?.sessionId, "codex-running-session")

        workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)
        let idleSnapshot = workspace.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: runningIndex
        )
        XCTAssertNil(idleSnapshot.panels.first?.terminal?.agent)
    }

    private func makeRestorableAgentIndex(
        kind: RestorableAgentKind = .codex,
        workspaceId: UUID,
        panelId: UUID,
        sessionId: String,
        arguments: [String],
        launcher: String? = nil,
        executablePath: String? = nil,
        environment: [String: String]? = nil,
        pid: Int? = nil
    ) throws -> RestorableAgentSessionIndex {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-hook-store-\(UUID().uuidString)", isDirectory: true)
        let storeURL = kind.hookStoreFileURL(homeDirectory: home.path)
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let resolvedEnvironment: [String: String]
        if let environment {
            resolvedEnvironment = environment
        } else {
            switch kind {
            case .claude:
                resolvedEnvironment = ["CLAUDE_CONFIG_DIR": "/tmp/claude"]
            case .codex:
                resolvedEnvironment = ["CODEX_HOME": "/tmp/codex"]
            case .grok:
                resolvedEnvironment = ["GROK_HOME": "/tmp/grok"]
            case .pi:
                resolvedEnvironment = ["PI_CODING_AGENT_DIR": "/tmp/pi"]
            case .amp:
                resolvedEnvironment = ["AMP_SETTINGS_FILE": "/tmp/amp-settings.json"]
            case .cursor, .rovodev, .factory, .custom:
                resolvedEnvironment = [:]
            case .gemini:
                resolvedEnvironment = ["GEMINI_CLI_HOME": "/tmp/gemini"]
            case .kiro:
                resolvedEnvironment = ["KIRO_HOME": "/tmp/kiro"]
            case .antigravity:
                resolvedEnvironment = ["GEMINI_CLI_HOME": "/tmp/gemini"]
            case .opencode:
                resolvedEnvironment = ["OPENCODE_CONFIG_DIR": "/tmp/opencode"]
            case .hermesAgent:
                resolvedEnvironment = ["HERMES_HOME": "/tmp/hermes"]
            case .copilot:
                resolvedEnvironment = ["COPILOT_HOME": "/tmp/copilot"]
            case .codebuddy:
                resolvedEnvironment = ["CODEBUDDY_CONFIG_DIR": "/tmp/codebuddy"]
            case .qoder:
                resolvedEnvironment = ["QODER_CONFIG_DIR": "/tmp/qoder"]
            }
        }
        let resolvedExecutablePath = executablePath ?? arguments.first ?? "/usr/local/bin/\(kind.rawValue)"
        let resolvedLauncher = launcher ?? kind.rawValue

        var sessionRecord: [String: Any] = [
            "sessionId": sessionId,
            "workspaceId": workspaceId.uuidString,
            "surfaceId": panelId.uuidString,
            "cwd": "/tmp/repo",
            "updatedAt": Date.now.timeIntervalSince1970,
            "launchCommand": [
                "launcher": resolvedLauncher,
                "executablePath": resolvedExecutablePath,
                "arguments": arguments,
                "workingDirectory": "/tmp/repo",
                "environment": resolvedEnvironment,
                "capturedAt": Date.now.timeIntervalSince1970,
                "source": "process",
            ],
        ]
        if kind == .claude {
            let transcriptURL = home.appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
            try #"{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]}}"#
                .write(to: transcriptURL, atomically: true, encoding: .utf8)
            sessionRecord["transcriptPath"] = transcriptURL.path
        }
        if let pid {
            sessionRecord["pid"] = pid
        }

        let jsonObject: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: sessionRecord,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted])
        try data.write(to: storeURL, options: .atomic)

        return RestorableAgentSessionIndex.load(homeDirectory: home.path)
    }

    private func makeSnapshot(version: Int) -> AppSessionSnapshot {
        let workspace = SessionWorkspaceSnapshot(
            processTitle: "Terminal",
            customTitle: "Restored",
            customColor: nil,
            isPinned: true,
            currentDirectory: "/tmp",
            focusedPanelId: nil,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
            panels: [],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil
        )

        let tabManager = SessionTabManagerSnapshot(
            selectedWorkspaceIndex: 0,
            workspaces: [workspace]
        )

        let window = SessionWindowSnapshot(
            frame: SessionRectSnapshot(x: 10, y: 20, width: 900, height: 700),
            display: SessionDisplaySnapshot(
                displayID: 42,
                frame: SessionRectSnapshot(x: 0, y: 0, width: 1920, height: 1200),
                visibleFrame: SessionRectSnapshot(x: 0, y: 25, width: 1920, height: 1175)
            ),
            tabManager: tabManager,
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: 240)
        )

        return AppSessionSnapshot(
            version: version,
            createdAt: Date().timeIntervalSince1970,
            windows: [window]
        )
    }

    private func fileNumber(for fileURL: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        return try XCTUnwrap(attributes[.systemFileNumber] as? Int)
    }
}

final class SocketListenerAcceptPolicyTests: XCTestCase {
    func testClaudeResumeCommandRoutesThroughWrapperInsteadOfCapturedRealBinary() {
        // The captured launch executable is the real claude binary
        // (CMUX_AGENT_LAUNCH_EXECUTABLE). Resuming with it directly bypasses
        // cmux's `claude` wrapper, which is what injects the hooks, so resumed
        // sessions silently lost SessionStart/Stop/Notification. Resume must use
        // the bare `claude` wrapper. https://github.com/manaflow-ai/cmux/issues/5427
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "claude-session-123",
            workingDirectory: "/tmp/cmux project",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/opt/Claude Code/bin/claude",
                arguments: [
                    "/opt/Claude Code/bin/claude",
                    "--model",
                    "sonnet",
                    "--permission-mode",
                    "auto"
                ],
                workingDirectory: "/tmp/cmux project",
                environment: ["CLAUDE_CONFIG_DIR": "/tmp/claude config"],
                capturedAt: 123,
                source: "environment"
            )
        )

        XCTAssertEqual(
            snapshot.resumeCommand,
            "cd -- '/tmp/cmux project' 2>/dev/null || [ ! -d '/tmp/cmux project' ] && /bin/sh -c "
                + shellQuotedForTest("'env' 'CLAUDE_CONFIG_DIR=/tmp/claude config' 'CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV=1' 'CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS=CLAUDE_CONFIG_DIR' \"$([ -x \"${CMUX_CLAUDE_WRAPPER_SHIM:-}\" ] && printf '%s' \"$CMUX_CLAUDE_WRAPPER_SHIM\" || printf claude)\" '--resume' 'claude-session-123' '--model' 'sonnet' '--permission-mode' 'auto'")
        )
        // The captured real-binary path must not survive: it would bypass the wrapper.
        XCTAssertFalse(snapshot.resumeCommand?.contains("/opt/Claude Code/bin/claude") ?? true)
    }

    func testClaudeForkCommandRoutesThroughWrapperInsteadOfCapturedRealBinary() throws {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "claude-session-123",
            workingDirectory: "/tmp/cmux project",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/opt/Claude Code/bin/claude",
                arguments: [
                    "/opt/Claude Code/bin/claude",
                    "--model",
                    "sonnet",
                    "--settings",
                    #"{"hooks":{"SessionStart":[{"hooks":[{"command":"cmux claude-hook session-start"}]}]}}"#,
                    "--session-id",
                    "old-session"
                ],
                workingDirectory: "/tmp/cmux project",
                environment: ["CLAUDE_CONFIG_DIR": "/tmp/claude config"],
                capturedAt: 123,
                source: "environment"
            )
        )

        // Fork mirrors resume: route through the `claude` wrapper (so hooks fire),
        // drop the captured session selectors and the stale hook --settings.
        // https://github.com/manaflow-ai/cmux/issues/5427
        let command = try XCTUnwrap(snapshot.forkCommand)
        XCTAssertTrue(
            command.contains(
                posixEscapedForTest(AgentResumeArgv.claudeWrapperShellExecutableToken)
                    + " '\\''--resume'\\'' '\\''claude-session-123'\\'' '\\''--fork-session'\\''"
            ),
            command
        )
        XCTAssertFalse(command.contains("/opt/Claude Code/bin/claude"), command)
        XCTAssertFalse(command.contains("cmux claude-hook session-start"), command)
        XCTAssertFalse(command.contains("old-session"), command)
    }

    /// Regression for https://github.com/manaflow-ai/cmux/issues/5639.
    ///
    /// #5430 fixed the resume *argv string* (bare `claude`) but the close-&-reopen
    /// restore launcher runs the resumed agent in a fresh `$SHELL -lic` login shell
    /// where cmux's shell integration (the `claude()` function + per-surface PATH shim)
    /// is NOT active, and the command is `env … claude …` — `env` resolves `claude`
    /// via `execvp`, bypassing any shell function. So bare `claude` resolved to the
    /// user's *real* binary, the cmux wrapper was bypassed, no hook `--settings` was
    /// injected, and SessionStart/Stop/Notification stayed dead on resume.
    ///
    /// Unlike #5430's tests, this asserts the EXECUTED resume command — it runs the
    /// real `resumeCommand` through `zsh -lic` (exactly what the restore launcher does)
    /// inside a hermetic sandbox whose user login profile clobbers `PATH` and defines a
    /// `claude` function (the conditions that defeat PATH-shim / shell-function fixes),
    /// and asserts the launched invocation routed through the cmux wrapper (its injected
    /// `--settings`), proving wrapper resolution at the shell layer, not just the argv.
    func testClaudeResumeCommandExecutesThroughWrapperInsideLoginShellLauncher() throws {
        let zshURL = URL(fileURLWithPath: "/bin/zsh")
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: zshURL.path),
            "/bin/zsh is required to exercise the $SHELL -lic restore launcher"
        )

        let fileManager = FileManager.default
        let sandbox = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-5639-\(UUID().uuidString)", isDirectory: true)
        let shimDir = sandbox.appendingPathComponent("cmux-cli-shims", isDirectory: true)
        let realBinDir = sandbox.appendingPathComponent("realbin", isDirectory: true)
        let userHome = sandbox.appendingPathComponent("home", isDirectory: true)
        for dir in [shimDir, realBinDir, userHome] {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? fileManager.removeItem(at: sandbox) }

        let recordURL = sandbox.appendingPathComponent("record.txt", isDirectory: false)
        let wrapperURL = sandbox.appendingPathComponent("cmux-claude-wrapper", isDirectory: false)
        let shimURL = shimDir.appendingPathComponent("claude", isDirectory: false)
        let realClaudeURL = realBinDir.appendingPathComponent("claude", isDirectory: false)

        func writeExecutable(_ url: URL, _ contents: String) throws {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        // Stand-in for cmux-claude-wrapper: re-inject the hook --settings on --resume
        // (as the real wrapper does), then record the final invocation.
        try writeExecutable(wrapperURL, """
        #!/usr/bin/env bash
        set -- "$@"
        for arg in "$@"; do
          if [[ "$arg" == "--resume" || "$arg" == "-r" ]]; then
            set -- --settings CMUX_HOOKS_JSON "$@"
            break
          fi
        done
        printf 'wrapper %s\\n' "$*" > \(shellQuotedForTest(recordURL.path))
        """)
        // Per-surface shim that cmux installs and points CMUX_CLAUDE_WRAPPER_SHIM at.
        try writeExecutable(shimURL, """
        #!/usr/bin/env bash
        exec \(shellQuotedForTest(wrapperURL.path)) "$@"
        """)
        // The user's "real" claude binary: NO hook injection. If the resume command
        // reaches this instead of the wrapper, hooks are lost (the bug).
        try writeExecutable(realClaudeURL, """
        #!/usr/bin/env bash
        printf 'real %s\\n' "$*" > \(shellQuotedForTest(recordURL.path))
        """)
        // Hostile login profile: rebuild PATH (dropping any inherited shim dir) and
        // shadow claude with a user function — both would defeat integration-based fixes.
        try (
            "export PATH=\(shellQuotedForTest(realBinDir.path)):/usr/bin:/bin\n"
                + "claude() { command \(shellQuotedForTest(realClaudeURL.path)) \"$@\"; }\n"
        ).write(to: userHome.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        try "".write(to: userHome.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
        try "".write(to: userHome.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)

        let snapshot = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "claude-session-123",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/opt/Claude Code/bin/claude",
                arguments: [
                    "/opt/Claude Code/bin/claude",
                    "--model",
                    "sonnet"
                ],
                workingDirectory: nil,
                environment: ["CLAUDE_CONFIG_DIR": "/tmp/claude config"],
                capturedAt: 123,
                source: "environment"
            )
        )
        let resumeCommand = try XCTUnwrap(snapshot.resumeCommand)

        // Run the resume command exactly as the restore launcher does: `$SHELL -lic <cmd>`.
        let process = Process()
        process.executableURL = zshURL
        process.arguments = ["-lic", resumeCommand]
        var environment = ["HOME": userHome.path, "ZDOTDIR": userHome.path]
        // CMUX_CLAUDE_WRAPPER_SHIM is a managed terminal env var inherited by the -lic shell.
        environment["CMUX_CLAUDE_WRAPPER_SHIM"] = shimURL.path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try runWithBoundedWait(process, shellDescription: "zsh -lic")

        let recorded = (try? String(contentsOf: recordURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(
            recorded.contains("--settings"),
            "Resumed claude must route through the cmux wrapper (which injects the hook --settings). Recorded invocation: \(recorded.isEmpty ? "<none>" : recorded)"
        )
        XCTAssertTrue(
            recorded.hasPrefix("wrapper "),
            "Resume must exec the cmux wrapper, not the user's real claude binary. Recorded invocation: \(recorded.isEmpty ? "<none>" : recorded)"
        )
    }

    private func shellQuotedForTest(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func codexRetryWrappedForTest(_ command: String) -> String {
        CodexResumeRetryShell().wrappedCommand(command, quote: shellQuotedForTest)
    }

    /// The wrapper token as it appears inside a `/bin/sh -c '…'` wrapped command
    /// (its single quotes escaped by the POSIX `'\''` dance, without outer quotes).
    private func posixEscapedForTest(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\\''")
    }

    /// Regression: the rendered claude resume command must parse in NON-POSIX login shells.
    ///
    /// The restore launcher dispatches the resume command through the user's `$SHELL`
    /// (`TerminalStartupReturnShellScript.commandThenReturnLines` runs
    /// `"$_cmux_resume_shell" -c <command>` for its `csh|tcsh` branch), and the
    /// session-index resume command is typed into — and copy-pasted into — the user's
    /// interactive shell. tcsh has no `${VAR:-fallback}` parameter expansion
    /// ("Bad : modifier in $"), so a raw POSIX-only wrapper token makes the whole resume
    /// command fail to parse and claude never launches, even though the same string works
    /// under `zsh -lic`. https://github.com/manaflow-ai/cmux/issues/5639
    func testClaudeResumeCommandExecutesThroughWrapperInsideTcshLauncher() throws {
        let tcshURL = URL(fileURLWithPath: "/bin/tcsh")
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: tcshURL.path),
            "/bin/tcsh is required to exercise the csh|tcsh restore-launcher dispatch"
        )

        let sandbox = try makeClaudeResumeWrapperShimSandbox()
        defer { sandbox.removeSandbox() }
        // Hostile tcsh profile: rebuild PATH (dropping any inherited shim dir) and alias
        // claude to the user's real binary — the same conditions the zsh test exercises.
        try (
            "set path = (\(shellQuotedForTest(sandbox.realBinDirectoryURL.path)) /usr/bin /bin)\n"
                + "alias claude \(shellQuotedForTest(sandbox.realClaudeURL.path))\n"
        ).write(to: sandbox.homeURL.appendingPathComponent(".tcshrc"), atomically: true, encoding: .utf8)

        // No working directory: keeps the command free of the POSIX `{ cd …; } &&` guard
        // (csh/tcsh cannot parse that prefix with or without this fix, a pre-existing
        // limitation shared by every agent kind) so the assertion isolates the claude
        // executable token itself.
        let snapshot = Self.makeClaudeRestorableSnapshot(workingDirectory: nil)
        let resumeCommand = try XCTUnwrap(snapshot.resumeCommand)

        let recorded = try runClaudeResumeCommand(
            resumeCommand,
            shellURL: tcshURL,
            arguments: ["-c"],
            sandbox: sandbox
        )
        XCTAssertTrue(
            recorded.hasPrefix("wrapper "),
            "tcsh-dispatched resume must parse and exec the cmux wrapper. Recorded invocation: \(recorded.isEmpty ? "<none>" : recorded)"
        )
        XCTAssertTrue(
            recorded.contains("--settings"),
            "tcsh-dispatched resume must re-inject the hook --settings via the wrapper. Recorded invocation: \(recorded.isEmpty ? "<none>" : recorded)"
        )
    }

    /// Regression: fish rejects `${…}` outright ("${ is not a valid variable"), and fish
    /// is a shipped cmux integration (`Resources/shell-integration/fish/`). The restore
    /// launcher's `*)` branch dispatches `"$_cmux_resume_shell" -c <command>` for fish
    /// logins, so a POSIX-only wrapper token regresses fish users from working resume to
    /// a hard parse error. Uses a working directory so the brace-free cwd guard
    /// (`cd … || [ ! -d … ] && …`, https://github.com/manaflow-ai/cmux/issues/6285) is
    /// exercised too — older fish rejects the POSIX `{ …; }` grouping the guard used to
    /// emit. https://github.com/manaflow-ai/cmux/issues/5639
    func testClaudeResumeCommandExecutesThroughWrapperInsideFishLauncher() throws {
        let fishURL = ["/usr/local/bin/fish", "/opt/homebrew/bin/fish", "/usr/bin/fish"]
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        guard let fishURL else {
            throw XCTSkip("fish is not installed; install fish to exercise the fish restore-launcher dispatch")
        }

        let sandbox = try makeClaudeResumeWrapperShimSandbox()
        defer { sandbox.removeSandbox() }
        let fishConfigDir = sandbox.homeURL.appendingPathComponent(".config/fish", isDirectory: true)
        try FileManager.default.createDirectory(at: fishConfigDir, withIntermediateDirectories: true)
        // Hostile fish config: rebuild PATH and shadow claude with a fish function.
        try (
            "set -gx PATH \(shellQuotedForTest(sandbox.realBinDirectoryURL.path)) /usr/bin /bin\n"
                + "function claude\n    \(shellQuotedForTest(sandbox.realClaudeURL.path)) $argv\nend\n"
        ).write(to: fishConfigDir.appendingPathComponent("config.fish"), atomically: true, encoding: .utf8)

        let snapshot = Self.makeClaudeRestorableSnapshot(workingDirectory: sandbox.sandboxURL.path)
        let resumeCommand = try XCTUnwrap(snapshot.resumeCommand)

        let recorded = try runClaudeResumeCommand(
            resumeCommand,
            shellURL: fishURL,
            arguments: ["-c"],
            sandbox: sandbox
        )
        XCTAssertTrue(
            recorded.hasPrefix("wrapper "),
            "fish-dispatched resume must parse and exec the cmux wrapper. Recorded invocation: \(recorded.isEmpty ? "<none>" : recorded)"
        )
        XCTAssertTrue(
            recorded.contains("--settings"),
            "fish-dispatched resume must re-inject the hook --settings via the wrapper. Recorded invocation: \(recorded.isEmpty ? "<none>" : recorded)"
        )
    }

    /// Regression for the stale-shim fallback: `CMUX_CLAUDE_WRAPPER_SHIM` can outlive
    /// its file (macOS reaps idle temporary-directory contents after ~3 days), and bare
    /// `${VAR:-claude}` parameter expansion would exec the dead path and hard-fail
    /// resume with "No such file or directory" — worse than the pre-#5639 behavior,
    /// which degraded to the PATH-resolved binary. The executability guard in the
    /// wrapper token must keep that graceful degradation: hooks are lost, resume works.
    func testClaudeResumeCommandFallsBackToPathClaudeWhenShimFileIsStale() throws {
        let zshURL = URL(fileURLWithPath: "/bin/zsh")
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: zshURL.path),
            "/bin/zsh is required to exercise the $SHELL -lic restore launcher"
        )

        let sandbox = try makeClaudeResumeWrapperShimSandbox()
        defer { sandbox.removeSandbox() }
        try ("export PATH=" + shellQuotedForTest(sandbox.realBinDirectoryURL.path) + ":/usr/bin:/bin\n")
            .write(to: sandbox.homeURL.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        try "".write(to: sandbox.homeURL.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
        try "".write(to: sandbox.homeURL.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)

        let snapshot = Self.makeClaudeRestorableSnapshot(workingDirectory: nil)
        let resumeCommand = try XCTUnwrap(snapshot.resumeCommand)

        let reapedShimPath = sandbox.sandboxURL
            .appendingPathComponent("reaped", isDirectory: true)
            .appendingPathComponent("claude", isDirectory: false).path
        let recorded = try runClaudeResumeCommand(
            resumeCommand,
            shellURL: zshURL,
            arguments: ["-lic"],
            sandbox: sandbox,
            environmentOverrides: [
                "ZDOTDIR": sandbox.homeURL.path,
                "CMUX_CLAUDE_WRAPPER_SHIM": reapedShimPath
            ]
        )
        XCTAssertTrue(
            recorded.hasPrefix("real "),
            "A stale shim path must degrade to the PATH-resolved claude binary, not hard-fail resume. Recorded invocation: \(recorded.isEmpty ? "<none>" : recorded)"
        )
        XCTAssertFalse(
            recorded.contains("--settings"),
            "The PATH fallback runs the real binary without wrapper hook injection. Recorded invocation: \(recorded)"
        )
    }

    private struct ClaudeResumeWrapperShimSandbox {
        let sandboxURL: URL
        let homeURL: URL
        let realBinDirectoryURL: URL
        let realClaudeURL: URL
        let shimURL: URL
        let recordURL: URL

        func removeSandbox() {
            try? FileManager.default.removeItem(at: sandboxURL)
        }
    }

    /// Builds the hermetic wrapper/shim/real-claude sandbox shared by the non-POSIX
    /// restore-launcher regression tests: a recording stand-in for `cmux-claude-wrapper`
    /// (re-injects the hook `--settings` on `--resume`, as the real wrapper does), the
    /// per-surface shim that `CMUX_CLAUDE_WRAPPER_SHIM` points at, and a hook-less "real"
    /// claude that records when the wrapper was bypassed.
    private func makeClaudeResumeWrapperShimSandbox() throws -> ClaudeResumeWrapperShimSandbox {
        let fileManager = FileManager.default
        let sandbox = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-5639-\(UUID().uuidString)", isDirectory: true)
        let shimDir = sandbox.appendingPathComponent("cmux-cli-shims", isDirectory: true)
        let realBinDir = sandbox.appendingPathComponent("realbin", isDirectory: true)
        let userHome = sandbox.appendingPathComponent("home", isDirectory: true)
        for dir in [shimDir, realBinDir, userHome] {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let recordURL = sandbox.appendingPathComponent("record.txt", isDirectory: false)
        let wrapperURL = sandbox.appendingPathComponent("cmux-claude-wrapper", isDirectory: false)
        let shimURL = shimDir.appendingPathComponent("claude", isDirectory: false)
        let realClaudeURL = realBinDir.appendingPathComponent("claude", isDirectory: false)

        func writeExecutable(_ url: URL, _ contents: String) throws {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        try writeExecutable(wrapperURL, """
        #!/usr/bin/env bash
        set -- "$@"
        for arg in "$@"; do
          if [[ "$arg" == "--resume" || "$arg" == "-r" ]]; then
            set -- --settings CMUX_HOOKS_JSON "$@"
            break
          fi
        done
        printf 'wrapper %s\\n' "$*" > \(shellQuotedForTest(recordURL.path))
        """)
        try writeExecutable(shimURL, """
        #!/usr/bin/env bash
        exec \(shellQuotedForTest(wrapperURL.path)) "$@"
        """)
        try writeExecutable(realClaudeURL, """
        #!/usr/bin/env bash
        printf 'real %s\\n' "$*" > \(shellQuotedForTest(recordURL.path))
        """)

        return ClaudeResumeWrapperShimSandbox(
            sandboxURL: sandbox,
            homeURL: userHome,
            realBinDirectoryURL: realBinDir,
            realClaudeURL: realClaudeURL,
            shimURL: shimURL,
            recordURL: recordURL
        )
    }

    private static func makeClaudeRestorableSnapshot(workingDirectory: String?) -> SessionRestorableAgentSnapshot {
        SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "claude-session-123",
            workingDirectory: workingDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/opt/Claude Code/bin/claude",
                arguments: [
                    "/opt/Claude Code/bin/claude",
                    "--model",
                    "sonnet"
                ],
                workingDirectory: workingDirectory,
                environment: ["CLAUDE_CONFIG_DIR": "/tmp/claude config"],
                capturedAt: 123,
                source: "environment"
            )
        )
    }

    /// Runs `resumeCommand` through the given shell exactly as the restore launcher's
    /// dispatch line does, with only the managed env the launcher guarantees (`HOME` for
    /// profile sourcing, `CMUX_CLAUDE_WRAPPER_SHIM` from the managed terminal env).
    private func runClaudeResumeCommand(
        _ resumeCommand: String,
        shellURL: URL,
        arguments: [String],
        sandbox: ClaudeResumeWrapperShimSandbox,
        environmentOverrides: [String: String] = [:]
    ) throws -> String {
        let process = Process()
        process.executableURL = shellURL
        process.arguments = arguments + [resumeCommand]
        var environment = [
            "HOME": sandbox.homeURL.path,
            "CMUX_CLAUDE_WRAPPER_SHIM": sandbox.shimURL.path
        ]
        for (key, value) in environmentOverrides {
            environment[key] = value
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try runWithBoundedWait(process, shellDescription: shellURL.path)
        return (try? String(contentsOf: sandbox.recordURL, encoding: .utf8)) ?? ""
    }

    /// Launches `process` and waits with a deadline so a stalled shell (missing
    /// shebang interpreter, prompting profile) fails the test with a clear message
    /// instead of hanging until the CI harness kills the job.
    private func runWithBoundedWait(
        _ process: Process,
        shellDescription: String,
        timeout: TimeInterval = 30
    ) throws {
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            XCTFail("Resume shell (\(shellDescription)) did not exit within \(Int(timeout))s; treating as hung.")
        }
    }

    func testRestorableAgentResumeStartupInputEscapesNonAsciiWorkingDirectoryAsAsciiShellInput() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-resume-\(UUID().uuidString)", isDirectory: true)
        let cwdURL = root
            .appendingPathComponent("中文路径", isDirectory: true)
            .appendingPathComponent("uam-service", isDirectory: true)
        try FileManager.default.createDirectory(at: cwdURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshot = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "claude-session-123",
            workingDirectory: cwdURL.path,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/opt/Claude Code/bin/claude",
                arguments: [
                    "/opt/Claude Code/bin/claude",
                    "--model",
                    "sonnet"
                ],
                workingDirectory: cwdURL.path,
                environment: ["CLAUDE_CONFIG_DIR": cwdURL.path],
                capturedAt: 123,
                source: "environment"
            )
        )

        let startupInput = try XCTUnwrap(snapshot.resumeStartupInput())
        XCTAssertTrue(
            startupInput.utf8.allSatisfy { $0 < 0x80 },
            "Terminal startup input must stay ASCII-only so UTF-8 paths are reconstructed by the shell instead of being mojibaked before execution."
        )

        // The printf-escaped non-ASCII cwd plus the `/bin/sh -c` portability wrap
        // (https://github.com/manaflow-ai/cmux/issues/5639) exceed the inline
        // startup-input byte budget, so the input is the `/bin/zsh '<script>'`
        // launcher form; the script body carries the actual resume command.
        let command = try inlineResumeCommandResolvingLauncherScript(from: startupInput)
        XCTAssertTrue(
            command.utf8.allSatisfy { $0 < 0x80 },
            "Launcher-script resume command must stay ASCII-only so UTF-8 paths are reconstructed by the shell instead of being mojibaked before execution."
        )
        let cdCommand = try leadingCdCommand(from: command)
        try assertZshCommandChangesDirectory(cdCommand, expectedPath: cwdURL.path)
    }

    /// Resolves a resume startup input to the line holding the resume command:
    /// inline inputs are returned directly; `/bin/zsh '<script>'` launcher-script
    /// inputs (used when the inline form exceeds the startup-input byte budget)
    /// are read and the script line carrying the resume command is returned.
    private func inlineResumeCommandResolvingLauncherScript(from startupInput: String) throws -> String {
        let trimmed = startupInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/bin/zsh '") else { return trimmed }
        let quotedPath = String(trimmed.dropFirst("/bin/zsh ".count))
        let scriptPath = try XCTUnwrap(
            singleQuotedValueForTest(quotedPath),
            "unparseable launcher-script startup input: \(trimmed)"
        )
        let script = try String(contentsOfFile: scriptPath, encoding: .utf8)
        return try XCTUnwrap(
            script.split(separator: "\n").map(String.init).last(where: { $0.contains(" && ") }),
            "no resume command line in launcher script: \(script)"
        )
    }

    private func singleQuotedValueForTest(_ value: String) -> String? {
        guard value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 else { return nil }
        return String(value.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
    }

    func testSessionEntryClaudeResumeCommandChangesToSessionCwdBeforeResume() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-resume-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let transcriptURL = root
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("-Users-tiffanysun-fun", isDirectory: true)
            .appendingPathComponent("a22293b7-bcef-4707-8439-2f538c8517a4.jsonl", isDirectory: false)
        try FileManager.default.createDirectory(
            at: transcriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let entry = SessionEntry(
            id: "claude:a22293b7-bcef-4707-8439-2f538c8517a4",
            agent: .claude,
            sessionId: "a22293b7-bcef-4707-8439-2f538c8517a4",
            title: "resume me",
            cwd: "/Users/tiffanysun/fun",
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 0),
            fileURL: transcriptURL,
            specifics: .claude(
                model: nil,
                permissionMode: nil,
                configDirectoryForResume: nil
            )
        )

        XCTAssertEqual(
            entry.resumeCommand,
            "cd /Users/tiffanysun/fun && /bin/sh -c "
                + shellQuotedForTest("\(AgentResumeArgv.claudeWrapperShellExecutableToken) --resume a22293b7-bcef-4707-8439-2f538c8517a4")
        )
    }

    func testSessionEntryClaudeResumeCommandEscapesNonAsciiCwdAsAsciiShellInput() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-resume-\(UUID().uuidString)", isDirectory: true)
        let cwdURL = root
            .appendingPathComponent("中文路径", isDirectory: true)
            .appendingPathComponent("uam-service", isDirectory: true)
        try FileManager.default.createDirectory(at: cwdURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let entry = SessionEntry(
            id: "claude:4d8cfb79-ef17-41a7-a0ac-2f0c25ac1519",
            agent: .claude,
            sessionId: "4d8cfb79-ef17-41a7-a0ac-2f0c25ac1519",
            title: "resume me",
            cwd: cwdURL.path,
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 0),
            fileURL: nil,
            specifics: .claude(
                model: "gpt-5.5",
                permissionMode: "bypassPermissions",
                configDirectoryForResume: nil
            )
        )

        let command = try XCTUnwrap(entry.resumeCommand)
        XCTAssertTrue(
            command.utf8.allSatisfy { $0 < 0x80 },
            "Terminal startup input must stay ASCII-only so UTF-8 paths are reconstructed by the shell instead of being mojibaked before execution."
        )

        let cdCommand = try leadingCdCommand(from: command)
        try assertZshCommandChangesDirectory(cdCommand, expectedPath: cwdURL.path)
    }

    private func leadingCdCommand(from command: String) throws -> String {
        let separator = try XCTUnwrap(command.range(of: " && "), "no ' && ' separator in: \(command)")
        return String(command[..<separator.lowerBound])
    }

    private func assertZshCommandChangesDirectory(
        _ cdCommand: String,
        expectedPath: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-fc", "\(cdCommand) && pwd"]

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        try process.run()
        process.waitUntilExit()

        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .newlines)
        let stderr = String(data: errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(process.terminationStatus, 0, stderr ?? "", file: file, line: line)
        XCTAssertEqual(stdout, expectedPath, file: file, line: line)
    }

    func testRestorableAgentStartupInputUsesInlineCommandWhenShort() {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "claude-session-123",
            workingDirectory: "/tmp/cmux project",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/opt/Claude Code/bin/claude",
                arguments: [
                    "/opt/Claude Code/bin/claude",
                    "--model",
                    "sonnet"
                ],
                workingDirectory: "/tmp/cmux project",
                environment: nil,
                capturedAt: 123,
                source: "environment"
            )
        )

        XCTAssertEqual(snapshot.resumeStartupInput(), snapshot.resumeCommand.map { $0 + "\n" })
    }

    func testRestorableAgentStartupInputUsesLauncherScriptWhenCommandExceedsTerminalInputBudget() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-resume-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let longPath = "/tmp/" + String(repeating: "nested-path-", count: 120)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            workingDirectory: "/tmp/repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: [
                    "/Users/example/.bun/bin/codex",
                    "--model",
                    "gpt-5.4",
                    "--add-dir",
                    longPath,
                    "initial prompt should not replay"
                ],
                workingDirectory: "/tmp/repo",
                environment: ["CODEX_HOME": "/tmp/codex"],
                capturedAt: 123,
                source: "environment"
            )
        )

        let input = try XCTUnwrap(snapshot.resumeStartupInput(temporaryDirectory: tempDir))
        XCTAssertLessThanOrEqual(input.utf8.count, SessionRestorableAgentSnapshot.maxInlineStartupInputBytes)
        XCTAssertTrue(input.hasPrefix("/bin/zsh '"))
        XCTAssertFalse(input.contains(longPath))

        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "/bin/zsh '"
        let scriptPath = String(trimmedInput.dropFirst(prefix.count).dropLast())
        let scriptContents = try String(contentsOfFile: scriptPath, encoding: .utf8)
        XCTAssertTrue(scriptContents.contains(longPath))
        XCTAssertTrue(scriptContents.contains("'resume'"))
        XCTAssertTrue(scriptContents.contains("'019dad34-d218-7943-b81a-eddac5c87951'"))

        let attributes = try FileManager.default.attributesOfItem(atPath: scriptPath)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
        XCTAssertEqual(permissions, 0o600)
    }

    func testRestorableAgentStartupInputSkipsOversizedCommandWhenScriptCannotBeWritten() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-resume-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let blockedDirectory = tempDir.appendingPathComponent("not-a-directory", isDirectory: false)
        try "occupied".write(to: blockedDirectory, atomically: true, encoding: .utf8)
        let longPath = "/tmp/" + String(repeating: "nested-path-", count: 120)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            workingDirectory: "/tmp/repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: [
                    "/Users/example/.bun/bin/codex",
                    "--model",
                    "gpt-5.4",
                    "--add-dir",
                    longPath,
                    "initial prompt should not replay"
                ],
                workingDirectory: "/tmp/repo",
                environment: ["CODEX_HOME": "/tmp/codex"],
                capturedAt: 123,
                source: "environment"
            )
        )

        XCTAssertNil(snapshot.resumeStartupInput(temporaryDirectory: blockedDirectory))
    }

    func testClaudeResumeCommandPreservesDangerouslySkipPermissionsAndObservedEnvironment() {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "24ec0052-450c-4914-b1dd-2ee80d4bc84b",
            workingDirectory: "/Users/lawrence/fun",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/Users/lawrence/.local/bin/claude",
                arguments: [
                    "/Users/lawrence/.local/bin/claude",
                    "--dangerously-load-development-channels",
                    "server:custom-dev-channel",
                    "--dangerously-skip-permissions"
                ],
                workingDirectory: "/Users/lawrence/fun",
                environment: [
                    "CLAUDE_CONFIG_DIR": "/Users/lawrence/.codex-accounts/claude/_p1775010019397",
                    "PATH": "/Users/lawrence/.local/bin:/usr/bin",
                    "SHELL": "/bin/zsh"
                ],
                capturedAt: 123,
                source: "environment"
            )
        )

        XCTAssertEqual(
            snapshot.resumeCommand,
            "cd -- '/Users/lawrence/fun' 2>/dev/null || [ ! -d '/Users/lawrence/fun' ] && /bin/sh -c "
                + shellQuotedForTest("'env' 'CLAUDE_CONFIG_DIR=/Users/lawrence/.codex-accounts/claude/_p1775010019397' 'CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV=1' 'CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS=CLAUDE_CONFIG_DIR' \"$([ -x \"${CMUX_CLAUDE_WRAPPER_SHIM:-}\" ] && printf '%s' \"$CMUX_CLAUDE_WRAPPER_SHIM\" || printf claude)\" '--resume' '24ec0052-450c-4914-b1dd-2ee80d4bc84b' '--dangerously-load-development-channels' 'server:custom-dev-channel' '--dangerously-skip-permissions'")
        )
    }

    func testCodexResumeCommandPreservesFlagsAndDropsOriginalPrompt() {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            workingDirectory: "/Users/example/repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: [
                    "/Users/example/.bun/bin/codex",
                    "--model",
                    "gpt-5.4",
                    "--sandbox",
                    "danger-full-access",
                    "--ask-for-approval",
                    "never",
                    "--search",
                    "--cd",
                    "/Users/example/repo",
                    "initial prompt should not replay"
                ],
                workingDirectory: "/Users/example/repo",
                environment: ["CODEX_HOME": "/tmp/codex home"],
                capturedAt: 123,
                source: "process"
            )
        )

        XCTAssertEqual(
            snapshot.resumeCommand,
            "cd -- '/Users/example/repo' 2>/dev/null || [ ! -d '/Users/example/repo' ] && "
                + codexRetryWrappedForTest("'env' 'CODEX_HOME=/tmp/codex home' '/Users/example/.bun/bin/codex' 'resume' '019dad34-d218-7943-b81a-eddac5c87951' '--model' 'gpt-5.4' '--sandbox' 'danger-full-access' '--ask-for-approval' 'never' '--search'")
        )
    }

    func testCodexResumeCommandDropsStartupImagesAndPlacesSessionBeforeFlags() {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019e2bb9-5544-7201-a517-d77bb00d724f",
            workingDirectory: "/Users/lawrence/fun/cmuxterm-hq",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/lawrence/.bun/bin/codex",
                arguments: [
                    "/Users/lawrence/.bun/bin/codex",
                    "resume",
                    "--yolo",
                    "--image",
                    "[Image #1]",
                    "[Image #1] cmd clicking this should open the crash file in finder",
                    "--model",
                    "gpt-5.4",
                ],
                workingDirectory: "/Users/lawrence/fun/cmuxterm-hq",
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )

        XCTAssertEqual(
            snapshot.resumeCommand,
            "cd -- '/Users/lawrence/fun/cmuxterm-hq' 2>/dev/null || [ ! -d '/Users/lawrence/fun/cmuxterm-hq' ] && "
                + codexRetryWrappedForTest("'/Users/lawrence/.bun/bin/codex' 'resume' '019e2bb9-5544-7201-a517-d77bb00d724f' '--yolo' '--model' 'gpt-5.4'")
        )
    }

    func testCodexTeamsResumeCommandUsesWrapperSubcommand() {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            workingDirectory: "/Users/example/repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codexTeams",
                executablePath: "/usr/local/bin/cmux",
                arguments: [
                    "/usr/local/bin/cmux",
                    "codex-teams",
                    "--model",
                    "gpt-5.4",
                    "--image",
                    "/tmp/team screenshot.png",
                    "--sandbox",
                    "danger-full-access",
                    "initial prompt should not replay"
                ],
                workingDirectory: "/Users/example/repo",
                environment: ["CODEX_HOME": "/tmp/codex home"],
                capturedAt: 123,
                source: "environment"
            )
        )

        XCTAssertEqual(
            snapshot.resumeCommand,
            "cd -- '/Users/example/repo' 2>/dev/null || [ ! -d '/Users/example/repo' ] && "
                + codexRetryWrappedForTest("'env' 'CODEX_HOME=/tmp/codex home' '/usr/local/bin/cmux' 'codex-teams' 'resume' '019dad34-d218-7943-b81a-eddac5c87951' '--model' 'gpt-5.4' '--sandbox' 'danger-full-access'")
        )
    }

    func testCodexTeamsResumeCommandDropsOriginalForkTarget() {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87952",
            workingDirectory: "/Users/example/repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codexTeams",
                executablePath: "/usr/local/bin/cmux",
                arguments: [
                    "/usr/local/bin/cmux",
                    "codex-teams",
                    "fork",
                    "019dad34-d218-7943-b81a-eddac5c87951",
                    "--model",
                    "gpt-5.4",
                    "stale fork prompt",
                    "--sandbox",
                    "danger-full-access"
                ],
                workingDirectory: "/Users/example/repo",
                environment: ["CODEX_HOME": "/tmp/codex home"],
                capturedAt: 123,
                source: "environment"
            )
        )

        XCTAssertEqual(
            snapshot.resumeCommand,
            "cd -- '/Users/example/repo' 2>/dev/null || [ ! -d '/Users/example/repo' ] && "
                + codexRetryWrappedForTest("'env' 'CODEX_HOME=/tmp/codex home' '/usr/local/bin/cmux' 'codex-teams' 'resume' '019dad34-d218-7943-b81a-eddac5c87952' '--model' 'gpt-5.4' '--sandbox' 'danger-full-access'")
        )
    }

    func testCodexResumeCommandRetriesTransientStateDatabaseLock() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-resume-lock-\(UUID().uuidString)", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("repo with spaces", isDirectory: true)
        let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let attemptsURL = root.appendingPathComponent("attempts.txt", isDirectory: false)
        let recordURL = root.appendingPathComponent("record.txt", isDirectory: false)
        let fakeCodexURL = binDirectory.appendingPathComponent("codex fake", isDirectory: false)
        try """
        #!/bin/zsh
        attempt=0
        if [[ -r \(shellQuotedForTest(attemptsURL.path)) ]]; then
          attempt="$(cat \(shellQuotedForTest(attemptsURL.path)))"
        fi
        attempt=$((attempt + 1))
        print -r -- "$attempt" > \(shellQuotedForTest(attemptsURL.path))
        if [[ "$attempt" -lt 3 ]]; then
          print -u2 "Codex couldn't start because another Codex process is using its local data."
          print -u2 "Technical details:"
          print -u2 "  Location: /Users/example/.codex/state_5.sqlite"
          print -u2 "  Cause: failed to initialize state runtime: error returned from database: (code: 5) database is locked"
          exit 1
        fi
        printf 'attempt=%s\\ncwd=%s\\nargs=%s\\n' "$attempt" "$PWD" "$*" > \(shellQuotedForTest(recordURL.path))
        """.write(to: fakeCodexURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCodexURL.path)

        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            workingDirectory: workingDirectory.path,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: fakeCodexURL.path,
                arguments: [
                    fakeCodexURL.path,
                    "--model",
                    "gpt-5.4"
                ],
                workingDirectory: workingDirectory.path,
                environment: ["CODEX_HOME": root.appendingPathComponent("codex home", isDirectory: true).path],
                capturedAt: 123,
                source: "process"
            )
        )
        let resumeCommand = try XCTUnwrap(snapshot.resumeCommand)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", resumeCommand]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        try runWithBoundedWait(process, shellDescription: "zsh codex resume retry")
        let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        XCTAssertEqual(process.terminationStatus, 0, stderrText)
        XCTAssertEqual(
            try String(contentsOf: attemptsURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
            "3"
        )
        let record = try String(contentsOf: recordURL, encoding: .utf8)
        XCTAssertTrue(record.contains("cwd=\(workingDirectory.path)\n"), record)
        XCTAssertTrue(record.contains("args=resume 019dad34-d218-7943-b81a-eddac5c87951 --model gpt-5.4\n"), record)
    }

    func testForkCommandsUseVerifiedAgentForkSyntaxAndPreserveContext() {
        let claude = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "24ec0052-450c-4914-b1dd-2ee80d4bc84b",
            workingDirectory: "/Users/lawrence/fun",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/Users/lawrence/.local/bin/claude",
                arguments: [
                    "/Users/lawrence/.local/bin/claude",
                    "--dangerously-load-development-channels",
                    "server:custom-dev-channel",
                    "--dangerously-skip-permissions"
                ],
                workingDirectory: "/Users/lawrence/fun",
                environment: [
                    "CLAUDE_CONFIG_DIR": "/Users/lawrence/.codex-accounts/claude/_p1775010019397",
                    "PATH": "/Users/lawrence/.local/bin:/usr/bin",
                    "SHELL": "/bin/zsh"
                ],
                capturedAt: 123,
                source: "environment"
            )
        )
        let claudeFork = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "claude-fork-child",
            workingDirectory: "/Users/lawrence/fun",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/Users/lawrence/.local/bin/claude",
                arguments: [
                    "/Users/lawrence/.local/bin/claude",
                    "--resume",
                    "24ec0052-450c-4914-b1dd-2ee80d4bc84b",
                    "--fork-session",
                    "--model",
                    "sonnet",
                    "--dangerously-skip-permissions"
                ],
                workingDirectory: "/Users/lawrence/fun",
                environment: [
                    "CLAUDE_CONFIG_DIR": "/Users/lawrence/.codex-accounts/claude/_p1775010019397"
                ],
                capturedAt: 123,
                source: "environment"
            )
        )
        let codex = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            workingDirectory: "/Users/example/repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: [
                    "/Users/example/.bun/bin/codex",
                    "--model",
                    "gpt-5.4",
                    "--sandbox",
                    "danger-full-access",
                    "--ask-for-approval",
                    "never",
                    "--search",
                    "--cd",
                    "/Users/example/repo",
                    "initial prompt should not replay"
                ],
                workingDirectory: "/Users/example/repo",
                environment: ["CODEX_HOME": "/tmp/codex home"],
                capturedAt: 123,
                source: "process"
            )
        )
        let codexWithImage = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019image-session",
            workingDirectory: "/Users/example/repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: [
                    "/Users/example/.bun/bin/codex",
                    "--image",
                    "/tmp/screenshot.png",
                    "--model",
                    "gpt-5.4",
                    "initial prompt should not replay"
                ],
                workingDirectory: "/Users/example/repo",
                environment: ["CODEX_HOME": "/tmp/codex home"],
                capturedAt: 123,
                source: "process"
            )
        )
        let codexFork = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019e1eca-ee32-7001-ab30-edcae57430bb",
            workingDirectory: "/Users/example/repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: [
                    "/Users/example/.bun/bin/codex",
                    "fork",
                    "019dad34-d218-7943-b81a-eddac5c87951",
                    "--model",
                    "gpt-5.4",
                    "--sandbox",
                    "danger-full-access",
                    "stale fork prompt",
                    "--search"
                ],
                workingDirectory: "/Users/example/repo",
                environment: ["CODEX_HOME": "/tmp/codex home"],
                capturedAt: 123,
                source: "process"
            )
        )
        let codexTeams = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-teams-session",
            workingDirectory: "/Users/example/repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codexTeams",
                executablePath: "/usr/local/bin/cmux",
                arguments: [
                    "/usr/local/bin/cmux",
                    "codex-teams",
                    "--model",
                    "gpt-5.4",
                    "--image",
                    "/tmp/team screenshot.png",
                    "--sandbox",
                    "danger-full-access",
                    "initial prompt should not replay"
                ],
                workingDirectory: "/Users/example/repo",
                environment: ["CODEX_HOME": "/tmp/codex home"],
                capturedAt: 123,
                source: "environment"
            )
        )
        let directOpenCode = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "direct-opencode-session-456",
            workingDirectory: "/tmp/direct opencode repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "opencode",
                executablePath: "/opt/homebrew/bin/opencode",
                arguments: [
                    "/opt/homebrew/bin/opencode",
                    "--model",
                    "anthropic/claude-sonnet-4-6",
                    "--session",
                    "old-session",
                    "--prompt",
                    "old prompt",
                    "--port",
                    "4096",
                    "/tmp/direct opencode repo",
                    "initial prompt"
                ],
                workingDirectory: "/tmp/direct opencode repo",
                environment: ["OPENCODE_CONFIG_DIR": "/tmp/opencode config"],
                capturedAt: 123,
                source: "environment"
            )
        )
        let directOpenCodeFork = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "direct-opencode-child-session",
            workingDirectory: "/tmp/direct opencode repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "opencode",
                executablePath: "/opt/homebrew/bin/opencode",
                arguments: [
                    "/opt/homebrew/bin/opencode",
                    "--session",
                    "direct-opencode-session-456",
                    "--fork",
                    "--model",
                    "anthropic/claude-sonnet-4-6",
                    "--port",
                    "4096",
                    "/tmp/direct opencode repo"
                ],
                workingDirectory: "/tmp/direct opencode repo",
                environment: ["OPENCODE_CONFIG_DIR": "/tmp/opencode config"],
                capturedAt: 123,
                source: "environment"
            )
        )
        let omoOpenCode = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "opencode-session-123",
            workingDirectory: "/tmp/opencode repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "omo",
                executablePath: "/usr/local/bin/cmux",
                arguments: [
                    "/usr/local/bin/cmux",
                    "omo",
                    "--model",
                    "anthropic/claude-sonnet-4-6",
                    "/tmp/opencode repo",
                    "initial prompt"
                ],
                workingDirectory: "/tmp/opencode repo",
                environment: ["OPENCODE_CONFIG_DIR": "/tmp/opencode config"],
                capturedAt: 123,
                source: "environment"
            )
        )
        let omoOpenCodeFork = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "opencode-child-session",
            workingDirectory: "/tmp/opencode repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "omo",
                executablePath: "/usr/local/bin/cmux",
                arguments: [
                    "/usr/local/bin/cmux",
                    "omo",
                    "--session",
                    "opencode-session-123",
                    "--fork",
                    "--model",
                    "anthropic/claude-sonnet-4-6",
                    "/tmp/opencode repo"
                ],
                workingDirectory: "/tmp/opencode repo",
                environment: ["OPENCODE_CONFIG_DIR": "/tmp/opencode config"],
                capturedAt: 123,
                source: "environment"
            )
        )
        let unsupported = SessionRestorableAgentSnapshot(
            kind: .gemini,
            sessionId: "gemini-session",
            workingDirectory: "/tmp/gemini repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "gemini",
                executablePath: "gemini",
                arguments: ["gemini"],
                workingDirectory: "/tmp/gemini repo",
                environment: nil,
                capturedAt: nil,
                source: nil
            )
        )

        XCTAssertEqual(
            claude.forkCommand,
            "cd -- '/Users/lawrence/fun' 2>/dev/null || [ ! -d '/Users/lawrence/fun' ] && /bin/sh -c "
                + shellQuotedForTest("'env' 'CLAUDE_CONFIG_DIR=/Users/lawrence/.codex-accounts/claude/_p1775010019397' 'CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV=1' 'CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS=CLAUDE_CONFIG_DIR' \"$([ -x \"${CMUX_CLAUDE_WRAPPER_SHIM:-}\" ] && printf '%s' \"$CMUX_CLAUDE_WRAPPER_SHIM\" || printf claude)\" '--resume' '24ec0052-450c-4914-b1dd-2ee80d4bc84b' '--fork-session' '--dangerously-load-development-channels' 'server:custom-dev-channel' '--dangerously-skip-permissions'")
        )
        XCTAssertEqual(
            claudeFork.forkCommand,
            "cd -- '/Users/lawrence/fun' 2>/dev/null || [ ! -d '/Users/lawrence/fun' ] && /bin/sh -c "
                + shellQuotedForTest("'env' 'CLAUDE_CONFIG_DIR=/Users/lawrence/.codex-accounts/claude/_p1775010019397' 'CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV=1' 'CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS=CLAUDE_CONFIG_DIR' \"$([ -x \"${CMUX_CLAUDE_WRAPPER_SHIM:-}\" ] && printf '%s' \"$CMUX_CLAUDE_WRAPPER_SHIM\" || printf claude)\" '--resume' 'claude-fork-child' '--fork-session' '--model' 'sonnet' '--dangerously-skip-permissions'")
        )
        XCTAssertEqual(
            codex.forkCommand,
            "cd -- '/Users/example/repo' 2>/dev/null || [ ! -d '/Users/example/repo' ] && "
                + codexRetryWrappedForTest("'env' 'CODEX_HOME=/tmp/codex home' '/Users/example/.bun/bin/codex' 'fork' '019dad34-d218-7943-b81a-eddac5c87951' '--model' 'gpt-5.4' '--sandbox' 'danger-full-access' '--ask-for-approval' 'never' '--search'")
        )
        XCTAssertEqual(
            codexWithImage.forkCommand,
            "cd -- '/Users/example/repo' 2>/dev/null || [ ! -d '/Users/example/repo' ] && "
                + codexRetryWrappedForTest("'env' 'CODEX_HOME=/tmp/codex home' '/Users/example/.bun/bin/codex' 'fork' '019image-session' '--model' 'gpt-5.4'")
        )
        XCTAssertEqual(
            codexFork.forkCommand,
            "cd -- '/Users/example/repo' 2>/dev/null || [ ! -d '/Users/example/repo' ] && "
                + codexRetryWrappedForTest("'env' 'CODEX_HOME=/tmp/codex home' '/Users/example/.bun/bin/codex' 'fork' '019e1eca-ee32-7001-ab30-edcae57430bb' '--model' 'gpt-5.4' '--sandbox' 'danger-full-access' '--search'")
        )
        XCTAssertEqual(
            codexTeams.forkCommand,
            "cd -- '/Users/example/repo' 2>/dev/null || [ ! -d '/Users/example/repo' ] && "
                + codexRetryWrappedForTest("'env' 'CODEX_HOME=/tmp/codex home' '/usr/local/bin/cmux' 'codex-teams' 'fork' 'codex-teams-session' '--model' 'gpt-5.4' '--sandbox' 'danger-full-access'")
        )
        XCTAssertEqual(
            directOpenCode.forkCommand,
            "cd -- '/tmp/direct opencode repo' 2>/dev/null || [ ! -d '/tmp/direct opencode repo' ] && 'env' 'OPENCODE_CONFIG_DIR=/tmp/opencode config' '/opt/homebrew/bin/opencode' '--session' 'direct-opencode-session-456' '--fork' '--model' 'anthropic/claude-sonnet-4-6' '--port' '4096' '/tmp/direct opencode repo'"
        )
        XCTAssertEqual(
            directOpenCodeFork.forkCommand,
            "cd -- '/tmp/direct opencode repo' 2>/dev/null || [ ! -d '/tmp/direct opencode repo' ] && 'env' 'OPENCODE_CONFIG_DIR=/tmp/opencode config' '/opt/homebrew/bin/opencode' '--session' 'direct-opencode-child-session' '--fork' '--model' 'anthropic/claude-sonnet-4-6' '--port' '4096' '/tmp/direct opencode repo'"
        )
        XCTAssertEqual(
            omoOpenCode.forkCommand,
            "cd -- '/tmp/opencode repo' 2>/dev/null || [ ! -d '/tmp/opencode repo' ] && 'env' 'OPENCODE_CONFIG_DIR=/tmp/opencode config' '/usr/local/bin/cmux' 'omo' '--session' 'opencode-session-123' '--fork' '--model' 'anthropic/claude-sonnet-4-6' '/tmp/opencode repo'"
        )
        XCTAssertEqual(
            omoOpenCodeFork.forkCommand,
            "cd -- '/tmp/opencode repo' 2>/dev/null || [ ! -d '/tmp/opencode repo' ] && 'env' 'OPENCODE_CONFIG_DIR=/tmp/opencode config' '/usr/local/bin/cmux' 'omo' '--session' 'opencode-child-session' '--fork' '--model' 'anthropic/claude-sonnet-4-6' '/tmp/opencode repo'"
        )
        XCTAssertNil(unsupported.forkCommand)
    }

    func testOpenCodeForkSupportRequiresVersionWithForkFix() {
        XCTAssertFalse(AgentForkSupport.openCodeVersionSupportsFork("opencode 1.14.48"))
        XCTAssertTrue(AgentForkSupport.openCodeVersionSupportsFork("opencode 1.14.50"))
        XCTAssertTrue(AgentForkSupport.openCodeVersionSupportsFork("opencode version 1.15.0"))
        XCTAssertFalse(AgentForkSupport.openCodeVersionSupportsFork("not a version"))
    }

    func testOpenCodeForkSupportProbesFromLaunchWorkingDirectory() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-opencode-probe-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("opencode", isDirectory: false)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try """
        #!/bin/sh
        echo 'opencode 1.14.50'
        """.write(to: executable, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let snapshot = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "opencode-session-123",
            workingDirectory: root.path,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "opencode",
                executablePath: "opencode",
                arguments: ["opencode"],
                workingDirectory: root.path,
                environment: ["PATH": ".:/usr/bin:/bin"],
                capturedAt: 123,
                source: "process"
            )
        )

        let supportsFork = await AgentForkSupport.supportsFork(snapshot: snapshot)
        XCTAssertTrue(supportsFork)
    }

    func testOpenCodeForkSupportSkipsLocalProbeForRemoteLikeContext() async {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "opencode-session-remote",
            workingDirectory: "/remote/cmux/project-\(UUID().uuidString)",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "opencode",
                executablePath: "/remote/bin/opencode",
                arguments: ["/remote/bin/opencode"],
                workingDirectory: "/remote/cmux/project-\(UUID().uuidString)",
                environment: ["PATH": "/remote/bin:/usr/bin"],
                capturedAt: 123,
                source: "process"
            )
        )

        let supportsFork = await AgentForkSupport.supportsFork(snapshot: snapshot)
        XCTAssertTrue(supportsFork)
    }

    func testAgentForkSupportRejectsRemoteForksThatNeedLauncherScript() async {
        let longPath = "/Users/cmux/" + String(repeating: "nested-project-", count: 120)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            workingDirectory: "/Users/cmux/project",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: [
                    "/Users/example/.bun/bin/codex",
                    "--model",
                    "gpt-5.4",
                    "--add-dir",
                    longPath
                ],
                workingDirectory: "/Users/cmux/project",
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )

        XCTAssertNotNil(snapshot.forkStartupInput(allowLauncherScript: true))
        XCTAssertNil(snapshot.forkStartupInput(allowLauncherScript: false))
        let supportsFork = await AgentForkSupport.supportsFork(
            snapshot: snapshot,
            isRemoteContext: true
        )
        XCTAssertFalse(supportsFork)
    }

    // Regression: the Codex retry launcher (`/bin/zsh -c '<multi-KB script>'`) must stay on local
    // dispatch. A remote fork (`allowLauncherScript: false`) cannot ship a locally written launcher
    // script and may not have `/bin/zsh`, and the wrapped command also blows past
    // `maxInlineStartupInputBytes`, so wrapping it there returned nil and dropped the remote fork.
    func testCodexRemoteForkStartupInputStaysInlineWithoutZshRetryLauncher() throws {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            workingDirectory: "/Users/cmux/project",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: [
                    "/Users/example/.bun/bin/codex",
                    "--model",
                    "gpt-5.4"
                ],
                workingDirectory: "/Users/cmux/project",
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )
        // Local dispatch can write a launcher script and is guaranteed /bin/zsh, so it still succeeds.
        XCTAssertNotNil(snapshot.forkStartupInput(allowLauncherScript: true))
        // Remote/inline dispatch stays a compact, zsh-independent command rather than nil.
        let remoteInput = try XCTUnwrap(
            snapshot.forkStartupInput(allowLauncherScript: false),
            "remote codex fork must produce a compact inline command, not nil"
        )
        XCTAssertFalse(remoteInput.contains("/bin/zsh -c"), remoteInput)
        XCTAssertFalse(remoteInput.contains("_cmux_codex_retry_limit"), remoteInput)
        XCTAssertTrue(remoteInput.contains("019dad34-d218-7943-b81a-eddac5c87951"), remoteInput)
    }

    func testOpenCodeForkSupportRemoteContextBypassesLocalProbe() async {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "opencode-session-remote-context",
            workingDirectory: FileManager.default.temporaryDirectory.path,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "opencode",
                executablePath: "/bin/false",
                arguments: ["/bin/false"],
                workingDirectory: FileManager.default.temporaryDirectory.path,
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )

        let supportsFork = await AgentForkSupport.supportsFork(
            snapshot: snapshot,
            isRemoteContext: true
        )
        XCTAssertTrue(supportsFork)
    }

    func testOpenCodeForkSupportRejectsMissingLocalExecutable() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-opencode-missing-executable-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let missingExecutable = root.appendingPathComponent("missing-opencode", isDirectory: false)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "opencode-session-missing-executable",
            workingDirectory: root.path,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "opencode",
                executablePath: missingExecutable.path,
                arguments: [missingExecutable.path],
                workingDirectory: root.path,
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )

        let supportsFork = await AgentForkSupport.supportsFork(snapshot: snapshot)
        XCTAssertFalse(supportsFork)
    }

    func testOpenCodeForkSupportCachesUnsupportedVersion() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-opencode-probe-cache-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("opencode", isDirectory: false)
        let versionFile = root.appendingPathComponent("version.txt", isDirectory: false)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try """
        #!/bin/sh
        cat "\(versionFile.path)"
        """.write(to: executable, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let snapshot = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "opencode-session-cache",
            workingDirectory: root.path,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "opencode",
                executablePath: "opencode",
                arguments: ["opencode"],
                workingDirectory: root.path,
                environment: ["PATH": "\(root.path):/usr/bin:/bin"],
                capturedAt: 123,
                source: "process"
            )
        )

        try "opencode 1.14.48\n".write(to: versionFile, atomically: true, encoding: .utf8)
        let unsupportedVersionSupportsFork = await AgentForkSupport.supportsFork(snapshot: snapshot)
        XCTAssertFalse(unsupportedVersionSupportsFork)

        try "opencode 1.14.50\n".write(to: versionFile, atomically: true, encoding: .utf8)
        let supportedVersionSupportsFork = await AgentForkSupport.supportsFork(snapshot: snapshot)
        XCTAssertFalse(supportedVersionSupportsFork)
    }

    func testOpenCodeVersionProbeEnvironmentIsSanitized() {
        let environment = AgentForkSupport.processEnvironmentForOpenCodeProbe(
            environment: [
                "PATH": "/tmp/project/bin:/usr/bin",
                "OPENCODE_CONFIG_DIR": "/tmp/opencode-config",
                "ANTHROPIC_API_KEY": "captured-secret",
            ],
            baseEnvironment: [
                "PATH": "/usr/local/bin:/usr/bin",
                "HOME": "/Users/example",
                "TMPDIR": "/tmp/example",
                "LANG": "en_US.UTF-8",
                "AWS_SECRET_ACCESS_KEY": "app-secret",
                "ANTHROPIC_API_KEY": "app-secret",
            ]
        )

        XCTAssertEqual(environment["PATH"], "/tmp/project/bin:/usr/bin")
        XCTAssertEqual(environment["HOME"], "/Users/example")
        XCTAssertEqual(environment["TMPDIR"], "/tmp/example")
        XCTAssertEqual(environment["LANG"], "en_US.UTF-8")
        XCTAssertEqual(environment["OPENCODE_CONFIG_DIR"], "/tmp/opencode-config")
        XCTAssertNil(environment["AWS_SECRET_ACCESS_KEY"])
        XCTAssertNil(environment["ANTHROPIC_API_KEY"])
    }

    func testProcessDetectedLaunchCommandFiltersEnvironmentAndOmitsCapturedAt() {
        let command = AgentLaunchCommandSnapshot(
            processDetectedLauncher: "opencode",
            executablePath: "/opt/homebrew/bin/opencode",
            arguments: ["/opt/homebrew/bin/opencode"],
            workingDirectory: "/tmp/repo",
            environment: [
                "OPENCODE_CONFIG_DIR": "/tmp/opencode config",
                "ANTHROPIC_BASE_URL": "https://api.example.test",
                "ANTHROPIC_API_KEY": "secret",
                "AWS_SECRET_ACCESS_KEY": "secret",
                "PATH": "/tmp/bin:/usr/bin"
            ]
        )

        XCTAssertEqual(command.launcher, "opencode")
        XCTAssertEqual(command.environment?["OPENCODE_CONFIG_DIR"], "/tmp/opencode config")
        XCTAssertEqual(command.environment?["ANTHROPIC_BASE_URL"], "https://api.example.test")
        XCTAssertEqual(command.environment?["PATH"], "/tmp/bin:/usr/bin")
        XCTAssertNil(command.environment?["ANTHROPIC_API_KEY"])
        XCTAssertNil(command.environment?["AWS_SECRET_ACCESS_KEY"])
        XCTAssertNil(command.capturedAt)
        XCTAssertEqual(command.source, "process")

        let nonOpenCodeCommand = AgentLaunchCommandSnapshot(
            processDetectedLauncher: "codex",
            executablePath: "codex",
            arguments: ["codex"],
            workingDirectory: nil,
            environment: ["CODEX_HOME": "/tmp/codex", "PATH": "/tmp/bin:/usr/bin"]
        )
        XCTAssertEqual(nonOpenCodeCommand.environment?["CODEX_HOME"], "/tmp/codex")
        XCTAssertNil(nonOpenCodeCommand.environment?["PATH"])

        let unsafeOnly = AgentLaunchCommandSnapshot(
            processDetectedLauncher: "opencode",
            executablePath: "opencode",
            arguments: ["opencode"],
            workingDirectory: nil,
            environment: ["ANTHROPIC_API_KEY": "secret"]
        )
        XCTAssertNil(unsafeOnly.environment)
        XCTAssertNil(unsafeOnly.capturedAt)
    }

    func testProcessDetectedOpenCodeRecognizesNodeWrapperAndNativeWorker() {
        XCTAssertTrue(
            RestorableAgentSessionIndex.processLooksLikeOpenCode(
                processName: "node",
                processPath: "/opt/homebrew/bin/node",
                arguments: ["node", "/Users/lawrence/.bun/bin/opencode"]
            )
        )
        XCTAssertTrue(
            RestorableAgentSessionIndex.processLooksLikeOpenCode(
                processName: ".opencode",
                processPath: "/Users/lawrence/.bun/install/global/node_modules/opencode-ai/bin/.opencode",
                arguments: ["/Users/lawrence/.bun/install/global/node_modules/opencode-ai/bin/.opencode"]
            )
        )
        XCTAssertTrue(
            RestorableAgentSessionIndex.processLooksLikeOpenCode(
                processName: "open-code",
                processPath: "/opt/homebrew/bin/open-code",
                arguments: ["open-code"]
            )
        )
        XCTAssertTrue(
            RestorableAgentSessionIndex.processLooksLikeOpenCode(
                processName: "node",
                processPath: "/opt/homebrew/bin/node",
                arguments: ["node", "/opt/homebrew/bin/open-code"]
            )
        )
        XCTAssertFalse(
            RestorableAgentSessionIndex.processLooksLikeOpenCode(
                processName: "node",
                processPath: "/opt/homebrew/bin/node",
                arguments: ["node", "/tmp/not-opencode-ai-helper"]
            )
        )
        XCTAssertFalse(
            RestorableAgentSessionIndex.processLooksLikeOpenCode(
                processName: "node",
                processPath: "/opt/homebrew/bin/node",
                arguments: [
                    "node",
                    "/Users/lawrence/.bun/install/global/node_modules/opencode-ai/src/cli/cmd/tui/worker.js"
                ]
            )
        )
        XCTAssertFalse(
            RestorableAgentSessionIndex.processLooksLikeOpenCode(
                processName: "node",
                processPath: "/opt/homebrew/bin/node",
                arguments: ["node", "/Users/lawrence/.bun/bin/codex"]
            )
        )
        XCTAssertFalse(
            RestorableAgentSessionIndex.processLooksLikeOpenCode(
                processName: "tail",
                processPath: "/usr/bin/tail",
                arguments: ["tail", "-f", "/tmp/opencode"]
            )
        )
        XCTAssertFalse(
            RestorableAgentSessionIndex.processLooksLikeOpenCode(
                processName: "node",
                processPath: "/opt/homebrew/bin/node",
                arguments: ["node", "/tmp/script.js", "/Users/lawrence/.bun/bin/opencode"]
            )
        )
        XCTAssertTrue(
            RestorableAgentSessionIndex.processLooksLikeOpenCode(
                processName: "node",
                processPath: "/opt/homebrew/bin/node",
                arguments: ["node", "--require", "/tmp/hook.js", "/Users/lawrence/.bun/bin/opencode"]
            )
        )
        XCTAssertEqual(
            RestorableAgentSessionIndex.openCodeExecutablePathForProcess(
                arguments: ["node", "/Users/lawrence/.bun/bin/opencode"],
                environment: [:]
            ),
            "/Users/lawrence/.bun/bin/opencode"
        )
        XCTAssertNil(
            RestorableAgentSessionIndex.openCodeLaunchArgumentsForProcess(
                arguments: ["opencode", "run", "--session", "unsupported-session"],
                environment: [:]
            )
        )
    }

    func testProcessDetectedOpenCodeResolvesBareExecutableWithCapturedPath() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-opencode-path-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let executable = bin.appendingPathComponent("opencode", isDirectory: false)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        XCTAssertTrue(fileManager.createFile(atPath: executable.path, contents: Data()))
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        XCTAssertEqual(
            RestorableAgentSessionIndex.openCodeExecutablePathForProcess(
                arguments: ["opencode"],
                environment: ["PATH": "\(bin.path):/usr/bin"]
            ),
            executable.path
        )
        XCTAssertEqual(
            RestorableAgentSessionIndex.openCodeExecutablePathForProcess(
                arguments: [".opencode"],
                environment: ["PATH": "\(bin.path):/usr/bin"]
            ),
            executable.path
        )
    }

    func testProcessDetectedOpenCodeWorkingDirectoryUsesProjectPositional() {
        XCTAssertEqual(
            RestorableAgentSessionIndex.openCodeWorkingDirectoryForProcess(
                arguments: [
                    "opencode",
                    "--model",
                    "anthropic/claude-sonnet-4-6",
                    "/tmp/opencode-project"
                ],
                environment: ["PWD": "/tmp/shell-cwd"]
            ),
            "/tmp/opencode-project"
        )
        XCTAssertEqual(
            RestorableAgentSessionIndex.openCodeWorkingDirectoryForProcess(
                arguments: [
                    "node",
                    "/Users/example/.bun/bin/opencode",
                    "../opencode-project"
                ],
                environment: ["PWD": "/tmp/shell-cwd/nested"]
            ),
            "/tmp/shell-cwd/opencode-project"
        )
        XCTAssertEqual(
            RestorableAgentSessionIndex.openCodeWorkingDirectoryForProcess(
                arguments: ["opencode", "--session", "known-session"],
                environment: ["CMUX_AGENT_LAUNCH_CWD": "/tmp/hook-cwd", "PWD": "/tmp/shell-cwd"]
            ),
            "/tmp/hook-cwd"
        )
    }

    func testProcessDetectedOpenCodeLaunchArgumentsPreserveSafeForkContext() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-opencode-argv-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let executable = bin.appendingPathComponent("opencode", isDirectory: false)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        XCTAssertTrue(fileManager.createFile(atPath: executable.path, contents: Data()))
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let arguments = try XCTUnwrap(RestorableAgentSessionIndex.openCodeLaunchArgumentsForProcess(
            arguments: [
                "node",
                "opencode",
                "--model",
                "anthropic/claude-sonnet-4-6",
                "--agent",
                "build",
                "--port",
                "4096",
                "--session",
                "old-session",
                "--prompt",
                "old prompt",
                "/tmp/opencode repo"
            ],
            environment: ["PATH": "\(bin.path):/usr/bin"]
        ))
        XCTAssertEqual(
            arguments,
            [
                executable.path,
                "--model",
                "anthropic/claude-sonnet-4-6",
                "--agent",
                "build",
                "--port",
                "4096",
                "/tmp/opencode repo"
            ]
        )

        let snapshot = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "opencode-session-123",
            workingDirectory: "/tmp/opencode repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "opencode",
                executablePath: executable.path,
                arguments: arguments,
                workingDirectory: "/tmp/opencode repo",
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )

        XCTAssertEqual(
            snapshot.forkCommand,
            "cd -- '/tmp/opencode repo' 2>/dev/null || [ ! -d '/tmp/opencode repo' ] && '\(executable.path)' '--session' 'opencode-session-123' '--fork' '--model' 'anthropic/claude-sonnet-4-6' '--agent' 'build' '--port' '4096' '/tmp/opencode repo'"
        )
    }

    func testProcessDetectedOpenCodeSessionFallbackAvoidsAmbiguousSameDirectoryPanels() {
        XCTAssertEqual(
            RestorableAgentSessionIndex.openCodeFallbackSessionIdForProcess(
                arguments: ["opencode", "--session", "ses-explicit"],
                latestSessionIdForSolePanel: "ses-latest",
                sameWorkingDirectoryPanelCount: 2
            ),
            "ses-explicit"
        )
        XCTAssertEqual(
            RestorableAgentSessionIndex.openCodeFallbackSessionIdForProcess(
                arguments: ["opencode", "--session", "ses-parent", "--fork"],
                latestSessionIdForSolePanel: "ses-child",
                sameWorkingDirectoryPanelCount: 1
            ),
            "ses-child"
        )
        XCTAssertEqual(
            RestorableAgentSessionIndex.openCodeFallbackSessionIdForProcess(
                arguments: ["opencode", "--fork=ses-parent"],
                latestSessionIdForSolePanel: "ses-child",
                sameWorkingDirectoryPanelCount: 1
            ),
            "ses-child"
        )
        XCTAssertNil(
            RestorableAgentSessionIndex.openCodeFallbackSessionIdForProcess(
                arguments: ["opencode", "--fork=ses-parent"],
                latestSessionIdForSolePanel: "ses-parent",
                sameWorkingDirectoryPanelCount: 1
            )
        )
        XCTAssertEqual(
            RestorableAgentSessionIndex.openCodeFallbackSessionIdForProcess(
                arguments: ["opencode", "--session", "ses-child", "--fork=ses-parent"],
                latestSessionIdForSolePanel: "ses-parent",
                sameWorkingDirectoryPanelCount: 1
            ),
            "ses-child"
        )
        XCTAssertEqual(
            RestorableAgentSessionIndex.openCodeFallbackSessionIdForProcess(
                arguments: ["opencode", "--session", "ses-child", "--fork=ses-parent"],
                latestSessionIdForSolePanel: nil,
                sameWorkingDirectoryPanelCount: 2
            ),
            "ses-child"
        )
        XCTAssertNil(
            RestorableAgentSessionIndex.openCodeFallbackSessionIdForProcess(
                arguments: ["opencode", "--session", "ses-parent", "--fork"],
                latestSessionIdForSolePanel: nil,
                sameWorkingDirectoryPanelCount: 1
            )
        )
        XCTAssertNil(
            RestorableAgentSessionIndex.openCodeFallbackSessionIdForProcess(
                arguments: ["opencode", "--session", "ses-parent", "--fork"],
                latestSessionIdForSolePanel: "ses-parent",
                sameWorkingDirectoryPanelCount: 1
            )
        )
        XCTAssertNil(
            RestorableAgentSessionIndex.openCodeFallbackSessionIdForProcess(
                arguments: ["opencode"],
                latestSessionIdForSolePanel: "ses-latest",
                sameWorkingDirectoryPanelCount: 1
            )
        )
        XCTAssertNil(
            RestorableAgentSessionIndex.openCodeFallbackSessionIdForProcess(
                arguments: ["opencode", "--fork"],
                latestSessionIdForSolePanel: "ses-latest",
                sameWorkingDirectoryPanelCount: 1
            )
        )
        XCTAssertNil(
            RestorableAgentSessionIndex.openCodeFallbackSessionIdForProcess(
                arguments: ["opencode"],
                latestSessionIdForSolePanel: "ses-latest",
                sameWorkingDirectoryPanelCount: 2
            )
        )
        XCTAssertNil(
            RestorableAgentSessionIndex.openCodeFallbackSessionIdForProcess(
                arguments: ["opencode"],
                latestSessionIdForSolePanel: nil,
                sameWorkingDirectoryPanelCount: 1
            )
        )
    }

    func testClaudeTeamsResumeCommandPreservesRemoteControlLauncher() {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "claude-team-session",
            workingDirectory: "/tmp/team repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claudeTeams",
                executablePath: "/Applications/cmux.app/Contents/Resources/bin/cmux",
                arguments: [
                    "/Applications/cmux.app/Contents/Resources/bin/cmux",
                    "claude-teams",
                    "--teammate-mode",
                    "auto",
                    "--model",
                    "sonnet",
                    "--remote-control-session-name-prefix",
                    "cmux-team",
                    "--tmux",
                    "side effect should be dropped",
                    "--permission-mode",
                    "auto",
                    "initial team prompt"
                ],
                workingDirectory: "/tmp/team repo",
                environment: [
                    "CMUX_CUSTOM_CLAUDE_PATH": "/opt/Claude Code/bin/claude",
                    "PATH": "/opt/Claude Code/bin:/usr/bin"
                ],
                capturedAt: 123,
                source: "environment"
            )
        )

        XCTAssertEqual(
            snapshot.resumeCommand,
            "cd -- '/tmp/team repo' 2>/dev/null || [ ! -d '/tmp/team repo' ] && 'env' 'CMUX_CUSTOM_CLAUDE_PATH=/opt/Claude Code/bin/claude' '/Applications/cmux.app/Contents/Resources/bin/cmux' 'claude-teams' '--resume' 'claude-team-session' '--teammate-mode' 'auto' '--model' 'sonnet' '--remote-control-session-name-prefix' 'cmux-team' '--permission-mode' 'auto'"
        )
    }

    func testClaudeResumeCommandHandlesOptionalDebugValueAndFilteredEnvironment() {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "claude-session-debug",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "claude",
                arguments: [
                    "claude",
                    "--debug",
                    "api,mcp",
                    "--model",
                    "sonnet",
                    "prompt should not replay"
                ],
                workingDirectory: nil,
                environment: [
                    "UNSAFE_TOKEN": "secret",
                    "NODE_OPTIONS": "--max-old-space-size=4096"
                ],
                capturedAt: nil,
                source: nil
            )
        )

        XCTAssertEqual(
            snapshot.resumeCommand,
            "/bin/sh -c " + shellQuotedForTest("'env' 'NODE_OPTIONS=--max-old-space-size=4096' \"$([ -x \"${CMUX_CLAUDE_WRAPPER_SHIM:-}\" ] && printf '%s' \"$CMUX_CLAUDE_WRAPPER_SHIM\" || printf claude)\" '--resume' 'claude-session-debug' '--debug' 'api,mcp' '--model' 'sonnet'")
        )
    }

    func testResumeCommandPreservesSafeProviderEnvironmentValuesOnly() {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "claude-session-env",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "claude",
                arguments: ["claude"],
                workingDirectory: nil,
                environment: [
                    "ANTHROPIC_AUTH_TOKEN": "third-party-auth-token",
                    "ANTHROPIC_BASE_URL": "https://api.example.test",
                    "ANTHROPIC_MODEL": "",
                    "PATH": " /tmp/bin ",
                    "UNSAFE_TOKEN": "secret"
                ],
                capturedAt: nil,
                source: nil
            )
        )

        XCTAssertEqual(
            snapshot.resumeCommand,
            "/bin/sh -c " + shellQuotedForTest("'env' 'ANTHROPIC_BASE_URL=https://api.example.test' 'ANTHROPIC_MODEL=' 'CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV=1' 'CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS=ANTHROPIC_BASE_URL,ANTHROPIC_MODEL' \"$([ -x \"${CMUX_CLAUDE_WRAPPER_SHIM:-}\" ] && printf '%s' \"$CMUX_CLAUDE_WRAPPER_SHIM\" || printf claude)\" '--resume' 'claude-session-env'")
        )
        XCTAssertFalse(snapshot.resumeCommand?.contains("ANTHROPIC_AUTH_TOKEN") ?? true)
    }

    func testClaudeResumeCommandStripsStaleCmuxNodeOptionsRestoreModule() {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "claude-session-node-options",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "claude",
                arguments: ["claude", "--model", "sonnet"],
                workingDirectory: nil,
                environment: [
                    "NODE_OPTIONS": "--require=/tmp/cmux-claude-node-options/restore-node-options.cjs --max-old-space-size=4096 --trace-warnings"
                ],
                capturedAt: nil,
                source: nil
            )
        )

        XCTAssertEqual(
            snapshot.resumeCommand,
            "/bin/sh -c " + shellQuotedForTest("'env' 'NODE_OPTIONS=--trace-warnings' \"$([ -x \"${CMUX_CLAUDE_WRAPPER_SHIM:-}\" ] && printf '%s' \"$CMUX_CLAUDE_WRAPPER_SHIM\" || printf claude)\" '--resume' 'claude-session-node-options' '--model' 'sonnet'")
        )
    }

    func testClaudeResumeCommandDropsEmptyStaleCmuxNodeOptionsEnvironment() {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "claude-session-empty-node-options",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "claude",
                arguments: ["claude", "--model", "sonnet"],
                workingDirectory: nil,
                environment: [
                    "NODE_OPTIONS": "--require /tmp/cmux-claude-node-options/restore-node-options.cjs --max-old-space-size 4096"
                ],
                capturedAt: nil,
                source: nil
            )
        )

        XCTAssertEqual(
            snapshot.resumeCommand,
            "/bin/sh -c " + shellQuotedForTest("\"$([ -x \"${CMUX_CLAUDE_WRAPPER_SHIM:-}\" ] && printf '%s' \"$CMUX_CLAUDE_WRAPPER_SHIM\" || printf claude)\" '--resume' 'claude-session-empty-node-options' '--model' 'sonnet'")
        )
    }

    func testOpenCodeWrapperResumeCommandAndUnsupportedOhMyLaunchers() {
        let direct = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "direct-opencode-session-456",
            workingDirectory: "/tmp/direct opencode repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "opencode",
                executablePath: "/opt/homebrew/bin/opencode",
                arguments: [
                    "/opt/homebrew/bin/opencode",
                    "--model",
                    "anthropic/claude-sonnet-4-6",
                    "--session",
                    "old-session",
                    "--prompt",
                    "old prompt",
                    "--port",
                    "4096",
                    "/tmp/direct opencode repo",
                    "initial prompt"
                ],
                workingDirectory: "/tmp/direct opencode repo",
                environment: ["OPENCODE_CONFIG_DIR": "/tmp/opencode config"],
                capturedAt: 123,
                source: "environment"
            )
        )
        let omo = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "opencode-session-123",
            workingDirectory: "/tmp/opencode repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "omo",
                executablePath: "/usr/local/bin/cmux",
                arguments: [
                    "/usr/local/bin/cmux",
                    "omo",
                    "--model",
                    "anthropic/claude-sonnet-4-6",
                    "/tmp/opencode repo",
                    "initial prompt"
                ],
                workingDirectory: "/tmp/opencode repo",
                environment: ["OPENCODE_CONFIG_DIR": "/tmp/opencode config"],
                capturedAt: 123,
                source: "environment"
            )
        )
        let staleBunWorker = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "ses_24b0be92affeVRRBplLmUzbXQl",
            workingDirectory: "/Users/lawrence/fun",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "opencode",
                executablePath: "/Users/lawrence/.bun/bin/opencode",
                arguments: [
                    "/Users/lawrence/.bun/bin/opencode",
                    "/$bunfs/root/src/cli/cmd/tui/worker.js"
                ],
                workingDirectory: "/Users/lawrence/fun",
                environment: [
                    "PATH": "/Users/lawrence/.bun/bin:/usr/bin",
                    "SHELL": "/bin/zsh"
                ],
                capturedAt: 123,
                source: "environment"
            )
        )
        let omx = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-session-123",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "omx",
                executablePath: "/usr/local/bin/cmux",
                arguments: ["/usr/local/bin/cmux", "omx", "team"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: nil
            )
        )
        let omc = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "claude-session-123",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "omc",
                executablePath: "/usr/local/bin/cmux",
                arguments: ["/usr/local/bin/cmux", "omc", "team"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: nil
            )
        )

        XCTAssertEqual(
            direct.resumeCommand,
            "cd -- '/tmp/direct opencode repo' 2>/dev/null || [ ! -d '/tmp/direct opencode repo' ] && 'env' 'OPENCODE_CONFIG_DIR=/tmp/opencode config' '/opt/homebrew/bin/opencode' '--session' 'direct-opencode-session-456' '--model' 'anthropic/claude-sonnet-4-6' '--port' '4096' '/tmp/direct opencode repo'"
        )
        XCTAssertEqual(
            omo.resumeCommand,
            "cd -- '/tmp/opencode repo' 2>/dev/null || [ ! -d '/tmp/opencode repo' ] && 'env' 'OPENCODE_CONFIG_DIR=/tmp/opencode config' '/usr/local/bin/cmux' 'omo' '--session' 'opencode-session-123' '--model' 'anthropic/claude-sonnet-4-6' '/tmp/opencode repo'"
        )
        XCTAssertEqual(
            staleBunWorker.resumeCommand,
            "cd -- '/Users/lawrence/fun' 2>/dev/null || [ ! -d '/Users/lawrence/fun' ] && '/Users/lawrence/.bun/bin/opencode' '--session' 'ses_24b0be92affeVRRBplLmUzbXQl'"
        )
        XCTAssertNil(omx.resumeCommand)
        XCTAssertNil(omc.resumeCommand)
    }

    func testRestorableAgentIndexLoadsLaunchCommandFromHookStore() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-hook-store-\(UUID().uuidString)", isDirectory: true)
        let storeDir = home.appendingPathComponent(".cmuxterm", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let workspaceId = UUID()
        let panelId = UUID()
        let storeURL = storeDir.appendingPathComponent("codex-hook-sessions.json", isDirectory: false)
        let json = """
        {
          "version": 1,
          "sessions": {
            "codex-session-123": {
              "sessionId": "codex-session-123",
              "workspaceId": "\(workspaceId.uuidString)",
              "surfaceId": "\(panelId.uuidString)",
              "cwd": "/tmp/repo",
              "updatedAt": 123,
              "launchCommand": {
                "launcher": "codex",
                "executablePath": "/usr/local/bin/codex",
                "arguments": [
                  "/usr/local/bin/codex",
                  "--model",
                  "gpt-5.4",
                  "--search",
                  "old prompt"
                ],
                "workingDirectory": "/tmp/repo",
                "environment": {
                  "CODEX_HOME": "/tmp/codex"
                },
                "capturedAt": 122,
                "source": "process"
              }
            }
          }
        }
        """
        try json.write(to: storeURL, atomically: true, encoding: .utf8)

        let index = RestorableAgentSessionIndex.load(homeDirectory: home.path)
        let snapshot = try XCTUnwrap(index.snapshot(workspaceId: workspaceId, panelId: panelId))

        XCTAssertEqual(snapshot.launchCommand?.arguments.first, "/usr/local/bin/codex")
        XCTAssertEqual(
            snapshot.resumeCommand,
            "cd -- '/tmp/repo' 2>/dev/null || [ ! -d '/tmp/repo' ] && "
                + codexRetryWrappedForTest("'env' 'CODEX_HOME=/tmp/codex' '/usr/local/bin/codex' 'resume' 'codex-session-123' '--model' 'gpt-5.4' '--search'")
        )
    }

    func testRestorableAgentIndexUsesNewerProcessFallbackOverStaleOmoHookRecord() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-agent-hook-store-\(UUID().uuidString)", isDirectory: true)
        let storeDir = home.appendingPathComponent(".cmuxterm", isDirectory: true)
        try fileManager.createDirectory(at: storeDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }

        let workspaceId = UUID()
        let panelId = UUID()
        let storeURL = storeDir.appendingPathComponent("opencode-hook-sessions.json", isDirectory: false)
        let json = """
        {
          "version": 1,
          "sessions": {
            "hook-session": {
              "sessionId": "hook-session",
              "workspaceId": "\(workspaceId.uuidString)",
              "surfaceId": "\(panelId.uuidString)",
              "cwd": "/tmp/repo",
              "updatedAt": 10,
              "launchCommand": {
                "launcher": "omo",
                "executablePath": "/usr/local/bin/cmux",
                "arguments": [
                  "/usr/local/bin/cmux",
                  "omo",
                  "--model",
                  "anthropic/claude-sonnet-4-6",
                  "/tmp/repo",
                  "old prompt"
                ],
                "workingDirectory": "/tmp/repo",
                "environment": {
                  "OPENCODE_CONFIG_DIR": "/tmp/opencode"
                },
                "capturedAt": 9,
                "source": "environment"
              }
            }
          }
        }
        """
        try json.write(to: storeURL, atomically: true, encoding: .utf8)

        let detectedSnapshot = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "process-session",
            workingDirectory: "/tmp/repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "opencode",
                executablePath: "/opt/homebrew/bin/opencode",
                arguments: ["/opt/homebrew/bin/opencode"],
                workingDirectory: "/tmp/repo",
                environment: ["PATH": "/opt/homebrew/bin:/usr/bin"],
                capturedAt: 999,
                source: "process"
            )
        )
        let index = RestorableAgentSessionIndex.load(
            homeDirectory: home.path,
            fileManager: fileManager,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [
                RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId): (
                    snapshot: detectedSnapshot,
                    updatedAt: 999,
                    processIDs: Set([123]),
                    sessionIDSource: .explicit
                ),
            ]
        )
        let snapshot = try XCTUnwrap(index.snapshot(workspaceId: workspaceId, panelId: panelId))

        XCTAssertEqual(snapshot.sessionId, "process-session")
        XCTAssertEqual(snapshot.launchCommand?.launcher, "opencode")
        XCTAssertEqual(snapshot.launchCommand?.source, "process")
    }

    func testRestorableAgentIndexUsesNewerProcessFallbackForPlainHookRecord() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-agent-hook-store-\(UUID().uuidString)", isDirectory: true)
        let storeDir = home.appendingPathComponent(".cmuxterm", isDirectory: true)
        try fileManager.createDirectory(at: storeDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }

        let workspaceId = UUID()
        let panelId = UUID()
        let storeURL = storeDir.appendingPathComponent("opencode-hook-sessions.json", isDirectory: false)
        let json = """
        {
          "version": 1,
          "sessions": {
            "old-hook-session": {
              "sessionId": "old-hook-session",
              "workspaceId": "\(workspaceId.uuidString)",
              "surfaceId": "\(panelId.uuidString)",
              "cwd": "/tmp/repo",
              "updatedAt": 10,
              "launchCommand": {
                "launcher": "opencode",
                "executablePath": "/opt/homebrew/bin/opencode",
                "arguments": ["/opt/homebrew/bin/opencode"],
                "workingDirectory": "/tmp/repo",
                "source": "environment"
              }
            }
          }
        }
        """
        try json.write(to: storeURL, atomically: true, encoding: .utf8)

        let detectedSnapshot = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "live-process-session",
            workingDirectory: "/tmp/repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "opencode",
                executablePath: "/opt/homebrew/bin/opencode",
                arguments: ["/opt/homebrew/bin/opencode"],
                workingDirectory: "/tmp/repo",
                environment: nil,
                capturedAt: nil,
                source: "process"
            )
        )
        let index = RestorableAgentSessionIndex.load(
            homeDirectory: home.path,
            fileManager: fileManager,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [
                RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId): (
                    snapshot: detectedSnapshot,
                    updatedAt: 999,
                    processIDs: Set([456]),
                    sessionIDSource: .explicit
                ),
            ]
        )
        let snapshot = try XCTUnwrap(index.snapshot(workspaceId: workspaceId, panelId: panelId))

        XCTAssertEqual(snapshot.sessionId, "live-process-session")
        XCTAssertEqual(snapshot.launchCommand?.source, "process")
    }

    func testAntigravityProcessDetectionDoesNotTreatTrailingFlagAsConversationID() throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let processId = 1_739_392_001
        let panelKey = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        let processSnapshot = CmuxTopProcessSnapshot(
            processes: [
                CmuxTopProcessInfo(
                    pid: processId,
                    parentPID: 1,
                    name: "agy",
                    path: "/usr/local/bin/agy",
                    ttyDevice: nil,
                    cmuxWorkspaceID: workspaceId,
                    cmuxSurfaceID: panelId,
                    cmuxAttributionReason: "cmux-test",
                    processGroupID: nil,
                    terminalProcessGroupID: nil,
                    cpuPercent: 0,
                    residentBytes: 0,
                    virtualBytes: 0,
                    threadCount: 1
                )
            ],
            sampledAt: Date(timeIntervalSince1970: 0),
            includesProcessDetails: true
        )
        let registry = CmuxVaultAgentRegistry(registrations: [.builtInAntigravity])

        func detectedSnapshot(arguments: [String]) -> SessionRestorableAgentSnapshot? {
            RestorableAgentSessionIndex.processDetectedSnapshots(
                registry: registry,
                fileManager: FileManager.default,
                processSnapshot: processSnapshot,
                capturedAt: 42,
                processArgumentsProvider: { requestedProcessId in
                    guard requestedProcessId == processId else { return nil }
                    return CmuxTopProcessArguments(
                        arguments: arguments,
                        environment: ["PWD": "/tmp/antigravity repo"]
                    )
                }
            )[panelKey]?.snapshot
        }

        XCTAssertNil(
            detectedSnapshot(arguments: ["/usr/local/bin/agy", "--conversation", "--sandbox", "danger-full-access"])
        )
        XCTAssertNil(
            detectedSnapshot(arguments: ["/usr/local/bin/agy", "--conversation=--sandbox"])
        )

        let validSnapshot = try XCTUnwrap(
            detectedSnapshot(arguments: ["/usr/local/bin/agy", "--conversation", "conversation-123", "--sandbox", "danger-full-access"])
        )
        XCTAssertEqual(validSnapshot.sessionId, "conversation-123")
        XCTAssertEqual(validSnapshot.workingDirectory, "/tmp/antigravity repo")
        XCTAssertEqual(validSnapshot.launchCommand?.launcher, "antigravity")
    }

}

final class SidebarDragFailsafePolicyTests: XCTestCase {
    func testRequestsClearWhenMonitorStartsAfterMouseRelease() {
        XCTAssertTrue(
            SidebarDragFailsafePolicy().shouldRequestClearWhenMonitoringStarts(
                isLeftMouseButtonDown: false
            )
        )
        XCTAssertFalse(
            SidebarDragFailsafePolicy().shouldRequestClearWhenMonitoringStarts(
                isLeftMouseButtonDown: true
            )
        )
    }

    func testRequestsClearForLeftMouseUpEventsOnly() {
        XCTAssertTrue(
            SidebarDragFailsafePolicy().shouldRequestClear(
                forMouseEventType: .leftMouseUp
            )
        )
        XCTAssertFalse(
            SidebarDragFailsafePolicy().shouldRequestClear(
                forMouseEventType: .leftMouseDragged
            )
        )
    }
}

extension SessionPersistenceTests {
    func testSurfaceResumeBindingStartupInputUsesExactCommand() {
        let binding = SurfaceResumeBindingSnapshot(
            name: "OpenCode",
            kind: "opencode",
            command: "opencode --session ses_123",
            cwd: "/tmp/project",
            checkpointId: "ses_123",
            source: "cli",
            updatedAt: 1_777_777_777
        )

        XCTAssertEqual(binding.startupInput, "opencode --session ses_123\n")
    }

    func testSurfaceResumeBindingStartupInputScopesEnvironmentToCommand() {
        let binding = SurfaceResumeBindingSnapshot(
            command: "cd '/tmp/project' && codex resume session",
            environment: [
                "SPACED": "  keep exact  ",
                "CODEX_HOME": "/tmp/codex home",
                "EMPTY": "",
                "ANTHROPIC_API_KEY": "should-not-persist",
            ]
        )

        XCTAssertEqual(
            binding.startupInput,
            "'/usr/bin/env' 'CODEX_HOME=/tmp/codex home' 'EMPTY=' 'SPACED=  keep exact  ' '/bin/zsh' '-lc' 'cd '\\''/tmp/project'\\'' && codex resume session'\n"
        )
    }

    func testAgentHookSurfaceResumeBindingStoresSanitizedCommand() throws {
        let binding = SurfaceResumeBindingSnapshot(
            command: "cd '/tmp/project' && codex resume session",
            cwd: "/tmp/project",
            source: "agent-hook",
            updatedAt: 1
        )

        XCTAssertEqual(
            binding.command,
            TerminalStartupWorkingDirectoryPrefix.prefix(
                "codex resume session",
                workingDirectory: "/tmp/project"
            )
        )

        let decoded = try JSONDecoder().decode(
            SurfaceResumeBindingSnapshot.self,
            from: Data(
                """
                {
                  "command": "cd '/tmp/project' && codex resume session",
                  "cwd": "/tmp/project",
                  "source": "agent-hook",
                  "updatedAt": 1
                }
                """.utf8
            )
        )

        XCTAssertEqual(
            decoded.command,
            TerminalStartupWorkingDirectoryPrefix.prefix(
                "codex resume session",
                workingDirectory: "/tmp/project"
            )
        )
    }

    func testAgentHookSurfaceResumeBindingDropsDuplicateWorkingDirectoryOption() {
        let binding = SurfaceResumeBindingSnapshot(
            command: "cd '/tmp/project' && codex resume session --append-system-prompt 'use C:\\tmp' --cd '/tmp/project' --model gpt-5.4",
            cwd: "/tmp/project",
            source: "agent-hook",
            updatedAt: 1
        )

        XCTAssertEqual(
            binding.command,
            TerminalStartupWorkingDirectoryPrefix.prefix(
                "codex resume session --append-system-prompt 'use C:\\tmp' --model gpt-5.4",
                workingDirectory: "/tmp/project"
            )
        )
    }

    func testAgentHookSurfaceResumeBindingPreservesShellOperatorsWhenDroppingDuplicateWorkingDirectoryOption() {
        let binding = SurfaceResumeBindingSnapshot(
            command: "cd '/tmp/project' && codex resume session --cd '/tmp/project' && echo done",
            cwd: "/tmp/project",
            source: "agent-hook",
            updatedAt: 1
        )

        XCTAssertEqual(
            binding.command,
            TerminalStartupWorkingDirectoryPrefix.prefix(
                "codex resume session && echo done",
                workingDirectory: "/tmp/project"
            )
        )
        XCTAssertFalse(binding.command.contains("'&&'"), binding.command)
    }

    func testAgentHookSurfaceResumeBindingCanonicalizesLegacyGuardForNonASCIIWorkingDirectory() {
        let cwd = "/tmp/\u{4E2D}\u{6587}\u{8DEF}\u{5F84}"
        let legacyQuotedCwd = "'\(cwd)'"
        let binding = SurfaceResumeBindingSnapshot(
            command: "{ cd -- \(legacyQuotedCwd) 2>/dev/null || [ ! -d \(legacyQuotedCwd) ]; } && codex resume session",
            cwd: cwd,
            source: "agent-hook",
            updatedAt: 1
        )

        XCTAssertEqual(
            binding.command,
            TerminalStartupWorkingDirectoryPrefix.prefix(
                "codex resume session",
                workingDirectory: cwd
            )
        )
        XCTAssertFalse(binding.command.contains(legacyQuotedCwd), binding.command)
    }

    // Regression for https://github.com/manaflow-ai/cmux/issues/6285: the cwd guard runs
    // verbatim in the user's login shell, which may be fish. fish has no POSIX `{ …; }`
    // command grouping (it uses `begin; …; end`) and errors before the agent launches.
    // The emitted guard must therefore avoid brace grouping entirely while keeping the
    // same `(cd || test) && cmd` semantics via a left-associative AND-OR list.
    func testWorkingDirectoryPrefixUsesNoPosixBraceGroupingForFishLoginShell() {
        let prefixed = TerminalStartupWorkingDirectoryPrefix.prefix(
            "claude --resume abc",
            workingDirectory: "/tmp/fish repo"
        )
        XCTAssertFalse(prefixed.contains("{ "), prefixed)
        XCTAssertFalse(prefixed.contains("; }"), prefixed)
        XCTAssertEqual(
            prefixed,
            "cd -- '/tmp/fish repo' 2>/dev/null || [ ! -d '/tmp/fish repo' ] && claude --resume abc"
        )
    }

    // A binding persisted by an older cmux with the legacy braced guard must be
    // canonicalized to the fish-safe unbraced form on the next agent-hook write so the
    // upgrade self-heals existing fish users.
    func testAgentHookSurfaceResumeBindingCanonicalizesLegacyBracedGuardToFishSafeForm() {
        let binding = SurfaceResumeBindingSnapshot(
            command: "{ cd -- '/tmp/fish repo' 2>/dev/null || [ ! -d '/tmp/fish repo' ]; } && codex resume session",
            cwd: "/tmp/fish repo",
            source: "agent-hook",
            updatedAt: 1
        )

        XCTAssertFalse(binding.command.contains("{ "), binding.command)
        XCTAssertEqual(
            binding.command,
            TerminalStartupWorkingDirectoryPrefix.prefix(
                "codex resume session",
                workingDirectory: "/tmp/fish repo"
            )
        )
    }

    func testAgentHookSurfaceResumeStartupInputRunsWhenSavedWorkingDirectoryWasDeleted() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-surface-resume-missing-cwd-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let deletedCwd = root.appendingPathComponent("deleted", isDirectory: true)
            .appendingPathComponent("repo", isDirectory: true)
        let outputURL = root.appendingPathComponent("codex-output.txt", isDirectory: false)
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let fakeCodex = bin.appendingPathComponent("codex", isDirectory: false)
        try """
        #!/bin/zsh
        print -r -- "$PWD|$*" > "$CMUX_FAKE_CODEX_OUTPUT"
        """.write(to: fakeCodex, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCodex.path)

        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "cd '\(deletedCwd.path)' && codex resume session-duplicate-turn --yolo",
            cwd: deletedCwd.path,
            checkpointId: "session-duplicate-turn",
            source: "agent-hook",
            environment: [
                "CLAUDE_CONFIG_DIR": root.appendingPathComponent("claude-profile", isDirectory: true).path
            ],
            autoResume: true
        )

        let startupInput = try XCTUnwrap(binding.startupInput)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", startupInput]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(bin.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["CMUX_FAKE_CODEX_OUTPUT"] = outputURL.path
        process.environment = environment
        let stderr = Pipe()
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let errorText = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, errorText)

        let output = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(output.contains("resume session-duplicate-turn --yolo"), output)
        XCTAssertFalse(output.hasPrefix("\(deletedCwd.path)|"), output)
    }

    func testSurfaceResumeBindingStartupInputUsesLauncherScriptWhenLong() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-surface-resume-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let longPath = "/tmp/" + String(repeating: "nested-path-", count: 120)
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume session --add-dir \(longPath)",
            environment: [
                "CODEX_HOME": "/tmp/codex home",
            ]
        )

        let inlineInput = try XCTUnwrap(binding.inlineStartupInput)
        XCTAssertGreaterThan(inlineInput.utf8.count, SurfaceResumeBindingSnapshot.maxInlineStartupInputBytes)

        let input = try XCTUnwrap(binding.startupInputWithLauncherScript(temporaryDirectory: tempDir))
        XCTAssertLessThanOrEqual(input.utf8.count, SurfaceResumeBindingSnapshot.maxInlineStartupInputBytes)
        XCTAssertTrue(input.hasPrefix("/bin/zsh '"))
        XCTAssertFalse(input.contains(longPath))

        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "/bin/zsh '"
        let scriptPath = String(trimmedInput.dropFirst(prefix.count).dropLast())
        let scriptContents = try String(contentsOfFile: scriptPath, encoding: .utf8)
        XCTAssertTrue(scriptContents.contains(longPath))
        XCTAssertTrue(scriptContents.contains("'CODEX_HOME=/tmp/codex home'"))
        XCTAssertTrue(scriptContents.contains("codex resume session"))
    }

    @MainActor
    func testSnapshotPrefersFreshProcessDetectedSurfaceResumeBinding() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        XCTAssertTrue(
            workspace.setSurfaceResumeBinding(
                SurfaceResumeBindingSnapshot(
                    name: "tmux",
                    kind: "tmux",
                    command: "tmux attach -t stale",
                    cwd: "/tmp/old",
                    checkpointId: "stale",
                    source: "process-detected",
                    updatedAt: 10
                ),
                panelId: panelId
            )
        )

        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: workspace.id, panelId: panelId): SurfaceResumeBindingSnapshot(
                name: "tmux",
                kind: "tmux",
                command: "tmux attach -t fresh",
                cwd: "/tmp/new",
                checkpointId: "fresh",
                source: "process-detected",
                updatedAt: 20
            ),
        ])
        let snapshot = workspace.sessionSnapshot(
            includeScrollback: false,
            surfaceResumeBindingIndex: bindingIndex
        )

        XCTAssertEqual(snapshot.panels.first?.terminal?.resumeBinding?.checkpointId, "fresh")
        XCTAssertEqual(snapshot.panels.first?.terminal?.resumeBinding?.command, "tmux attach -t fresh")
        XCTAssertEqual(
            workspace.sessionSnapshot(includeScrollback: false).panels.first?.terminal?.resumeBinding?.checkpointId,
            "fresh"
        )
    }

    @MainActor
    func testSnapshotUsesProcessDetectedSurfaceResumeBindingAfterWorkspaceMove() throws {
        let originalWorkspaceId = UUID()
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: originalWorkspaceId, panelId: panelId): SurfaceResumeBindingSnapshot(
                name: "tmux",
                kind: "tmux",
                command: "tmux attach -t moved",
                cwd: "/tmp/moved",
                checkpointId: "moved",
                source: "process-detected",
                updatedAt: 20
            ),
        ])
        let snapshot = workspace.sessionSnapshot(
            includeScrollback: false,
            surfaceResumeBindingIndex: bindingIndex
        )

        XCTAssertEqual(snapshot.panels.first?.terminal?.resumeBinding?.checkpointId, "moved")
        XCTAssertEqual(snapshot.panels.first?.terminal?.resumeBinding?.command, "tmux attach -t moved")
        XCTAssertEqual(
            workspace.sessionSnapshot(includeScrollback: false).panels.first?.terminal?.resumeBinding?.checkpointId,
            "moved"
        )
    }

    @MainActor
    func testSnapshotKeepsExplicitSurfaceResumeBindingOverDetectedBinding() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        XCTAssertTrue(
            workspace.setSurfaceResumeBinding(
                SurfaceResumeBindingSnapshot(
                    name: "Codex",
                    kind: "codex",
                    command: "codex resume explicit",
                    cwd: "/tmp/explicit",
                    checkpointId: "explicit",
                    source: "cli",
                    updatedAt: 10
                ),
                panelId: panelId
            )
        )

        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: workspace.id, panelId: panelId): SurfaceResumeBindingSnapshot(
                name: "tmux",
                kind: "tmux",
                command: "tmux attach -t detected",
                cwd: "/tmp/detected",
                checkpointId: "detected",
                source: "process-detected",
                updatedAt: 20
            ),
        ])
        let snapshot = workspace.sessionSnapshot(
            includeScrollback: false,
            surfaceResumeBindingIndex: bindingIndex
        )

        XCTAssertEqual(snapshot.panels.first?.terminal?.resumeBinding?.checkpointId, "explicit")
        XCTAssertEqual(snapshot.panels.first?.terminal?.resumeBinding?.command, "codex resume explicit")
    }

    @MainActor
    func testSnapshotPrefersProcessDetectedTmuxOverAgentHookBinding() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        XCTAssertTrue(
            workspace.setSurfaceResumeBinding(
                SurfaceResumeBindingSnapshot(
                    name: "Codex",
                    kind: "codex",
                    command: "codex resume session",
                    cwd: "/tmp/agent",
                    checkpointId: "session",
                    source: "agent-hook",
                    updatedAt: 10
                ),
                panelId: panelId
            )
        )

        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: workspace.id, panelId: panelId): SurfaceResumeBindingSnapshot(
                name: "tmux",
                kind: "tmux",
                command: "tmux attach -t detected",
                cwd: "/tmp/detected",
                checkpointId: "detected",
                source: "process-detected",
                autoResume: true,
                updatedAt: 20
            ),
        ])
        let snapshot = workspace.sessionSnapshot(
            includeScrollback: false,
            surfaceResumeBindingIndex: bindingIndex
        )

        XCTAssertEqual(snapshot.panels.first?.terminal?.resumeBinding?.checkpointId, "detected")
        XCTAssertEqual(snapshot.panels.first?.terminal?.resumeBinding?.command, "tmux attach -t detected")
        XCTAssertEqual(
            workspace.sessionSnapshot(includeScrollback: false).panels.first?.terminal?.resumeBinding?.checkpointId,
            "detected"
        )
    }

    @MainActor
    func testAutosaveFingerprintIgnoresSurfaceResumeBindingUpdatedAt() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let key = SurfaceResumeBindingIndex.PanelKey(workspaceId: workspace.id, panelId: panelId)
        let firstIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            key: SurfaceResumeBindingSnapshot(
                name: "tmux",
                kind: "tmux",
                command: "tmux attach -t work",
                cwd: "/tmp/project",
                checkpointId: "work",
                source: "process-detected",
                updatedAt: 10
            ),
        ])
        let secondIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            key: SurfaceResumeBindingSnapshot(
                name: "tmux",
                kind: "tmux",
                command: "tmux attach -t work",
                cwd: "/tmp/project",
                checkpointId: "work",
                source: "process-detected",
                updatedAt: 20
            ),
        ])

        XCTAssertEqual(
            manager.sessionAutosaveFingerprint(surfaceResumeBindingIndex: firstIndex),
            manager.sessionAutosaveFingerprint(surfaceResumeBindingIndex: secondIndex)
        )
    }

    @MainActor
    func testAutosaveFingerprintIncludesManualSurfaceResumeBindingUpdatedAt() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let key = SurfaceResumeBindingIndex.PanelKey(workspaceId: workspace.id, panelId: panelId)
        let firstIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            key: SurfaceResumeBindingSnapshot(
                name: "custom",
                kind: "custom",
                command: "echo one",
                cwd: "/tmp/project",
                checkpointId: "custom",
                source: "cli",
                updatedAt: 10
            ),
        ])
        let secondIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            key: SurfaceResumeBindingSnapshot(
                name: "custom",
                kind: "custom",
                command: "echo one",
                cwd: "/tmp/project",
                checkpointId: "custom",
                source: "cli",
                updatedAt: 20
            ),
        ])

        XCTAssertNotEqual(
            manager.sessionAutosaveFingerprint(surfaceResumeBindingIndex: firstIndex),
            manager.sessionAutosaveFingerprint(surfaceResumeBindingIndex: secondIndex)
        )
    }

    @MainActor
    func testAutosaveFingerprintUsesEffectiveSurfaceResumeBinding() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        XCTAssertTrue(
            workspace.setSurfaceResumeBinding(
                SurfaceResumeBindingSnapshot(
                    name: "tmux",
                    kind: "tmux",
                    command: "tmux attach -t stale",
                    cwd: "/tmp/stale",
                    checkpointId: "stale",
                    source: "process-detected",
                    updatedAt: 10
                ),
                panelId: panelId
            )
        )

        let key = SurfaceResumeBindingIndex.PanelKey(workspaceId: workspace.id, panelId: panelId)
        let firstIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            key: SurfaceResumeBindingSnapshot(
                name: "tmux",
                kind: "tmux",
                command: "tmux attach -t first",
                cwd: "/tmp/first",
                checkpointId: "first",
                source: "process-detected",
                updatedAt: 20
            ),
        ])
        let secondIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            key: SurfaceResumeBindingSnapshot(
                name: "tmux",
                kind: "tmux",
                command: "tmux attach -t second",
                cwd: "/tmp/second",
                checkpointId: "second",
                source: "process-detected",
                updatedAt: 30
            ),
        ])

        XCTAssertNotEqual(
            manager.sessionAutosaveFingerprint(surfaceResumeBindingIndex: firstIndex),
            manager.sessionAutosaveFingerprint(surfaceResumeBindingIndex: secondIndex)
        )
    }

    @MainActor
    func testAutosaveFingerprintIncludesSurfaceResumeBindingEnvironment() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let key = SurfaceResumeBindingIndex.PanelKey(workspaceId: workspace.id, panelId: panelId)
        let firstIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            key: SurfaceResumeBindingSnapshot(
                name: "Codex",
                kind: "codex",
                command: "codex resume session",
                cwd: "/tmp/project",
                checkpointId: "session",
                source: "agent-hook",
                environment: ["CODEX_HOME": "/tmp/codex-a"],
                updatedAt: 10
            ),
        ])
        let secondIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            key: SurfaceResumeBindingSnapshot(
                name: "Codex",
                kind: "codex",
                command: "codex resume session",
                cwd: "/tmp/project",
                checkpointId: "session",
                source: "agent-hook",
                environment: ["CODEX_HOME": "/tmp/codex-b"],
                updatedAt: 10
            ),
        ])

        XCTAssertNotEqual(
            manager.sessionAutosaveFingerprint(surfaceResumeBindingIndex: firstIndex),
            manager.sessionAutosaveFingerprint(surfaceResumeBindingIndex: secondIndex)
        )
    }

    @MainActor
    func testAutosaveFingerprintIncludesSurfaceResumeBindingAutoResumeTrust() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let key = SurfaceResumeBindingIndex.PanelKey(workspaceId: workspace.id, panelId: panelId)
        let untrustedIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            key: SurfaceResumeBindingSnapshot(
                name: "tmux",
                kind: "tmux",
                command: "tmux attach -t work",
                cwd: "/tmp/project",
                checkpointId: "work",
                source: "process-detected",
                updatedAt: 10
            ),
        ])
        let trustedIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            key: SurfaceResumeBindingSnapshot(
                name: "tmux",
                kind: "tmux",
                command: "tmux attach -t work",
                cwd: "/tmp/project",
                checkpointId: "work",
                source: "process-detected",
                autoResume: true,
                updatedAt: 10
            ),
        ])

        XCTAssertNotEqual(
            manager.sessionAutosaveFingerprint(surfaceResumeBindingIndex: untrustedIndex),
            manager.sessionAutosaveFingerprint(surfaceResumeBindingIndex: trustedIndex)
        )
    }

    @MainActor
    func testAutosaveFingerprintIncludesTextBoxDraftContent() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let terminalPanel = try XCTUnwrap(workspace.terminalPanel(for: panelId))

        let baselineFingerprint = manager.sessionAutosaveFingerprint()
        terminalPanel.restoreSessionTextBoxDraft(SessionTextBoxInputDraftSnapshot(
            isActive: true,
            parts: [.text("draft one")]
        ))
        let firstTextFingerprint = manager.sessionAutosaveFingerprint()
        XCTAssertNotEqual(baselineFingerprint, firstTextFingerprint)

        terminalPanel.restoreSessionTextBoxDraft(SessionTextBoxInputDraftSnapshot(
            isActive: true,
            parts: [.text("draft two")]
        ))
        let secondTextFingerprint = manager.sessionAutosaveFingerprint()
        XCTAssertNotEqual(firstTextFingerprint, secondTextFingerprint)

        let attachment = SessionTextBoxInputAttachmentSnapshot(
            displayName: "moon.png",
            submissionText: "/tmp/moon.png",
            submissionPath: "/tmp/moon.png",
            localPath: "/tmp/moon.png",
            cleanupLocalPathWhenDisposed: false
        )
        terminalPanel.restoreSessionTextBoxDraft(SessionTextBoxInputDraftSnapshot(
            isActive: true,
            parts: [.text("look "), .attachment(attachment)]
        ))
        let imageDraftFingerprint = manager.sessionAutosaveFingerprint()
        XCTAssertNotEqual(secondTextFingerprint, imageDraftFingerprint)

        terminalPanel.restoreSessionTextBoxDraft(SessionTextBoxInputDraftSnapshot(
            isActive: false,
            parts: [.text("look "), .attachment(attachment)]
        ))
        XCTAssertNotEqual(imageDraftFingerprint, manager.sessionAutosaveFingerprint())
    }

    func testSurfaceResumeBindingPreservesExactNonSensitiveEnvironmentValues() {
        let binding = SurfaceResumeBindingSnapshot(
            command: "codex resume session",
            environment: [
                " EMPTY ": "",
                "SPACED": "  keep exact  ",
                "PLAIN": "value",
                "MULTILINE": "line\nbreak",
                "NULL_BYTE": "bad\u{0}value",
                "ANTHROPIC_API_KEY": "should-not-persist",
                "SERVICE_TOKEN": "should-not-persist",
            ]
        )

        XCTAssertEqual(binding.environment?["EMPTY"], "")
        XCTAssertEqual(binding.environment?["SPACED"], "  keep exact  ")
        XCTAssertEqual(binding.environment?["PLAIN"], "value")
        XCTAssertNil(binding.environment?["MULTILINE"])
        XCTAssertNil(binding.environment?["NULL_BYTE"])
        XCTAssertNil(binding.environment?["ANTHROPIC_API_KEY"])
        XCTAssertNil(binding.environment?["SERVICE_TOKEN"])
    }

    func testSurfaceResumeApprovalAutoPolicyAppliesSignedPrefix() throws {
        let storeURL = try makeSurfaceResumeApprovalStoreURL()
        let secret = Data("approval-secret".utf8)
        let binding = SurfaceResumeBindingSnapshot(
            name: "tmux work",
            kind: "tmux",
            command: "tmux attach -t 'work session'",
            cwd: "/tmp/project",
            source: "cli",
            environment: ["PATH": "/usr/bin:/bin"]
        )

        let record = try XCTUnwrap(SurfaceResumeApprovalStore.approve(
            binding: binding,
            policy: .auto,
            commandPrefix: ["tmux", "attach"],
            fileURL: storeURL,
            signingSecret: secret
        ))
        XCTAssertTrue(record.hasValidSignature(secret: secret))

        let effectiveBinding = SurfaceResumeApprovalStore.applyingStoredApproval(
            to: binding,
            fileURL: storeURL,
            signingSecret: secret
        )
        XCTAssertEqual(effectiveBinding.approvalPolicy, .auto)
        XCTAssertEqual(effectiveBinding.approvalRecordId, record.id)
        XCTAssertTrue(effectiveBinding.allowsAutomaticResume)

        let changedEnvironmentBinding = SurfaceResumeBindingSnapshot(
            name: "tmux work",
            kind: "tmux",
            command: "tmux attach -t 'work session'",
            cwd: "/tmp/project",
            source: "cli",
            environment: ["PATH": "/tmp/bin"]
        )
        let changedEnvironmentEffectiveBinding = SurfaceResumeApprovalStore.applyingStoredApproval(
            to: changedEnvironmentBinding,
            fileURL: storeURL,
            signingSecret: secret
        )
        XCTAssertEqual(changedEnvironmentEffectiveBinding.approvalPolicy, .manual)
        XCTAssertFalse(changedEnvironmentEffectiveBinding.allowsAutomaticResume)
    }

    func testSurfaceResumeApprovalRejectsTamperedRecord() throws {
        let storeURL = try makeSurfaceResumeApprovalStoreURL()
        let secret = Data("approval-secret".utf8)
        let binding = SurfaceResumeBindingSnapshot(
            command: "tmux attach -t work",
            cwd: "/tmp/project",
            source: "cli"
        )

        var record = try XCTUnwrap(SurfaceResumeApprovalStore.approve(
            binding: binding,
            policy: .manual,
            fileURL: storeURL,
            signingSecret: secret
        ))
        record.policy = .auto
        let encoder = JSONEncoder()
        let data = try encoder.encode(SurfaceResumeApprovalStore.StoredFile(version: 1, records: [record]))
        try data.write(to: storeURL, options: [.atomic])

        let effectiveBinding = SurfaceResumeApprovalStore.applyingStoredApproval(
            to: binding,
            fileURL: storeURL,
            signingSecret: secret
        )
        XCTAssertEqual(effectiveBinding.approvalPolicy, .manual)
        XCTAssertNil(effectiveBinding.approvalRecordId)
        XCTAssertFalse(effectiveBinding.allowsAutomaticResume)
    }

    func testSurfaceResumeApprovalMissingRecordResetsStalePromptPolicy() throws {
        let binding = SurfaceResumeBindingSnapshot(
            command: "tmux attach -t work",
            cwd: "/tmp/project",
            source: "cli",
            autoResume: false,
            approvalPolicy: .prompt,
            approvalRecordId: "deleted-record"
        )

        let effectiveBinding = SurfaceResumeApprovalStore.applyingStoredApproval(
            to: binding,
            fileURL: URL(fileURLWithPath: "/tmp/cmux-missing-\(UUID().uuidString).json"),
            signingSecret: Data("approval-secret".utf8)
        )
        XCTAssertEqual(effectiveBinding.approvalPolicy, .manual)
        XCTAssertNil(effectiveBinding.approvalRecordId)
        XCTAssertFalse(effectiveBinding.allowsAutomaticResume)
    }

    func testSurfaceResumeApprovalDoesNotPromptForExplicitCLICommand() throws {
        let binding = SurfaceResumeBindingSnapshot(
            command: "tmux attach -t work",
            cwd: "/tmp/project",
            source: "cli"
        )

        XCTAssertFalse(SurfaceResumeApprovalStore.shouldPromptForProposal(
            binding: binding,
            existingRecord: nil,
            isMainThread: true,
            isRunningTests: false
        ))
    }

    func testSurfaceResumeApprovalCreatesManualRecordForPromptlessCLICommand() throws {
        let storeURL = try makeSurfaceResumeApprovalStoreURL()
        let secret = Data("approval-secret".utf8)
        let binding = SurfaceResumeBindingSnapshot(
            name: "tmux work",
            kind: "tmux",
            command: "tmux attach -t work",
            cwd: "/tmp/project",
            source: "cli",
            environment: ["PATH": "/usr/bin:/bin"]
        )

        let effectiveBinding = try XCTUnwrap(SurfaceResumeApprovalStore.applyingPromptlessCLIManualApprovalIfNeeded(
            to: binding,
            existingRecord: nil,
            fileURL: storeURL,
            signingSecret: secret
        ))
        XCTAssertEqual(effectiveBinding.approvalPolicy, .manual)
        XCTAssertFalse(effectiveBinding.allowsAutomaticResume)
        XCTAssertNotNil(effectiveBinding.approvalRecordId)

        let records = SurfaceResumeApprovalStore.validRecords(
            fileURL: storeURL,
            signingSecret: secret
        )
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(record.policy, .manual)
        XCTAssertEqual(record.source, "cli")
        XCTAssertEqual(record.commandPrefixText, "tmux attach -t work")
        XCTAssertEqual(effectiveBinding.approvalRecordId, record.id)

        XCTAssertNil(SurfaceResumeApprovalStore.applyingPromptlessCLIManualApprovalIfNeeded(
            to: binding,
            existingRecord: record,
            fileURL: storeURL,
            signingSecret: secret
        ))
    }

    func testSurfaceResumeApprovalWritesRecordsIntoCmuxJSON() throws {
        let settingsURL = try makeSurfaceResumeApprovalCmuxSettingsURL()
        let secret = Data("approval-secret".utf8)
        let initialSettings = """
        {
          "$schema": "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux.schema.json",
          // keep root comment
          "schemaVersion": 1,
          "terminal": {
            // keep terminal comment
            "showScrollBar": false
          }
        }
        """.replacingOccurrences(of: "\n", with: "\r\n")
        try initialSettings.write(to: settingsURL, atomically: true, encoding: .utf8)

        let binding = SurfaceResumeBindingSnapshot(
            name: "tmux work",
            kind: "tmux",
            command: "tmux attach -t work",
            cwd: "/tmp/project",
            source: "cli",
            environment: ["PATH": "/usr/bin:/bin"]
        )

        let record = try XCTUnwrap(SurfaceResumeApprovalStore.approve(
            binding: binding,
            policy: .auto,
            commandPrefix: ["tmux", "attach"],
            fileURL: settingsURL,
            signingSecret: secret
        ))

        let root = try jsonObject(at: settingsURL)
        let terminal = try XCTUnwrap(root["terminal"] as? [String: Any])
        XCTAssertEqual(terminal["showScrollBar"] as? Bool, false)
        let storedRecords = try XCTUnwrap(terminal["resumeCommands"] as? [[String: Any]])
        XCTAssertEqual(storedRecords.count, 1)
        XCTAssertEqual(storedRecords.first?["id"] as? String, record.id)
        let updatedSettings = try String(contentsOf: settingsURL, encoding: .utf8)
        XCTAssertTrue(updatedSettings.contains("// keep root comment"))
        XCTAssertTrue(updatedSettings.contains("// keep terminal comment"))
        XCTAssertTrue(updatedSettings.contains("\r\n    \"resumeCommands\""))

        let validRecords = SurfaceResumeApprovalStore.validRecords(
            fileURL: settingsURL,
            signingSecret: secret
        )
        XCTAssertEqual(validRecords.map(\.id), [record.id])
        XCTAssertEqual(validRecords.first?.policy, .auto)
    }

    func testSurfaceResumeApprovalWritesNonUTF8CmuxJSON() throws {
        let settingsURL = try makeSurfaceResumeApprovalCmuxSettingsURL()
        let secret = Data("approval-secret".utf8)
        let initialSettings = """
        {
          "$schema": "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux.schema.json",
          // keep utf16 comment
          "schemaVersion": 1,
          "terminal": {
            "showScrollBar": false
          }
        }
        """
        try XCTUnwrap(initialSettings.data(using: .utf16LittleEndian))
            .write(to: settingsURL, options: [.atomic])

        let binding = SurfaceResumeBindingSnapshot(
            name: "tmux work",
            kind: "tmux",
            command: "tmux attach -t work",
            cwd: "/tmp/project",
            source: "cli",
            environment: ["PATH": "/usr/bin:/bin"]
        )

        let record = try XCTUnwrap(SurfaceResumeApprovalStore.approve(
            binding: binding,
            policy: .auto,
            commandPrefix: ["tmux", "attach"],
            fileURL: settingsURL,
            signingSecret: secret
        ))

        let updatedData = try Data(contentsOf: settingsURL)
        let updatedSettings = try XCTUnwrap(String(data: updatedData, encoding: .utf16LittleEndian))
        XCTAssertTrue(updatedSettings.contains("// keep utf16 comment"))
        XCTAssertTrue(updatedSettings.contains("\"resumeCommands\""))
        let root = try jsonObject(at: settingsURL)
        let terminal = try XCTUnwrap(root["terminal"] as? [String: Any])
        let storedRecords = try XCTUnwrap(terminal["resumeCommands"] as? [[String: Any]])
        XCTAssertEqual(storedRecords.first?["id"] as? String, record.id)
    }

    func testSurfaceResumeApprovalMigratesLegacyRecordsIntoCmuxJSON() throws {
        let settingsURL = try makeSurfaceResumeApprovalCmuxSettingsURL()
        let legacyURL = settingsURL.deletingLastPathComponent()
            .appendingPathComponent("resume-commands.json", isDirectory: false)
        let secret = Data("approval-secret".utf8)
        try """
        {
          "$schema": "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux.schema.json",
          // keep migration comment
          "schemaVersion": 1,
          "rightSidebar": {
            "width": 320
          }
        }
        """.write(to: settingsURL, atomically: true, encoding: .utf8)

        let binding = SurfaceResumeBindingSnapshot(
            name: "tmux work",
            kind: "tmux",
            command: "tmux attach -t work",
            cwd: "/tmp/project",
            source: "cli",
            environment: ["PATH": "/usr/bin:/bin"]
        )

        let record = try XCTUnwrap(SurfaceResumeApprovalStore.approve(
            binding: binding,
            policy: .auto,
            commandPrefix: ["tmux", "attach"],
            fileURL: legacyURL,
            signingSecret: secret
        ))

        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertTrue(SurfaceResumeApprovalStore.migrateLegacyRecordsIfNeeded(
            fileURL: settingsURL,
            legacyFileURL: legacyURL
        ))

        let root = try jsonObject(at: settingsURL)
        let terminal = try XCTUnwrap(root["terminal"] as? [String: Any])
        let rightSidebar = try XCTUnwrap(root["rightSidebar"] as? [String: Any])
        XCTAssertEqual((rightSidebar["width"] as? NSNumber)?.intValue, 320)
        let storedRecords = try XCTUnwrap(terminal["resumeCommands"] as? [[String: Any]])
        XCTAssertEqual(storedRecords.count, 1)
        XCTAssertEqual(storedRecords.first?["id"] as? String, record.id)
        let updatedSettings = try String(contentsOf: settingsURL, encoding: .utf8)
        XCTAssertTrue(updatedSettings.contains("// keep migration comment"))

        let validRecords = SurfaceResumeApprovalStore.validRecords(
            fileURL: settingsURL,
            signingSecret: secret
        )
        XCTAssertEqual(validRecords.map(\.id), [record.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))

        XCTAssertFalse(SurfaceResumeApprovalStore.migrateLegacyRecordsIfNeeded(
            fileURL: settingsURL,
            legacyFileURL: legacyURL
        ))
        let rootAfterSecondMigration = try jsonObject(at: settingsURL)
        let terminalAfterSecondMigration = try XCTUnwrap(rootAfterSecondMigration["terminal"] as? [String: Any])
        let storedRecordsAfterSecondMigration = try XCTUnwrap(terminalAfterSecondMigration["resumeCommands"] as? [[String: Any]])
        XCTAssertEqual(storedRecordsAfterSecondMigration.count, 1)
    }

    func testSurfaceResumeApprovalDoesNotOverwriteInvalidCmuxJSON() throws {
        let settingsURL = try makeSurfaceResumeApprovalCmuxSettingsURL()
        let legacyURL = settingsURL.deletingLastPathComponent()
            .appendingPathComponent("resume-commands.json", isDirectory: false)
        let secret = Data("approval-secret".utf8)
        let invalidSettingsData = Data("{ \"terminal\":".utf8)
        try invalidSettingsData.write(to: settingsURL, options: [.atomic])

        let binding = SurfaceResumeBindingSnapshot(
            name: "tmux work",
            kind: "tmux",
            command: "tmux attach -t work",
            cwd: "/tmp/project",
            source: "cli",
            environment: ["PATH": "/usr/bin:/bin"]
        )

        let legacyRecord = try XCTUnwrap(SurfaceResumeApprovalStore.approve(
            binding: binding,
            policy: .auto,
            commandPrefix: ["tmux", "attach"],
            fileURL: legacyURL,
            signingSecret: secret
        ))

        XCTAssertEqual(SurfaceResumeApprovalStore.loadRecords(
            fileURL: settingsURL,
            defaultSettingsURL: settingsURL
        ).map(\.id), [legacyRecord.id])
        XCTAssertEqual(try Data(contentsOf: settingsURL), invalidSettingsData)

        XCTAssertFalse(SurfaceResumeApprovalStore.migrateLegacyRecordsIfNeeded(
            fileURL: settingsURL,
            legacyFileURL: legacyURL
        ))
        XCTAssertEqual(try Data(contentsOf: settingsURL), invalidSettingsData)

        XCTAssertNotNil(SurfaceResumeApprovalStore.approve(
            binding: binding,
            policy: .auto,
            commandPrefix: ["tmux", "attach"],
            fileURL: settingsURL,
            signingSecret: secret
        ))
        XCTAssertEqual(try Data(contentsOf: settingsURL), invalidSettingsData)
        XCTAssertTrue(SurfaceResumeApprovalStore.validRecords(
            fileURL: settingsURL,
            signingSecret: secret
        ).isEmpty)
        XCTAssertEqual(SurfaceResumeApprovalStore.validRecords(
            fileURL: legacyURL,
            signingSecret: secret
        ).map(\.id), [legacyRecord.id])
    }

    func testSurfaceResumeApprovalPromptsForUnknownManualProposal() throws {
        let binding = SurfaceResumeBindingSnapshot(
            command: "tmux attach -t work",
            cwd: "/tmp/project",
            source: nil
        )

        XCTAssertTrue(SurfaceResumeApprovalStore.shouldPromptForProposal(
            binding: binding,
            existingRecord: nil,
            isMainThread: true,
            isRunningTests: false
        ))
    }

    func testSurfaceResumePromptPolicyDoesNotRunAutomaticallyUnderTest() throws {
        let storeURL = try makeSurfaceResumeApprovalStoreURL()
        let secret = Data("approval-secret".utf8)
        let binding = SurfaceResumeBindingSnapshot(
            command: "tmux attach -t work",
            cwd: "/tmp/project",
            source: "cli"
        )

        XCTAssertNotNil(SurfaceResumeApprovalStore.approve(
            binding: binding,
            policy: .prompt,
            fileURL: storeURL,
            signingSecret: secret
        ))

        let input = Workspace.surfaceResumeStartupInput(
            binding,
            autoResumeAgentSessions: true,
            approvalStoreURL: storeURL,
            approvalSigningSecret: secret
        )
        XCTAssertNil(input)
    }

    func testSurfaceResumePromptPolicyDoesNotPromptDuringSnapshot() throws {
        let storeURL = try makeSurfaceResumeApprovalStoreURL()
        let secret = Data("approval-secret".utf8)
        let binding = SurfaceResumeBindingSnapshot(
            command: "tmux attach -t work",
            cwd: "/tmp/project",
            source: "cli"
        )

        XCTAssertNotNil(SurfaceResumeApprovalStore.approve(
            binding: binding,
            policy: .prompt,
            fileURL: storeURL,
            signingSecret: secret
        ))

        let input = Workspace.surfaceResumeStartupInput(
            binding,
            autoResumeAgentSessions: true,
            promptForApproval: false,
            approvalStoreURL: storeURL,
            approvalSigningSecret: secret
        )
        XCTAssertNil(input)
    }

    func testProcessDetectedSurfaceResumeRemainsTrustedWithoutApprovalRecord() {
        let binding = SurfaceResumeBindingSnapshot(
            command: "tmux attach -t work",
            cwd: "/tmp/project",
            source: "process-detected"
        )

        let effectiveBinding = SurfaceResumeApprovalStore.applyingStoredApproval(
            to: binding,
            fileURL: URL(fileURLWithPath: "/tmp/cmux-missing-\(UUID().uuidString).json"),
            signingSecret: Data("approval-secret".utf8)
        )
        XCTAssertEqual(effectiveBinding.approvalPolicy, .auto)
        XCTAssertTrue(effectiveBinding.allowsAutomaticResume)
    }

    func testAgentHookSurfaceResumeAutoResumeRemainsTrustedWithoutApprovalRecord() {
        let binding = SurfaceResumeBindingSnapshot(
            command: "codex resume session",
            cwd: "/tmp/project",
            source: "agent-hook",
            autoResume: true
        )

        let effectiveBinding = SurfaceResumeApprovalStore.applyingStoredApproval(
            to: binding,
            fileURL: URL(fileURLWithPath: "/tmp/cmux-missing-\(UUID().uuidString).json"),
            signingSecret: Data("approval-secret".utf8)
        )
        XCTAssertEqual(effectiveBinding.approvalPolicy, .auto)
        XCTAssertTrue(effectiveBinding.allowsAutomaticResume)
    }

    func testHermesAgentHookSurfaceResumeBootstrapsSubrouterAndRewritesStaleCodexProvider() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hermes-surface-resume-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try """
        model = "gpt-5.5"
        openai_base_url = "http://subrouter-team:31415/v1"
        chatgpt_base_url = "http://subrouter-team:31415/backend-api"
        """.write(to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let binding = SurfaceResumeBindingSnapshot(
            kind: "hermes-agent",
            command: "cd '/tmp/project' && 'hermes' '--provider' 'openai-codex' '--resume' 'hermes-session-123'",
            cwd: "/tmp/project",
            source: "agent-hook",
            environment: [
                "CODEX_HOME": codexHome.path,
                "CUSTOM_BASE_URL": "http://subrouter-team:31415/v1",
            ],
            autoResume: true
        )

        let input = try XCTUnwrap(Workspace.surfaceResumeStartupInput(
            binding,
            autoResumeAgentSessions: true,
            promptForApproval: false
        ))

        XCTAssertTrue(input.contains("config set model.provider"))
        XCTAssertTrue(input.contains("config set model.base_url"))
        XCTAssertTrue(input.contains("config set model.api_mode"))
        XCTAssertTrue(input.contains("codex_responses"))
        XCTAssertTrue(input.contains("gpt-5.5"))
        XCTAssertTrue(input.contains("'--provider' '\\''custom'\\'''") || input.contains("'--provider' 'custom'"))
        XCTAssertFalse(input.contains("openai-codex"))
    }

    func testHermesAgentHookSurfaceResumeBootstrapUsesCapturedExecutable() throws {
        let binding = SurfaceResumeBindingSnapshot(
            kind: "hermes-agent",
            command: "cd '/tmp/hermes' && '/opt/homebrew/bin/hermes' '--provider' 'custom' '--resume' 'hermes-session-123'",
            cwd: "/tmp/hermes",
            source: "agent-hook",
            environment: [
                "CUSTOM_BASE_URL": "http://subrouter-team:31415/v1",
            ],
            autoResume: true
        )

        let input = try XCTUnwrap(Workspace.surfaceResumeStartupInput(
            binding,
            autoResumeAgentSessions: true,
            promptForApproval: false
        ))

        XCTAssertTrue(input.contains("'/opt/homebrew/bin/hermes' config set model.provider"))
        XCTAssertTrue(input.contains("'/opt/homebrew/bin/hermes' config set model.base_url"))
    }

    func testHermesAgentHookSurfaceResumeBootstrapStaysInsideCwdGuard() throws {
        let binding = SurfaceResumeBindingSnapshot(
            kind: "hermes-agent",
            command: "cd -- '/tmp/hermes project' 2>/dev/null || [ ! -d '/tmp/hermes project' ] && './hermes' '--provider' 'custom' '--resume' 'hermes-session-123'",
            cwd: "/tmp/hermes project",
            source: "agent-hook",
            environment: [
                "CUSTOM_BASE_URL": "http://subrouter-team:31415/v1",
            ],
            autoResume: true
        )

        let input = try XCTUnwrap(Workspace.surfaceResumeStartupInput(
            binding,
            autoResumeAgentSessions: true,
            promptForApproval: false
        ))

        let cdRange = try XCTUnwrap(input.range(of: "cd --"))
        let bootstrapRange = try XCTUnwrap(input.range(of: "config set model.provider"))
        XCTAssertLessThan(cdRange.lowerBound, bootstrapRange.lowerBound)
        XCTAssertTrue(input.contains("'./hermes' config set model.provider"))
        XCTAssertTrue(input.contains("'./hermes' '--provider' 'custom' '--resume'"))
    }

    func testHermesAgentHookSurfaceResumeReplacesExistingBootstrap() throws {
        let binding = SurfaceResumeBindingSnapshot(
            kind: "hermes-agent",
            command: "cd '/tmp/project' && '/opt/homebrew/bin/hermes' config set model.provider 'custom' >/dev/null && '/opt/homebrew/bin/hermes' config set model.base_url 'http://old-subrouter:9999/v1' >/dev/null && '/opt/homebrew/bin/hermes' config set model.api_mode 'codex_responses' >/dev/null && '/opt/homebrew/bin/hermes' '--provider' 'custom' '--resume' 'hermes-session-123'",
            cwd: "/tmp/project",
            source: "agent-hook",
            environment: [
                "CUSTOM_BASE_URL": "http://subrouter-team:31415/v1",
            ],
            autoResume: true
        )

        let input = try XCTUnwrap(Workspace.surfaceResumeStartupInput(
            binding,
            autoResumeAgentSessions: true,
            promptForApproval: false
        ))

        XCTAssertEqual(input.components(separatedBy: "config set model.provider").count - 1, 1)
        XCTAssertTrue(input.contains("http://subrouter-team:31415/v1"))
        XCTAssertFalse(input.contains("http://old-subrouter:9999/v1"))
    }

    func testHermesAgentHookSurfaceResumeHandlesMalformedTrailingEscape() throws {
        let binding = SurfaceResumeBindingSnapshot(
            kind: "hermes-agent",
            command: "cd '/tmp/project' && '/opt/homebrew/bin/hermes' \\",
            cwd: "/tmp/project",
            source: "agent-hook",
            environment: [
                "CUSTOM_BASE_URL": "http://subrouter-team:31415/v1",
            ],
            autoResume: true
        )

        let input = try XCTUnwrap(Workspace.surfaceResumeStartupInput(
            binding,
            autoResumeAgentSessions: true,
            promptForApproval: false
        ))

        XCTAssertTrue(input.contains("config set model.provider"))
    }

    func testHermesAgentHookSurfaceResumeSkipsCodexBootstrapForExplicitProvider() throws {
        let binding = SurfaceResumeBindingSnapshot(
            kind: "hermes-agent",
            command: "cd '/tmp/project' && '/opt/homebrew/bin/hermes' '--provider' 'anthropic' '--resume' 'hermes-session-123'",
            cwd: "/tmp/project",
            source: "agent-hook",
            environment: [
                "CUSTOM_BASE_URL": "http://subrouter-team:31415/v1",
            ],
            autoResume: true
        )

        let input = try XCTUnwrap(Workspace.surfaceResumeStartupInput(
            binding,
            autoResumeAgentSessions: true,
            promptForApproval: false
        ))

        XCTAssertFalse(input.contains("config set model.provider"))
        XCTAssertTrue(input.contains("'--provider' '\\''anthropic'\\'''") || input.contains("'--provider' 'anthropic'"))
    }

    private func makeSurfaceResumeApprovalStoreURL() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-surface-resume-approvals-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root.appendingPathComponent("resume-commands.json", isDirectory: false)
    }

    private func makeSurfaceResumeApprovalCmuxSettingsURL() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-surface-resume-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root.appendingPathComponent("cmux.json", isDirectory: false)
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let sanitized = try JSONCParser.preprocess(data: data)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: sanitized) as? [String: Any])
    }

    @MainActor
    func testRestoreRunsSurfaceResumeBindingFromBindingCwd() throws {
        let source = Workspace()
        let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
        source.panelDirectories[sourcePanelId] = "/tmp/old"
        let bindingCwd = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-surface-binding-cwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: bindingCwd, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: bindingCwd)
        }
        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: source.id, panelId: sourcePanelId): SurfaceResumeBindingSnapshot(
                name: "script",
                kind: "custom",
                command: "./resume.sh",
                cwd: bindingCwd.path,
                checkpointId: "script",
                source: "process-detected",
                autoResume: true,
                updatedAt: 10
            ),
        ])
        let snapshot = source.sessionSnapshot(
            includeScrollback: false,
            surfaceResumeBindingIndex: bindingIndex
        )

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
        let restoredPanel = try XCTUnwrap(restored.terminalPanel(for: restoredPanelId))

        XCTAssertEqual(restoredPanel.requestedWorkingDirectory, bindingCwd.path)
        XCTAssertTrue(restoredPanel.surface.debugInitialInputMetadata().hasInitialInput)
    }

    @MainActor
    func testRestoreDoesNotPassDeletedAgentHookCwdToTerminalRuntime() throws {
        try withAutoResumeAgentSessionsEnabled {
            let source = Workspace()
            let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
            let missingCwd = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-deleted-agent-hook-cwd-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("repo", isDirectory: true)
            let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
                SurfaceResumeBindingIndex.PanelKey(workspaceId: source.id, panelId: sourcePanelId): SurfaceResumeBindingSnapshot(
                    name: "Codex",
                    kind: "codex",
                    command: "cd '\(missingCwd.path)' && codex resume session-duplicate-turn --yolo",
                    cwd: missingCwd.path,
                    checkpointId: "session-duplicate-turn",
                    source: "agent-hook",
                    environment: [
                        "CLAUDE_CONFIG_DIR": "/tmp/claude-profile"
                    ],
                    autoResume: true,
                    updatedAt: 10
                ),
            ])
            let snapshot = source.sessionSnapshot(
                includeScrollback: false,
                surfaceResumeBindingIndex: bindingIndex
            )

            let restored = Workspace()
            restored.restoreSessionSnapshot(snapshot)
            let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
            let restoredPanel = try XCTUnwrap(restored.terminalPanel(for: restoredPanelId))
            let startupPayload = try restoredStartupPayload(for: restoredPanel)

            XCTAssertNil(restoredPanel.requestedWorkingDirectory)
            XCTAssertTrue(startupPayload.contains("codex resume session-duplicate-turn --yolo"), startupPayload)
            // The guard is the fish-safe, brace-free form (https://github.com/manaflow-ai/cmux/issues/6285):
            let guardStart = try XCTUnwrap(startupPayload.range(of: "cd -- "), startupPayload)
            let guardSuffix = String(startupPayload[guardStart.lowerBound...])
            let guardEnd = try XCTUnwrap(guardSuffix.range(of: "] &&")?.upperBound, guardSuffix)
            let guardSnippet = String(guardSuffix[..<guardEnd])
            XCTAssertTrue(guardSnippet.contains(missingCwd.path), guardSnippet)
            XCTAssertTrue(guardSnippet.contains("2>/dev/null || [ ! -d"), guardSnippet)
        }
    }

    @MainActor
    func testRestorePreservesUnmountedVolumeCwdBindingsWhenInitialReportsAreScrambled() throws {
        try withAutoResumeAgentSessionsEnabled {
            let manager = TabManager(autoWelcomeIfNeeded: false)
            let volumeName = "cmux-issue-5278-\(UUID().uuidString)"
            let expectedCwdsByWorkspaceAndPanel = try makeUnmountedVolumeCwdSnapshot(
                manager: manager,
                volumeName: volumeName
            )
            let snapshotData = try JSONEncoder().encode(manager.sessionSnapshot(includeScrollback: false))
            let decodedSnapshot = try JSONDecoder().decode(SessionTabManagerSnapshot.self, from: snapshotData)
            let restored = TabManager(autoWelcomeIfNeeded: false)

            restored.restoreSessionSnapshot(decodedSnapshot)
            let allExpectedCwds = expectedCwdsByWorkspaceAndPanel
                .values
                .flatMap { $0.values }
                .sorted()
            let rotatedExpectedCwds = Array(allExpectedCwds.dropFirst()) + [allExpectedCwds[0]]
            let scrambledCwds = Dictionary(uniqueKeysWithValues: zip(allExpectedCwds, rotatedExpectedCwds))
            for workspace in restored.tabs {
                let workspaceTitle = try XCTUnwrap(workspace.customTitle)
                let expectedPanelCwds = try XCTUnwrap(expectedCwdsByWorkspaceAndPanel[workspaceTitle])
                for (panelId, panelTitle) in workspace.panelCustomTitles {
                    let expectedCwd = try XCTUnwrap(expectedPanelCwds[panelTitle])
                    let scrambledCwd = try XCTUnwrap(scrambledCwds[expectedCwd])
                    restored.updateSurfaceDirectory(
                        tabId: workspace.id,
                        surfaceId: panelId,
                        directory: scrambledCwd
                    )
                }
            }

            let postReportSnapshot = restored.sessionSnapshot(includeScrollback: false)
            for workspaceSnapshot in postReportSnapshot.workspaces {
                let workspaceTitle = try XCTUnwrap(workspaceSnapshot.customTitle)
                let expectedPanelCwds = try XCTUnwrap(expectedCwdsByWorkspaceAndPanel[workspaceTitle])
                for panelSnapshot in workspaceSnapshot.panels {
                    let panelTitle = try XCTUnwrap(panelSnapshot.customTitle)
                    let expectedCwd = try XCTUnwrap(expectedPanelCwds[panelTitle])
                    XCTAssertEqual(panelSnapshot.directory, expectedCwd, "\(workspaceTitle) / \(panelTitle)")
                    XCTAssertEqual(panelSnapshot.terminal?.workingDirectory, expectedCwd, "\(workspaceTitle) / \(panelTitle)")
                    XCTAssertEqual(panelSnapshot.terminal?.resumeBinding?.cwd, expectedCwd, "\(workspaceTitle) / \(panelTitle)")
                }
            }
        }
    }

    @MainActor
    private func withAutoResumeAgentSessionsEnabled<T>(_ body: () throws -> T) rethrows -> T {
        let defaults = UserDefaults.standard
        let key = AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey
        let previous = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        return try body()
    }

    @MainActor
    private func restoredStartupPayload(for panel: TerminalPanel) throws -> String {
        if let input = panel.surface.debugInitialInputForTesting() {
            return input
        }

        let command = try XCTUnwrap(panel.surface.debugInitialCommand())
        let launcherPrefix = "/bin/zsh '"
        guard command.hasPrefix(launcherPrefix), command.hasSuffix("'") else {
            return try XCTUnwrap(
                Optional<String>.none,
                "Unexpected restored startup command format: \(command)"
            )
        }
        let scriptPath = String(command.dropFirst(launcherPrefix.count).dropLast())
        return try String(contentsOfFile: scriptPath, encoding: .utf8)
    }

    @MainActor
    private func makeUnmountedVolumeCwdSnapshot(
        manager: TabManager,
        volumeName: String
    ) throws -> [String: [String: String]] {
        let workspaces = [
            try XCTUnwrap(manager.selectedWorkspace),
            manager.addWorkspace(inheritWorkingDirectory: false, select: true, autoWelcomeIfNeeded: false),
            manager.addWorkspace(inheritWorkingDirectory: false, select: true, autoWelcomeIfNeeded: false),
        ]
        var expected: [String: [String: String]] = [:]

        for (workspaceIndex, workspace) in workspaces.enumerated() {
            let workspaceTitle = "Project \(workspaceIndex + 1)"
            workspace.setCustomTitle(workspaceTitle)
            let paneId = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
            let firstPanelId = try XCTUnwrap(workspace.focusedPanelId)
            let secondPanelId = try XCTUnwrap(workspace.newTerminalSurface(inPane: paneId, focus: true)?.id)
            for (panelIndex, panelId) in [firstPanelId, secondPanelId].enumerated() {
                let panelTitle = "Tab \(workspaceIndex + 1).\(panelIndex + 1)"
                let cwd = "/Volumes/\(volumeName)/project-\(workspaceIndex + 1)/tab-\(panelIndex + 1)"
                workspace.setPanelCustomTitle(panelId: panelId, title: panelTitle)
                workspace.updatePanelDirectory(panelId: panelId, directory: cwd)
                XCTAssertTrue(
                    workspace.setSurfaceResumeBinding(
                        SurfaceResumeBindingSnapshot(
                            name: "Codex",
                            kind: "codex",
                            command: "cd '\(cwd)' && codex resume session-\(workspaceIndex)-\(panelIndex) --yolo",
                            cwd: cwd,
                            checkpointId: "session-\(workspaceIndex)-\(panelIndex)",
                            source: "agent-hook",
                            autoResume: true,
                            updatedAt: 10 + Double(workspaceIndex * 10 + panelIndex)
                        ),
                        panelId: panelId
                    )
                )
                expected[workspaceTitle, default: [:]][panelTitle] = cwd
            }
        }

        return expected
    }

    @MainActor
    func testRestoreDoesNotRunResumeBindingForHibernatedSnapshot() throws {
        let source = Workspace()
        let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
        let sourcePanel = try XCTUnwrap(source.terminalPanel(for: sourcePanelId))
        let sourcePaneId = try XCTUnwrap(source.paneId(forPanelId: sourcePanelId))
        _ = try XCTUnwrap(source.newTerminalSurface(inPane: sourcePaneId, focus: true))
        let agent = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-hibernated-restore",
            workingDirectory: "/tmp/agent",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/usr/local/bin/codex",
                arguments: ["/usr/local/bin/codex"],
                workingDirectory: "/tmp/agent",
                environment: nil,
                capturedAt: nil,
                source: nil
            )
        )
        sourcePanel.enterAgentHibernation(
            agent: agent,
            lastActivityAt: Date(timeIntervalSince1970: 10),
            hibernatedAt: Date(timeIntervalSince1970: 20)
        )
        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: source.id, panelId: sourcePanelId): SurfaceResumeBindingSnapshot(
                name: "script",
                kind: "custom",
                command: "./resume.sh",
                cwd: "/tmp/binding",
                checkpointId: "script",
                source: "process-detected",
                autoResume: true,
                updatedAt: 10
            ),
        ])
        let snapshot = source.sessionSnapshot(
            includeScrollback: false,
            surfaceResumeBindingIndex: bindingIndex
        )
        let sourcePanelSnapshot = try XCTUnwrap(snapshot.panels.first { $0.id == sourcePanelId })
        XCTAssertNotNil(sourcePanelSnapshot.terminal?.hibernation)
        XCTAssertNotNil(sourcePanelSnapshot.terminal?.agent?.resumeCommand)
        XCTAssertNotEqual(snapshot.focusedPanelId, sourcePanelId)

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        let restoredSnapshot = restored.sessionSnapshot(includeScrollback: false)
        let restoredPanelSnapshot = try XCTUnwrap(
            restoredSnapshot.panels.first {
                $0.terminal?.resumeBinding?.command == "./resume.sh"
            }
        )
        let restoredPanel = try XCTUnwrap(restored.terminalPanel(for: restoredPanelSnapshot.id))

        XCTAssertFalse(restoredPanel.surface.debugInitialInputMetadata().hasInitialInput)
        XCTAssertEqual(restoredPanelSnapshot.terminal?.agent?.sessionId, "codex-hibernated-restore")
    }

    @MainActor
    func testRestoreDoesNotRunUntrustedSurfaceResumeBindingByDefault() throws {
        let source = Workspace()
        let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: source.id, panelId: sourcePanelId): SurfaceResumeBindingSnapshot(
                name: "script",
                kind: "custom",
                command: "./resume.sh",
                cwd: "/tmp/sticky",
                checkpointId: "script",
                source: "process-detected",
                updatedAt: 10
            ),
        ])
        let snapshot = source.sessionSnapshot(
            includeScrollback: false,
            surfaceResumeBindingIndex: bindingIndex
        )

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
        let restoredPanel = try XCTUnwrap(restored.terminalPanel(for: restoredPanelId))

        XCTAssertFalse(restoredPanel.surface.debugInitialInputMetadata().hasInitialInput)
        XCTAssertEqual(
            restored.sessionSnapshot(includeScrollback: false).panels.first?.terminal?.resumeBinding?.command,
            "./resume.sh"
        )
    }

    @MainActor
    func testRestoreScopesSurfaceResumeBindingEnvironmentToInitialInput() throws {
        let source = Workspace()
        let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: source.id, panelId: sourcePanelId): SurfaceResumeBindingSnapshot(
                name: "Codex",
                kind: "codex",
                command: "codex resume session",
                cwd: "/tmp/project",
                checkpointId: "session",
                source: "process-detected",
                environment: [
                    "CODEX_HOME": "/tmp/codex home",
                    "EMPTY": "",
                ],
                autoResume: true,
                updatedAt: 10
            ),
        ])
        let snapshot = source.sessionSnapshot(
            includeScrollback: false,
            surfaceResumeBindingIndex: bindingIndex
        )

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
        let restoredPanel = try XCTUnwrap(restored.terminalPanel(for: restoredPanelId))

        XCTAssertNil(restoredPanel.surface.debugAdditionalEnvironmentForTesting()["CODEX_HOME"])
        XCTAssertNil(restoredPanel.surface.debugAdditionalEnvironmentForTesting()["EMPTY"])
        XCTAssertEqual(
            restoredPanel.surface.debugInitialInputForTesting(),
            "'/usr/bin/env' 'CODEX_HOME=/tmp/codex home' 'EMPTY=' '/bin/zsh' '-lc' 'codex resume session'\n"
        )
    }

    @MainActor
    func testRestoreUsesLauncherScriptForLongSurfaceResumeBinding() throws {
        let source = Workspace()
        let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
        let longPath = "/tmp/" + String(repeating: "nested-project-", count: 120)
        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: source.id, panelId: sourcePanelId): SurfaceResumeBindingSnapshot(
                name: "Codex",
                kind: "codex",
                command: "codex resume session --add-dir \(longPath)",
                cwd: "/tmp/project",
                checkpointId: "session",
                source: "process-detected",
                environment: [
                    "CODEX_HOME": "/tmp/codex home",
                ],
                autoResume: true,
                updatedAt: 10
            ),
        ])
        let snapshot = source.sessionSnapshot(
            includeScrollback: false,
            surfaceResumeBindingIndex: bindingIndex
        )

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
        let restoredPanel = try XCTUnwrap(restored.terminalPanel(for: restoredPanelId))

        XCTAssertNil(restoredPanel.surface.debugAdditionalEnvironmentForTesting()["CODEX_HOME"])
        let input = try XCTUnwrap(restoredPanel.surface.debugInitialInputForTesting())
        XCTAssertTrue(input.hasPrefix("/bin/zsh '"))
        XCTAssertFalse(input.contains(longPath))

        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "/bin/zsh '"
        let scriptPath = String(trimmedInput.dropFirst(prefix.count).dropLast())
        defer { try? FileManager.default.removeItem(atPath: scriptPath) }
        let scriptContents = try String(contentsOfFile: scriptPath, encoding: .utf8)
        XCTAssertTrue(scriptContents.contains(longPath))
        XCTAssertTrue(scriptContents.contains("'CODEX_HOME=/tmp/codex home'"))
        XCTAssertTrue(scriptContents.contains("codex resume session"))
    }

    @MainActor
    func testRestoreRetainsProcessDetectedSurfaceResumeBindingBeforeRedetection() throws {
        let source = Workspace()
        let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: source.id, panelId: sourcePanelId): SurfaceResumeBindingSnapshot(
                name: "tmux",
                kind: "tmux",
                command: "tmux attach -t restored",
                cwd: "/tmp/project",
                checkpointId: "restored",
                source: "process-detected",
                updatedAt: 10
            ),
        ])
        let snapshot = source.sessionSnapshot(
            includeScrollback: false,
            surfaceResumeBindingIndex: bindingIndex
        )

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        let immediateSnapshot = restored.sessionSnapshot(includeScrollback: false)

        XCTAssertEqual(immediateSnapshot.panels.first?.terminal?.resumeBinding?.checkpointId, "restored")
        XCTAssertEqual(immediateSnapshot.panels.first?.terminal?.resumeBinding?.command, "tmux attach -t restored")
    }

    @MainActor
    func testSnapshotDropsStaleProcessDetectedSurfaceResumeBindingAfterCleanRedetection() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        XCTAssertTrue(
            workspace.setSurfaceResumeBinding(
                SurfaceResumeBindingSnapshot(
                    name: "tmux",
                    kind: "tmux",
                    command: "tmux attach -t stale",
                    cwd: "/tmp/stale",
                    checkpointId: "stale",
                    source: "process-detected",
                    updatedAt: 10
                ),
                panelId: panelId
            )
        )

        let snapshot = workspace.sessionSnapshot(
            includeScrollback: false,
            surfaceResumeBindingIndex: .empty
        )

        XCTAssertNil(snapshot.panels.first?.terminal?.resumeBinding)
        XCTAssertNil(workspace.sessionSnapshot(includeScrollback: false).panels.first?.terminal?.resumeBinding)
    }

    @MainActor
    func testSnapshotCachesNewProcessDetectedSurfaceResumeBindingForLaterNoScanSave() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: workspace.id, panelId: panelId): SurfaceResumeBindingSnapshot(
                name: "tmux",
                kind: "tmux",
                command: "tmux attach -t cached",
                cwd: "/tmp/project",
                checkpointId: "cached",
                source: "process-detected",
                updatedAt: 10
            ),
        ])

        let scannedSnapshot = workspace.sessionSnapshot(
            includeScrollback: false,
            surfaceResumeBindingIndex: bindingIndex
        )
        let laterSnapshot = workspace.sessionSnapshot(includeScrollback: false)

        XCTAssertEqual(scannedSnapshot.panels.first?.terminal?.resumeBinding?.checkpointId, "cached")
        XCTAssertEqual(laterSnapshot.panels.first?.terminal?.resumeBinding?.checkpointId, "cached")
    }

    @MainActor
    func testAppDelegateSnapshotPreservesRestoredProcessDetectedSurfaceResumeBindingBeforeScan() throws {
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        AppDelegate.shared = app
        defer {
            AppDelegate.shared = previousAppDelegate
        }

        let manager = TabManager(autoWelcomeIfNeeded: false)
        let windowId = app.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
        }

        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        XCTAssertTrue(
            workspace.setSurfaceResumeBinding(
                SurfaceResumeBindingSnapshot(
                    name: "tmux",
                    kind: "tmux",
                    command: "tmux attach -t restored",
                    cwd: "/tmp/project",
                    checkpointId: "restored",
                    source: "process-detected",
                    updatedAt: 10
                ),
                panelId: panelId
            )
        )

        let noScanSnapshot = try XCTUnwrap(app.debugBuildSessionSnapshotForTesting(includeScrollback: false))
        let noScanBinding = noScanSnapshot.windows.first?.tabManager.workspaces.first?.panels
            .first(where: { $0.id == panelId })?
            .terminal?
            .resumeBinding
        XCTAssertEqual(noScanBinding?.checkpointId, "restored")

        let cleanScanSnapshot = try XCTUnwrap(
            app.debugBuildSessionSnapshotForTesting(
                includeScrollback: false,
                surfaceResumeBindingIndex: .empty
            )
        )
        let cleanScanBinding = cleanScanSnapshot.windows.first?.tabManager.workspaces.first?.panels
            .first(where: { $0.id == panelId })?
            .terminal?
            .resumeBinding
        XCTAssertNil(cleanScanBinding)
    }

    func testTmuxProcessDetectedResumeBindingPreservesSocketFlags() throws {
        let binding = try XCTUnwrap(
            SurfaceResumeBindingIndex.tmuxResumeBindingForTesting(
                processName: "tmux: client",
                processPath: "/opt/homebrew/bin/tmux",
                arguments: ["/opt/homebrew/bin/tmux", "-L", "dev", "attach-session", "-t", "work"],
                environment: ["PWD": "/tmp/project"]
            )
        )

        XCTAssertEqual(binding.kind, "tmux")
        XCTAssertEqual(binding.source, "process-detected")
        XCTAssertEqual(binding.allowsAutomaticResume, true)
        XCTAssertEqual(binding.checkpointId, "work")
        XCTAssertEqual(binding.cwd, "/tmp/project")
        XCTAssertEqual(binding.command, "'/opt/homebrew/bin/tmux' '-L' 'dev' 'attach' '-t' 'work'")
    }

    func testTmuxProcessDetectedResumeBindingPreservesTmuxTmpdir() throws {
        let binding = try XCTUnwrap(
            SurfaceResumeBindingIndex.tmuxResumeBindingForTesting(
                processName: "tmux: client",
                processPath: "/opt/homebrew/bin/tmux",
                arguments: ["/opt/homebrew/bin/tmux", "-L", "dev", "attach-session", "-t", "work"],
                environment: [
                    "PWD": "/tmp/project",
                    "TMUX": "/tmp/tmux-current,123,0",
                    "TMUX_TMPDIR": "/var/folders/custom-tmux",
                ]
            )
        )

        XCTAssertEqual(binding.command, "'/opt/homebrew/bin/tmux' '-L' 'dev' 'attach' '-t' 'work'")
        XCTAssertEqual(binding.environment, ["TMUX_TMPDIR": "/var/folders/custom-tmux"])
        let startupInput = try XCTUnwrap(binding.startupInput)
        XCTAssertTrue(startupInput.contains("'TMUX_TMPDIR=/var/folders/custom-tmux'"), startupInput)
        XCTAssertFalse(startupInput.contains("TMUX="), startupInput)
    }

    func testTmuxProcessDetectedResumeBindingParsesAttachAlias() throws {
        let binding = try XCTUnwrap(
            SurfaceResumeBindingIndex.tmuxResumeBindingForTesting(
                processName: "tmux: client",
                processPath: "/opt/homebrew/bin/tmux",
                arguments: ["/opt/homebrew/bin/tmux", "a", "-t", "work"],
                environment: [:]
            )
        )

        XCTAssertEqual(binding.checkpointId, "work")
        XCTAssertEqual(binding.command, "'/opt/homebrew/bin/tmux' 'attach' '-t' 'work'")
    }

    func testTmuxProcessDetectedResumeBindingDoesNotUseProcessTitleAsExecutable() throws {
        let binding = try XCTUnwrap(
            SurfaceResumeBindingIndex.tmuxResumeBindingForTesting(
                processName: "tmux: client",
                processPath: "/opt/homebrew/bin/tmux",
                arguments: ["tmux: client", "attach-session", "-t", "work"],
                environment: [:]
            )
        )

        XCTAssertEqual(binding.command, "'/opt/homebrew/bin/tmux' 'attach' '-t' 'work'")
    }

    func testTmuxProcessDetectedResumeBindingDropsFullClientProcessTitle() throws {
        let binding = try XCTUnwrap(
            SurfaceResumeBindingIndex.tmuxResumeBindingForTesting(
                processName: "tmux: client (/dev/ttys001)",
                processPath: nil,
                arguments: ["tmux: client (/dev/ttys001)", "attach-session", "-t", "work"],
                environment: ["PWD": "/tmp/project"]
            )
        )

        XCTAssertEqual(binding.checkpointId, "work")
        XCTAssertEqual(binding.cwd, "/tmp/project")
        XCTAssertEqual(binding.command, "'tmux' 'attach' '-t' 'work'")
    }

    func testTmuxProcessDetectedResumeBindingRejectsFullServerProcessTitle() {
        let binding = SurfaceResumeBindingIndex.tmuxResumeBindingForTesting(
            processName: "tmux: server (/private/tmp/tmux-501/default)",
            processPath: nil,
            arguments: ["tmux: server (/private/tmp/tmux-501/default)"],
            environment: [:]
        )

        XCTAssertNil(binding)
    }

    func testTmuxProcessDetectedResumeBindingRejectsServerProcessTitle() {
        let binding = SurfaceResumeBindingIndex.tmuxResumeBindingForTesting(
            processName: "tmux: server",
            processPath: "/opt/homebrew/bin/tmux",
            arguments: ["tmux: server"],
            environment: [:]
        )

        XCTAssertNil(binding)
    }

    func testTmuxAttachFlagParserTreatsConfigFlagAsValueTaking() {
        let binding = SurfaceResumeBindingIndex.tmuxResumeBindingForTesting(
            processName: "tmux",
            processPath: nil,
            arguments: ["tmux", "new", "-fA"],
            environment: [:]
        )

        XCTAssertNil(binding)
    }

    func testTmuxAttachFlagParserTreatsShellCommandFlagAsValueTaking() throws {
        let binding = try XCTUnwrap(
            SurfaceResumeBindingIndex.tmuxResumeBindingForTesting(
                processName: "tmux",
                processPath: nil,
                arguments: ["tmux", "-c", "/bin/zsh", "attach", "-t", "work"],
                environment: [:]
            )
        )

        XCTAssertEqual(binding.checkpointId, "work")
        XCTAssertEqual(binding.command, "'tmux' 'attach' '-t' 'work'")
    }

    func testTmuxProcessDetectedResumeBindingRejectsUnnamedAttach() {
        let attachBinding = SurfaceResumeBindingIndex.tmuxResumeBindingForTesting(
            processName: "tmux",
            processPath: nil,
            arguments: ["tmux", "attach"],
            environment: [:]
        )
        let aliasBinding = SurfaceResumeBindingIndex.tmuxResumeBindingForTesting(
            processName: "tmux",
            processPath: nil,
            arguments: ["tmux", "a"],
            environment: [:]
        )

        XCTAssertNil(attachBinding)
        XCTAssertNil(aliasBinding)
    }

    func testTmuxProcessDetectedResumeBindingRejectsCommandlessClient() {
        let executableOnlyBinding = SurfaceResumeBindingIndex.tmuxResumeBindingForTesting(
            processName: "tmux",
            processPath: nil,
            arguments: ["tmux"],
            environment: [:]
        )
        let processTitleBinding = SurfaceResumeBindingIndex.tmuxResumeBindingForTesting(
            processName: "tmux: client",
            processPath: nil,
            arguments: ["tmux: client"],
            environment: [:]
        )

        XCTAssertNil(executableOnlyBinding)
        XCTAssertNil(processTitleBinding)
    }

    func testTmuxOptionValueDoesNotReadTargetFromConfigValue() {
        let binding = SurfaceResumeBindingIndex.tmuxResumeBindingForTesting(
            processName: "tmux",
            processPath: nil,
            arguments: ["tmux", "attach", "-factive-pane"],
            environment: [:]
        )

        XCTAssertNil(binding)
    }

    func testTmuxOptionValueStopsAtValueTakingClusterOption() {
        let binding = SurfaceResumeBindingIndex.tmuxResumeBindingForTesting(
            processName: "tmux",
            processPath: nil,
            arguments: ["tmux", "new", "-Ans"],
            environment: [:]
        )

        XCTAssertNil(binding)
    }

    func testTmuxOptionValueStopsAtCommandTerminator() {
        let attachBinding = SurfaceResumeBindingIndex.tmuxResumeBindingForTesting(
            processName: "tmux",
            processPath: nil,
            arguments: ["tmux", "attach", "--", "-t", "work"],
            environment: [:]
        )
        let newBinding = SurfaceResumeBindingIndex.tmuxResumeBindingForTesting(
            processName: "tmux",
            processPath: nil,
            arguments: ["tmux", "new", "-A", "--", "-s", "work"],
            environment: [:]
        )

        XCTAssertNil(attachBinding)
        XCTAssertNil(newBinding)
    }

    func testTmuxProcessDetectedResumeBindingRejectsUnnamedNewAttachSession() {
        let binding = SurfaceResumeBindingIndex.tmuxResumeBindingForTesting(
            processName: "tmux",
            processPath: nil,
            arguments: ["tmux", "new-session", "-A"],
            environment: [:]
        )

        XCTAssertNil(binding)
    }

    func testTmuxProcessDetectedResumeBindingParsesNewAttachSession() throws {
        let binding = try XCTUnwrap(
            SurfaceResumeBindingIndex.tmuxResumeBindingForTesting(
                processName: "tmux",
                processPath: nil,
                arguments: ["tmux", "new", "-As", "work"],
                environment: [:]
            )
        )

        XCTAssertEqual(binding.checkpointId, "work")
        XCTAssertEqual(binding.command, "'tmux' 'attach' '-t' 'work'")
    }

    func testTmuxProcessDetectedResumeBindingRejectsSessionNameThatLooksLikeAttachFlag() {
        let binding = SurfaceResumeBindingIndex.tmuxResumeBindingForTesting(
            processName: "tmux",
            processPath: nil,
            arguments: ["tmux", "new", "-sA"],
            environment: [:]
        )

        XCTAssertNil(binding)
    }

    func testMarkdownFileLinkResolverRecognizesMarkdownPathLikeStrings() {
        XCTAssertTrue(MarkdownPanelFileLinkResolver.isMarkdownPathLike("other-markdown.md"))
        XCTAssertTrue(MarkdownPanelFileLinkResolver.isMarkdownPathLike("test/markdown.md"))
        XCTAssertTrue(MarkdownPanelFileLinkResolver.isMarkdownPathLike("../notes/plan.mdx#section"))
        XCTAssertTrue(MarkdownPanelFileLinkResolver.isMarkdownPathLike("file:///tmp/plan.markdown"))

        XCTAssertFalse(MarkdownPanelFileLinkResolver.isMarkdownPathLike("https://example.com/plan.md"))
        XCTAssertFalse(MarkdownPanelFileLinkResolver.isMarkdownPathLike("mailto:person@example.com"))
        XCTAssertFalse(MarkdownPanelFileLinkResolver.isMarkdownPathLike("README.txt"))
        XCTAssertFalse(MarkdownPanelFileLinkResolver.isMarkdownPathLike("md"))
    }

    func testMarkdownFileLinkResolverPrefersCurrentMarkdownDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-markdown-link-resolver-\(UUID().uuidString)", isDirectory: true)
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        let cwdFile = root.appendingPathComponent("other-markdown.md")
        let adjacentFile = docs.appendingPathComponent("other-markdown.md")
        let openedFile = docs.appendingPathComponent("index.md")

        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try "cwd".write(to: cwdFile, atomically: true, encoding: .utf8)
        try "adjacent".write(to: adjacentFile, atomically: true, encoding: .utf8)
        try "index".write(to: openedFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolved = MarkdownPanelFileLinkResolver.resolve(
            rawPath: "other-markdown.md",
            relativeToMarkdownFile: openedFile.path
        )
        XCTAssertEqual(resolved, adjacentFile.path)
    }

    func testMarkdownFileLinkResolverFallsBackToProcessWorkingDirectory() throws {
        let originalCWD = FileManager.default.currentDirectoryPath
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-markdown-link-resolver-cwd-\(UUID().uuidString)", isDirectory: true)
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        let openedFile = docs.appendingPathComponent("index.md")
        let fallbackFile = root.appendingPathComponent("test/markdown.md")

        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fallbackFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "index".write(to: openedFile, atomically: true, encoding: .utf8)
        try "fallback".write(to: fallbackFile, atomically: true, encoding: .utf8)
        defer {
            FileManager.default.changeCurrentDirectoryPath(originalCWD)
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(root.path))

        let resolved = MarkdownPanelFileLinkResolver.resolve(
            rawPath: "test/markdown.md",
            relativeToMarkdownFile: openedFile.path
        )
        XCTAssertEqual(resolved, fallbackFile.path)
    }

    func testMarkdownFileLinkResolverRejectsMissingAndNonMarkdownFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-markdown-link-resolver-reject-\(UUID().uuidString)", isDirectory: true)
        let openedFile = root.appendingPathComponent("index.md")
        let textFile = root.appendingPathComponent("notes.txt")

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "index".write(to: openedFile, atomically: true, encoding: .utf8)
        try "text".write(to: textFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertNil(MarkdownPanelFileLinkResolver.resolve(rawPath: "missing.md", relativeToMarkdownFile: openedFile.path))
        XCTAssertNil(MarkdownPanelFileLinkResolver.resolve(rawPath: "notes.txt", relativeToMarkdownFile: openedFile.path))
        XCTAssertNil(MarkdownPanelFileLinkResolver.resolve(rawPath: "https://example.com/notes.md", relativeToMarkdownFile: openedFile.path))
    }
}
