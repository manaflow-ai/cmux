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
            case .cursor:
                resolvedEnvironment = [:]
            case .gemini:
                resolvedEnvironment = ["GEMINI_CLI_HOME": "/tmp/gemini"]
            case .opencode:
                resolvedEnvironment = ["OPENCODE_CONFIG_DIR": "/tmp/opencode"]
            case .rovodev:
                resolvedEnvironment = [:]
            case .copilot:
                resolvedEnvironment = ["COPILOT_HOME": "/tmp/copilot"]
            case .codebuddy:
                resolvedEnvironment = ["CODEBUDDY_CONFIG_DIR": "/tmp/codebuddy"]
            case .factory:
                resolvedEnvironment = [:]
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
            "'env' 'ANTHROPIC_MODEL=' 'CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV=1' 'CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS=ANTHROPIC_MODEL' 'claude' '--resume' 'claude-session-env'"
        )
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
