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
            case .pi:
                resolvedEnvironment = ["PI_CODING_AGENT_DIR": "/tmp/pi"]
            case .amp:
                resolvedEnvironment = ["AMP_SETTINGS_FILE": "/tmp/amp-settings.json"]
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

    func testSessionEntryClaudeResumeCommandChangesToSessionCwdBeforeResume() {
        let entry = SessionEntry(
            id: "claude:a22293b7-bcef-4707-8439-2f538c8517a4",
            agent: .claude,
            sessionId: "a22293b7-bcef-4707-8439-2f538c8517a4",
            title: "resume me",
            cwd: "/Users/tiffanysun/fun",
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 0),
            fileURL: URL(
                fileURLWithPath: "/Users/tiffanysun/.claude/projects/-Users-tiffanysun-fun/a22293b7-bcef-4707-8439-2f538c8517a4.jsonl"
            ),
            specifics: .claude(model: nil, permissionMode: nil)
        )

        XCTAssertEqual(
            entry.resumeCommand,
            "cd /Users/tiffanysun/fun && env CLAUDE_CONFIG_DIR=/Users/tiffanysun/.claude CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV=1 CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS=CLAUDE_CONFIG_DIR claude --resume a22293b7-bcef-4707-8439-2f538c8517a4"
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
            "cd '/Users/lawrence/fun' && 'env' 'CLAUDE_CONFIG_DIR=/Users/lawrence/.codex-accounts/claude/_p1775010019397' 'CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV=1' 'CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS=CLAUDE_CONFIG_DIR' '/Users/lawrence/.local/bin/claude' '--resume' '24ec0052-450c-4914-b1dd-2ee80d4bc84b' '--dangerously-load-development-channels' 'server:custom-dev-channel' '--dangerously-skip-permissions'"
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
            "cd '/Users/lawrence/fun' && 'env' 'CLAUDE_CONFIG_DIR=/Users/lawrence/.codex-accounts/claude/_p1775010019397' 'CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV=1' 'CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS=CLAUDE_CONFIG_DIR' '/Users/lawrence/.local/bin/claude' '--resume' '24ec0052-450c-4914-b1dd-2ee80d4bc84b' '--fork-session' '--dangerously-load-development-channels' 'server:custom-dev-channel' '--dangerously-skip-permissions'"
        )
        XCTAssertEqual(
            claudeFork.forkCommand,
            "cd '/Users/lawrence/fun' && 'env' 'CLAUDE_CONFIG_DIR=/Users/lawrence/.codex-accounts/claude/_p1775010019397' 'CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV=1' 'CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS=CLAUDE_CONFIG_DIR' '/Users/lawrence/.local/bin/claude' '--resume' 'claude-fork-child' '--fork-session' '--model' 'sonnet' '--dangerously-skip-permissions'"
        )
        XCTAssertEqual(
            codex.forkCommand,
            "cd '/Users/example/repo' && 'env' 'CODEX_HOME=/tmp/codex home' '/Users/example/.bun/bin/codex' 'fork' '019dad34-d218-7943-b81a-eddac5c87951' '--model' 'gpt-5.4' '--sandbox' 'danger-full-access' '--ask-for-approval' 'never' '--search' '--cd' '/Users/example/repo'"
        )
        XCTAssertEqual(
            codexWithImage.forkCommand,
            "cd '/Users/example/repo' && 'env' 'CODEX_HOME=/tmp/codex home' '/Users/example/.bun/bin/codex' 'fork' '019image-session' '--image' '/tmp/screenshot.png' '--model' 'gpt-5.4'"
        )
        XCTAssertEqual(
            codexFork.forkCommand,
            "cd '/Users/example/repo' && 'env' 'CODEX_HOME=/tmp/codex home' '/Users/example/.bun/bin/codex' 'fork' '019e1eca-ee32-7001-ab30-edcae57430bb' '--model' 'gpt-5.4' '--sandbox' 'danger-full-access' '--search'"
        )
        XCTAssertEqual(
            codexTeams.forkCommand,
            "cd '/Users/example/repo' && 'env' 'CODEX_HOME=/tmp/codex home' '/usr/local/bin/cmux' 'codex-teams' 'fork' 'codex-teams-session' '--model' 'gpt-5.4' '--image' '/tmp/team screenshot.png' '--sandbox' 'danger-full-access'"
        )
        XCTAssertEqual(
            directOpenCode.forkCommand,
            "cd '/tmp/direct opencode repo' && 'env' 'OPENCODE_CONFIG_DIR=/tmp/opencode config' '/opt/homebrew/bin/opencode' '--session' 'direct-opencode-session-456' '--fork' '--model' 'anthropic/claude-sonnet-4-6' '--port' '4096' '/tmp/direct opencode repo'"
        )
        XCTAssertEqual(
            directOpenCodeFork.forkCommand,
            "cd '/tmp/direct opencode repo' && 'env' 'OPENCODE_CONFIG_DIR=/tmp/opencode config' '/opt/homebrew/bin/opencode' '--session' 'direct-opencode-child-session' '--fork' '--model' 'anthropic/claude-sonnet-4-6' '--port' '4096' '/tmp/direct opencode repo'"
        )
        XCTAssertEqual(
            omoOpenCode.forkCommand,
            "cd '/tmp/opencode repo' && 'env' 'OPENCODE_CONFIG_DIR=/tmp/opencode config' '/usr/local/bin/cmux' 'omo' '--session' 'opencode-session-123' '--fork' '--model' 'anthropic/claude-sonnet-4-6' '/tmp/opencode repo'"
        )
        XCTAssertEqual(
            omoOpenCodeFork.forkCommand,
            "cd '/tmp/opencode repo' && 'env' 'OPENCODE_CONFIG_DIR=/tmp/opencode config' '/usr/local/bin/cmux' 'omo' '--session' 'opencode-child-session' '--fork' '--model' 'anthropic/claude-sonnet-4-6' '/tmp/opencode repo'"
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

    func testProcessDetectedCodexRecognizesWrapperAndSessionId() {
        XCTAssertTrue(
            RestorableAgentSessionIndex.processLooksLikeCodex(
                processName: "codex",
                processPath: "/Users/lawrence/.bun/bin/codex",
                arguments: [
                    "/Users/lawrence/.bun/bin/codex",
                    "--model",
                    "gpt-5.4",
                    "initial prompt"
                ]
            )
        )
        XCTAssertTrue(
            RestorableAgentSessionIndex.processLooksLikeCodex(
                processName: "node",
                processPath: "/opt/homebrew/bin/node",
                arguments: [
                    "node",
                    "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js",
                    "--model",
                    "gpt-5.4"
                ]
            )
        )
        XCTAssertFalse(
            RestorableAgentSessionIndex.processLooksLikeCodex(
                processName: "node",
                processPath: "/opt/homebrew/bin/node",
                arguments: [
                    "node",
                    "/Users/lawrence/.bun/bin/opencode"
                ]
            )
        )
        XCTAssertEqual(
            RestorableAgentSessionIndex.codexSessionIdForProcess(
                arguments: [
                    "/Users/lawrence/.bun/bin/codex",
                    "--disable",
                    "hooks",
                    "--dangerously-bypass-approvals-and-sandbox",
                    "2+2"
                ],
                environment: ["CODEX_THREAD_ID": "019e26a3-2c4b-7e62-b8d3-825ec5f3c696"]
            ),
            "019e26a3-2c4b-7e62-b8d3-825ec5f3c696"
        )
        XCTAssertEqual(
            RestorableAgentSessionIndex.codexSessionIdForProcess(
                arguments: [
                    "/Users/lawrence/.bun/bin/codex",
                    "resume",
                    "019dad34-d218-7943-b81a-eddac5c87951"
                ],
                environment: [:]
            ),
            "019dad34-d218-7943-b81a-eddac5c87951"
        )
        XCTAssertEqual(
            RestorableAgentSessionIndex.codexSessionIdForProcess(
                arguments: [
                    "/Users/lawrence/.bun/bin/codex",
                    "fork",
                    "019dad34-d218-7943-b81a-eddac5c87951"
                ],
                environment: [:]
            ),
            "019dad34-d218-7943-b81a-eddac5c87951"
        )
        XCTAssertEqual(
            RestorableAgentSessionIndex.codexLaunchArgumentsForProcess(
                arguments: [
                    "/Users/lawrence/.bun/bin/codex",
                    "--disable",
                    "hooks",
                    "--dangerously-bypass-approvals-and-sandbox",
                    "2+2"
                ],
                environment: [:]
            ),
            [
                "/Users/lawrence/.bun/bin/codex",
                "--disable",
                "hooks",
                "--dangerously-bypass-approvals-and-sandbox"
            ]
        )
    }

    func testProcessDetectedClaudeRecognizesWrapperAndSessionId() {
        XCTAssertTrue(
            RestorableAgentSessionIndex.processLooksLikeClaude(
                processName: "claude",
                processPath: "/Users/lawrence/.local/bin/claude",
                arguments: [
                    "/Users/lawrence/.local/bin/claude",
                    "--session-id",
                    "claude-session",
                    "--settings",
                    #"{"hooks":{"SessionStart":[{"hooks":[{"command":"cmux hooks claude session-start"}]}]}}"#,
                    "--dangerously-skip-permissions"
                ],
                environment: ["CMUX_AGENT_LAUNCH_KIND": "claude"]
            )
        )
        XCTAssertTrue(
            RestorableAgentSessionIndex.processLooksLikeClaude(
                processName: "node",
                processPath: "/opt/homebrew/bin/node",
                arguments: [
                    "node",
                    "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js",
                    "--resume",
                    "resumed-session"
                ]
            )
        )
        XCTAssertTrue(
            RestorableAgentSessionIndex.processLooksLikeClaude(
                processName: "2.1.143",
                processPath: "/Users/lawrence/.local/share/claude/versions/2.1.143",
                arguments: [
                    "/Users/lawrence/.local/share/claude/versions/2.1.143",
                    "--resume",
                    "versioned-session"
                ]
            )
        )
        XCTAssertFalse(
            RestorableAgentSessionIndex.processLooksLikeClaude(
                processName: "helper",
                processPath: "/usr/bin/helper",
                arguments: ["/usr/bin/helper"],
                environment: ["CMUX_AGENT_LAUNCH_KIND": "claude"]
            )
        )
        XCTAssertFalse(
            RestorableAgentSessionIndex.processLooksLikeClaude(
                processName: "node",
                processPath: "/opt/homebrew/bin/node",
                arguments: [
                    "node",
                    "/Users/lawrence/projects/claude-code/server.js",
                    "--resume",
                    "not-claude"
                ]
            )
        )
        XCTAssertFalse(
            RestorableAgentSessionIndex.processLooksLikeClaude(
                processName: "node",
                processPath: "/opt/homebrew/bin/node",
                arguments: [
                    "node",
                    "/Users/lawrence/work/claude-code/dist/server.js",
                    "--resume",
                    "not-claude"
                ]
            )
        )
        XCTAssertEqual(
            RestorableAgentSessionIndex.claudeSessionIdForProcess(
                arguments: [
                    "/Users/lawrence/.local/bin/claude",
                    "--session-id",
                    "claude-session"
                ],
                environment: [:]
            ),
            "claude-session"
        )
        XCTAssertEqual(
            RestorableAgentSessionIndex.claudeSessionIdForProcess(
                arguments: [
                    "/Users/lawrence/.local/bin/claude",
                    "--resume",
                    "41b9a226-2504-4f6d-8e81-8dd28f91fadb"
                ],
                environment: [:]
            ),
            "41b9a226-2504-4f6d-8e81-8dd28f91fadb"
        )
        XCTAssertEqual(
            RestorableAgentSessionIndex.claudeSessionIdForProcess(
                arguments: [
                    "/Users/lawrence/.local/bin/claude",
                    "--resume",
                    "41b9a226-2504-4f6d-8e81-8dd28f91fadb"
                ],
                environment: ["CLAUDE_SESSION_ID": "d86c6b10-0ac8-4f71-a9d0-428d7855cded"]
            ),
            "41b9a226-2504-4f6d-8e81-8dd28f91fadb"
        )
        XCTAssertEqual(
            RestorableAgentSessionIndex.claudeSessionIdForProcess(
                arguments: [
                    "/Users/lawrence/.local/bin/claude",
                    "--resume",
                    "fix the tests"
                ],
                environment: ["CLAUDE_SESSION_ID": "d86c6b10-0ac8-4f71-a9d0-428d7855cded"]
            ),
            "d86c6b10-0ac8-4f71-a9d0-428d7855cded"
        )
        XCTAssertNil(
            RestorableAgentSessionIndex.claudeSessionIdForProcess(
                arguments: [
                    "/Users/lawrence/.local/bin/claude",
                    "--resume",
                    "fix the tests"
                ],
                environment: [:]
            )
        )
        XCTAssertEqual(
            RestorableAgentSessionIndex.claudeSessionIdForProcess(
                arguments: [
                    "node",
                    "-r",
                    "/tmp/preload-hook.js",
                    "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js",
                    "--session-id",
                    "node-wrapper-session"
                ],
                environment: [:]
            ),
            "node-wrapper-session"
        )
        XCTAssertNil(
            RestorableAgentSessionIndex.claudeSessionIdForProcess(
                arguments: [
                    "node",
                    "-r",
                    "/tmp/preload-hook.js",
                    "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"
                ],
                environment: [:]
            )
        )
        XCTAssertNil(
            RestorableAgentSessionIndex.claudeSessionIdForProcess(
                arguments: [
                    "/Users/lawrence/.local/bin/claude",
                    "--resume",
                    "--model",
                    "opus"
                ],
                environment: [:]
            )
        )
        XCTAssertNil(
            RestorableAgentSessionIndex.claudeSessionIdForProcess(
                arguments: [
                    "/Users/lawrence/.local/bin/claude",
                    "--resume",
                    "parent-session",
                    "--fork-session",
                    "--model",
                    "opus"
                ],
                environment: [:]
            )
        )
        XCTAssertEqual(
            RestorableAgentSessionIndex.claudeSessionIdForProcess(
                arguments: [
                    "/Users/lawrence/.local/bin/claude",
                    "--resume",
                    "parent-session",
                    "--fork-session"
                ],
                environment: ["CLAUDE_SESSION_ID": "child-session"]
            ),
            "child-session"
        )
        XCTAssertEqual(
            RestorableAgentSessionIndex.claudeSessionIdForProcess(
                arguments: [
                    "/Users/lawrence/.local/bin/claude"
                ],
                environment: ["CLAUDE_SESSION_ID": "env-session"]
            ),
            "env-session"
        )
    }

    func testProcessDetectedClaudeLaunchArgumentsDropHookSettingsAndSessionFlag() {
        let arguments = RestorableAgentSessionIndex.claudeLaunchArgumentsForProcess(
            arguments: [
                "/Users/lawrence/.local/bin/claude",
                "--session-id",
                "claude-session",
                "--settings",
                #"{"hooks":{"SessionStart":[{"hooks":[{"command":"cmux hooks claude session-start"}]}]}}"#,
                "--model",
                "opus",
                "--dangerously-skip-permissions",
                "prompt should not replay"
            ],
            environment: [:]
        )

        XCTAssertEqual(
            arguments,
            [
                "/Users/lawrence/.local/bin/claude",
                "--model",
                "opus",
                "--dangerously-skip-permissions"
            ]
        )
    }

    func testProcessDetectedClaudePreservesInheritedLauncherMetadata() {
        let launchCommand = RestorableAgentSessionIndex.claudeLaunchCommandForProcess(
            arguments: [
                "/Users/lawrence/.local/bin/claude",
                "--session-id",
                "claude-session",
                "--settings",
                #"{"hooks":{"SessionStart":[{"hooks":[{"command":"cmux hooks claude session-start"}]}]}}"#,
                "--dangerously-skip-permissions"
            ],
            environment: [
                "CMUX_AGENT_LAUNCH_KIND": "claude-teams",
                "CMUX_AGENT_LAUNCH_EXECUTABLE": "/Applications/cmux.app/Contents/Resources/bin/cmux",
                "CMUX_AGENT_LAUNCH_ARGV_B64": base64NULSeparated([
                    "/Applications/cmux.app/Contents/Resources/bin/cmux",
                    "claude-teams",
                    "--model",
                    "opus"
                ]),
                "CMUX_AGENT_LAUNCH_CWD": "/Users/lawrence/project",
                "PATH": "/tmp/bin:/usr/bin",
                "ANTHROPIC_API_KEY": "secret"
            ]
        )

        XCTAssertEqual(launchCommand?.launcher, "claudeTeams")
        XCTAssertEqual(launchCommand?.executablePath, "/Applications/cmux.app/Contents/Resources/bin/cmux")
        XCTAssertEqual(
            launchCommand?.arguments,
            [
                "/Applications/cmux.app/Contents/Resources/bin/cmux",
                "claude-teams",
                "--model",
                "opus"
            ]
        )
        XCTAssertEqual(launchCommand?.workingDirectory, "/Users/lawrence/project")
        XCTAssertNil(launchCommand?.environment?["ANTHROPIC_API_KEY"])
        XCTAssertNil(launchCommand?.capturedAt)
        XCTAssertEqual(launchCommand?.source, "environment")
    }

    func testProcessDetectedClaudeRejectsUnsupportedInheritedLauncher() {
        let launchCommand = RestorableAgentSessionIndex.claudeLaunchCommandForProcess(
            arguments: [
                "/Users/lawrence/.local/bin/claude",
                "--session-id",
                "claude-session"
            ],
            environment: [
                "CMUX_AGENT_LAUNCH_KIND": "omc",
                "CMUX_AGENT_LAUNCH_EXECUTABLE": "/Applications/cmux.app/Contents/Resources/bin/cmux",
                "CMUX_AGENT_LAUNCH_ARGV_B64": base64NULSeparated([
                    "/Applications/cmux.app/Contents/Resources/bin/cmux",
                    "omc"
                ])
            ]
        )

        XCTAssertNil(launchCommand)

        XCTAssertNil(
            RestorableAgentSessionIndex.claudeLaunchCommandForProcess(
                arguments: [
                    "/Users/lawrence/.local/bin/claude",
                    "--session-id",
                    "claude-session"
                ],
                environment: [
                    "CMUX_AGENT_LAUNCH_KIND": "codexTeams",
                    "CMUX_AGENT_LAUNCH_EXECUTABLE": "/Applications/cmux.app/Contents/Resources/bin/cmux",
                    "CMUX_AGENT_LAUNCH_ARGV_B64": base64NULSeparated([
                        "/Applications/cmux.app/Contents/Resources/bin/cmux",
                        "codex-teams",
                        "--model",
                        "gpt-5.4"
                    ])
                ]
            )
        )
        XCTAssertNil(
            RestorableAgentSessionIndex.claudeLaunchCommandForProcess(
                arguments: [
                    "/Users/lawrence/.local/bin/claude",
                    "--session-id",
                    "claude-session"
                ],
                environment: [
                    "CMUX_AGENT_LAUNCH_KIND": "omo",
                    "CMUX_AGENT_LAUNCH_EXECUTABLE": "/Applications/cmux.app/Contents/Resources/bin/cmux",
                    "CMUX_AGENT_LAUNCH_ARGV_B64": base64NULSeparated([
                        "/Applications/cmux.app/Contents/Resources/bin/cmux",
                        "omo"
                    ])
                ]
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
            "cd '/tmp/opencode repo' && '\(executable.path)' '--session' 'opencode-session-123' '--fork' '--model' 'anthropic/claude-sonnet-4-6' '--agent' 'build' '--port' '4096' '/tmp/opencode repo'"
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

    func testProcessDetectionOpenCodeForkFallbackCountsPanelsNotHelperPIDs() throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let ttyDevice: Int64 = 44_034
        let nativeOpenCode = makeTopProcess(
            pid: 10_034,
            name: "opencode",
            path: "/opt/homebrew/bin/opencode",
            ttyDevice: ttyDevice,
            workspaceId: workspaceId,
            panelId: panelId
        )
        let nodeWrapperOpenCode = makeTopProcess(
            pid: 10_035,
            name: "node",
            path: "/opt/homebrew/bin/node",
            ttyDevice: ttyDevice,
            workspaceId: workspaceId,
            panelId: panelId
        )
        var latestLookups: [(workingDirectory: String?, parentSessionId: String?)] = []
        let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: []),
            fileManager: .default,
            processSnapshot: CmuxTopProcessSnapshot(
                processes: [nativeOpenCode, nodeWrapperOpenCode],
                sampledAt: Date(timeIntervalSince1970: 123),
                includesProcessDetails: false
            ),
            processArguments: { pid in
                switch pid {
                case nativeOpenCode.pid:
                    return CmuxTopProcessArguments(
                        arguments: [
                            "/opt/homebrew/bin/opencode",
                            "--session",
                            "opencode-parent-session",
                            "--fork"
                        ],
                        environment: ["PWD": "/tmp/single opencode panel"]
                    )
                case nodeWrapperOpenCode.pid:
                    return CmuxTopProcessArguments(
                        arguments: [
                            "node",
                            "/opt/homebrew/bin/opencode",
                            "--session",
                            "opencode-parent-session",
                            "--fork"
                        ],
                        environment: ["PWD": "/tmp/single opencode panel"]
                    )
                default:
                    return nil
                }
            },
            latestOpenCodeSessionId: { workingDirectory, parentSessionId, _ in
                latestLookups.append((workingDirectory, parentSessionId))
                return "opencode-child-session"
            }
        )

        let snapshot = try XCTUnwrap(
            detected[RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)]?.snapshot
        )
        XCTAssertFalse(latestLookups.isEmpty)
        XCTAssertEqual(snapshot.kind, .opencode)
        XCTAssertEqual(snapshot.sessionId, "opencode-child-session")
        XCTAssertEqual(snapshot.workingDirectory, "/tmp/single opencode panel")
    }

    func testProcessDetectionUsesFocusedTTYFallbackForClaudeWithoutCMUXEnvironment() throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let ttyDevice: Int64 = 44_001
        let process = makeTopProcess(
            pid: 10_001,
            name: "claude",
            path: "/Users/lawrence/.local/bin/claude",
            ttyDevice: ttyDevice
        )
        let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: []),
            fileManager: .default,
            fallbackScope: RestorableAgentProcessDetectionScope(
                workspaceId: workspaceId,
                panelId: panelId,
                ttyDevice: ttyDevice
            ),
            processSnapshot: CmuxTopProcessSnapshot(
                processes: [process],
                sampledAt: Date(timeIntervalSince1970: 123),
                includesProcessDetails: false
            ),
            processArguments: { pid in
                guard pid == process.pid else { return nil }
                return CmuxTopProcessArguments(
                    arguments: [
                        "/Users/lawrence/.local/bin/claude",
                        "--resume",
                        "eb9abe5d-1ac0-4db1-a7f1-9ea585764529"
                    ],
                    environment: ["PWD": "/tmp/claude repo"]
                )
            }
        )

        let snapshot = try XCTUnwrap(
            detected[RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)]?.snapshot
        )
        XCTAssertEqual(snapshot.kind, .claude)
        XCTAssertEqual(snapshot.sessionId, "eb9abe5d-1ac0-4db1-a7f1-9ea585764529")
        XCTAssertEqual(snapshot.workingDirectory, "/tmp/claude repo")
        XCTAssertEqual(snapshot.launchCommand?.source, "process")
    }

    func testProcessDetectionUsesFocusedTTYFallbackForOpenCodeWithoutCMUXEnvironment() throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let ttyDevice: Int64 = 44_002
        let process = makeTopProcess(
            pid: 10_002,
            name: "opencode",
            path: "/opt/homebrew/bin/opencode",
            ttyDevice: ttyDevice
        )
        let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: []),
            fileManager: .default,
            fallbackScope: RestorableAgentProcessDetectionScope(
                workspaceId: workspaceId,
                panelId: panelId,
                ttyDevice: ttyDevice
            ),
            processSnapshot: CmuxTopProcessSnapshot(
                processes: [process],
                sampledAt: Date(timeIntervalSince1970: 123),
                includesProcessDetails: false
            ),
            processArguments: { pid in
                guard pid == process.pid else { return nil }
                return CmuxTopProcessArguments(
                    arguments: [
                        "/opt/homebrew/bin/opencode",
                        "--session",
                        "opencode-tty-session"
                    ],
                    environment: ["PWD": "/tmp/opencode repo"]
                )
            }
        )

        let snapshot = try XCTUnwrap(
            detected[RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)]?.snapshot
        )
        XCTAssertEqual(snapshot.kind, .opencode)
        XCTAssertEqual(snapshot.sessionId, "opencode-tty-session")
        XCTAssertEqual(snapshot.workingDirectory, "/tmp/opencode repo")
        XCTAssertEqual(snapshot.launchCommand?.source, "process")
    }

    func testProcessDetectionUsesFocusedTTYFallbackForCodexWithoutCMUXEnvironment() throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let ttyDevice: Int64 = 44_030
        let process = makeTopProcess(
            pid: 10_030,
            name: "codex",
            path: "/Users/lawrence/.bun/bin/codex",
            ttyDevice: ttyDevice
        )
        let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: []),
            fileManager: .default,
            fallbackScope: RestorableAgentProcessDetectionScope(
                workspaceId: workspaceId,
                panelId: panelId,
                ttyDevice: ttyDevice
            ),
            processSnapshot: CmuxTopProcessSnapshot(
                processes: [process],
                sampledAt: Date(timeIntervalSince1970: 123),
                includesProcessDetails: false
            ),
            processArguments: { pid in
                guard pid == process.pid else { return nil }
                return CmuxTopProcessArguments(
                    arguments: [
                        "/Users/lawrence/.bun/bin/codex",
                        "--disable",
                        "hooks",
                        "--dangerously-bypass-approvals-and-sandbox",
                        "2+2"
                    ],
                    environment: [
                        "CODEX_HOME": "/tmp/codex home",
                        "CODEX_THREAD_ID": "019e26a3-2c4b-7e62-b8d3-825ec5f3c696",
                        "PWD": "/tmp/codex repo"
                    ]
                )
            }
        )

        let snapshot = try XCTUnwrap(
            detected[RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)]?.snapshot
        )
        XCTAssertEqual(snapshot.kind, .codex)
        XCTAssertEqual(snapshot.sessionId, "019e26a3-2c4b-7e62-b8d3-825ec5f3c696")
        XCTAssertEqual(snapshot.workingDirectory, "/tmp/codex repo")
        XCTAssertEqual(snapshot.launchCommand?.source, "process")
        XCTAssertEqual(
            snapshot.forkCommand,
            "cd '/tmp/codex repo' && 'env' 'CODEX_HOME=/tmp/codex home' '/Users/lawrence/.bun/bin/codex' 'fork' '019e26a3-2c4b-7e62-b8d3-825ec5f3c696' '--disable' 'hooks' '--dangerously-bypass-approvals-and-sandbox'"
        )
    }

    func testProcessDetectionUsesCodexForkChildThreadEnvironment() throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let ttyDevice: Int64 = 44_031
        let process = makeTopProcess(
            pid: 10_031,
            name: "codex",
            path: "/Users/lawrence/.bun/bin/codex",
            ttyDevice: ttyDevice,
            workspaceId: workspaceId,
            panelId: panelId
        )
        let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: []),
            fileManager: .default,
            processSnapshot: CmuxTopProcessSnapshot(
                processes: [process],
                sampledAt: Date(timeIntervalSince1970: 123),
                includesProcessDetails: false
            ),
            processArguments: { pid in
                guard pid == process.pid else { return nil }
                return CmuxTopProcessArguments(
                    arguments: [
                        "/Users/lawrence/.bun/bin/codex",
                        "fork",
                        "019dad34-d218-7943-b81a-eddac5c87951",
                        "--model",
                        "gpt-5.4",
                        "stale fork prompt"
                    ],
                    environment: [
                        "CODEX_HOME": "/tmp/codex home",
                        "CODEX_THREAD_ID": "019e1eca-ee32-7001-ab30-edcae57430bb",
                        "PWD": "/tmp/codex fork repo"
                    ]
                )
            }
        )

        let snapshot = try XCTUnwrap(
            detected[RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)]?.snapshot
        )
        XCTAssertEqual(snapshot.kind, .codex)
        XCTAssertEqual(snapshot.sessionId, "019e1eca-ee32-7001-ab30-edcae57430bb")
        XCTAssertEqual(
            snapshot.forkCommand,
            "cd '/tmp/codex fork repo' && 'env' 'CODEX_HOME=/tmp/codex home' '/Users/lawrence/.bun/bin/codex' 'fork' '019e1eca-ee32-7001-ab30-edcae57430bb' '--model' 'gpt-5.4'"
        )
    }

    func testProcessDetectionResolvesCodexForkChildFromSessionMetadataWhenThreadEnvironmentMissing() throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let ttyDevice: Int64 = 44_033
        let fileManager = FileManager.default
        let codexHome = fileManager.temporaryDirectory
            .appendingPathComponent("codex-fork-child-\(UUID().uuidString)", isDirectory: true)
        let workingDirectory = "/tmp/codex fork repo"
        try writeCodexSessionMeta(
            codexHome: codexHome,
            sessionId: "019e1111-1111-7111-8111-111111111111",
            forkedFromId: "019dad34-d218-7943-b81a-eddac5c87951",
            cwd: "/tmp/other repo",
            modifiedAt: Date(timeIntervalSince1970: 300)
        )
        try writeCodexSessionMeta(
            codexHome: codexHome,
            sessionId: "019e2222-2222-7222-8222-222222222222",
            forkedFromId: "019dad34-d218-7943-b81a-eddac5c87951",
            cwd: workingDirectory,
            createdAt: Date(timeIntervalSince1970: 100),
            modifiedAt: Date(timeIntervalSince1970: 100)
        )
        try writeCodexSessionMeta(
            codexHome: codexHome,
            sessionId: "019e2222-2222-7222-8222-222222222223",
            forkedFromId: "019dad34-d218-7943-b81a-eddac5c87951",
            cwd: workingDirectory,
            createdAt: Date(timeIntervalSince1970: 150),
            modifiedAt: Date(timeIntervalSince1970: 400)
        )
        try writeCodexSessionMeta(
            codexHome: codexHome,
            sessionId: "019e3333-3333-7333-8333-333333333333",
            forkedFromId: "019dad34-d218-7943-b81a-eddac5c87951",
            cwd: workingDirectory,
            createdAt: Date(timeIntervalSince1970: 200),
            modifiedAt: Date(timeIntervalSince1970: 200)
        )
        defer {
            try? fileManager.removeItem(at: codexHome)
        }

        let process = makeTopProcess(
            pid: 10_033,
            name: "codex",
            path: "/Users/lawrence/.bun/bin/codex",
            ttyDevice: ttyDevice,
            workspaceId: workspaceId,
            panelId: panelId
        )
        let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: []),
            fileManager: fileManager,
            processSnapshot: CmuxTopProcessSnapshot(
                processes: [process],
                sampledAt: Date(timeIntervalSince1970: 123),
                includesProcessDetails: false
            ),
            processArguments: { pid in
                guard pid == process.pid else { return nil }
                return CmuxTopProcessArguments(
                    arguments: [
                        "/Users/lawrence/.bun/bin/codex",
                        "fork",
                        "019dad34-d218-7943-b81a-eddac5c87951",
                        "--model",
                        "gpt-5.4",
                        "stale fork prompt"
                    ],
                    environment: [
                        "CODEX_HOME": codexHome.path,
                        "PWD": workingDirectory
                    ]
                )
            }
        )

        let snapshot = try XCTUnwrap(
            detected[RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)]?.snapshot
        )
        XCTAssertEqual(snapshot.kind, .codex)
        XCTAssertEqual(snapshot.sessionId, "019e3333-3333-7333-8333-333333333333")
        XCTAssertEqual(
            snapshot.forkCommand,
            "cd '/tmp/codex fork repo' && 'env' 'CODEX_HOME=\(codexHome.path)' '/Users/lawrence/.bun/bin/codex' 'fork' '019e3333-3333-7333-8333-333333333333' '--model' 'gpt-5.4'"
        )
    }

    func testProcessDetectionDoesNotShareCodexForkMetadataAcrossAmbiguousPanes() throws {
        let firstWorkspaceId = UUID()
        let firstPanelId = UUID()
        let secondWorkspaceId = UUID()
        let secondPanelId = UUID()
        let fileManager = FileManager.default
        let codexHome = fileManager.temporaryDirectory
            .appendingPathComponent("codex-ambiguous-fork-child-\(UUID().uuidString)", isDirectory: true)
        let parentSessionId = "019dad34-d218-7943-b81a-eddac5c87951"
        let workingDirectory = "/tmp/codex fork repo"
        try writeCodexSessionMeta(
            codexHome: codexHome,
            sessionId: "019e3333-3333-7333-8333-333333333333",
            forkedFromId: parentSessionId,
            cwd: workingDirectory,
            createdAt: Date(timeIntervalSince1970: 200),
            modifiedAt: Date(timeIntervalSince1970: 200)
        )
        defer {
            try? fileManager.removeItem(at: codexHome)
        }

        let firstProcess = makeTopProcess(
            pid: 10_034,
            name: "codex",
            path: "/Users/lawrence/.bun/bin/codex",
            ttyDevice: 44_034,
            workspaceId: firstWorkspaceId,
            panelId: firstPanelId
        )
        let secondProcess = makeTopProcess(
            pid: 10_035,
            name: "codex",
            path: "/Users/lawrence/.bun/bin/codex",
            ttyDevice: 44_035,
            workspaceId: secondWorkspaceId,
            panelId: secondPanelId
        )
        let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: []),
            fileManager: fileManager,
            processSnapshot: CmuxTopProcessSnapshot(
                processes: [firstProcess, secondProcess],
                sampledAt: Date(timeIntervalSince1970: 123),
                includesProcessDetails: false
            ),
            processArguments: { pid in
                guard pid == firstProcess.pid || pid == secondProcess.pid else { return nil }
                return CmuxTopProcessArguments(
                    arguments: [
                        "/Users/lawrence/.bun/bin/codex",
                        "fork",
                        parentSessionId,
                        "--model",
                        "gpt-5.4",
                        "stale fork prompt"
                    ],
                    environment: [
                        "CODEX_HOME": codexHome.path,
                        "PWD": workingDirectory
                    ]
                )
            }
        )

        let firstSnapshot = try XCTUnwrap(
            detected[RestorableAgentSessionIndex.PanelKey(workspaceId: firstWorkspaceId, panelId: firstPanelId)]?.snapshot
        )
        let secondSnapshot = try XCTUnwrap(
            detected[RestorableAgentSessionIndex.PanelKey(workspaceId: secondWorkspaceId, panelId: secondPanelId)]?.snapshot
        )
        XCTAssertEqual(firstSnapshot.kind, .codex)
        XCTAssertEqual(secondSnapshot.kind, .codex)
        XCTAssertEqual(firstSnapshot.sessionId, parentSessionId)
        XCTAssertEqual(secondSnapshot.sessionId, parentSessionId)
    }

    func testProcessDetectionCountsEnvBackedCodexForksAsMetadataAmbiguous() throws {
        let envBackedWorkspaceId = UUID()
        let envBackedPanelId = UUID()
        let missingEnvWorkspaceId = UUID()
        let missingEnvPanelId = UUID()
        let fileManager = FileManager.default
        let codexHome = fileManager.temporaryDirectory
            .appendingPathComponent("codex-mixed-fork-child-\(UUID().uuidString)", isDirectory: true)
        let parentSessionId = "019dad34-d218-7943-b81a-eddac5c87951"
        let childSessionId = "019e3333-3333-7333-8333-333333333333"
        let workingDirectory = "/tmp/codex fork repo"
        try writeCodexSessionMeta(
            codexHome: codexHome,
            sessionId: childSessionId,
            forkedFromId: parentSessionId,
            cwd: workingDirectory,
            createdAt: Date(timeIntervalSince1970: 200),
            modifiedAt: Date(timeIntervalSince1970: 200)
        )
        defer {
            try? fileManager.removeItem(at: codexHome)
        }

        let envBackedProcess = makeTopProcess(
            pid: 10_036,
            name: "codex",
            path: "/Users/lawrence/.bun/bin/codex",
            ttyDevice: 44_036,
            workspaceId: envBackedWorkspaceId,
            panelId: envBackedPanelId
        )
        let missingEnvProcess = makeTopProcess(
            pid: 10_037,
            name: "codex",
            path: "/Users/lawrence/.bun/bin/codex",
            ttyDevice: 44_037,
            workspaceId: missingEnvWorkspaceId,
            panelId: missingEnvPanelId
        )
        let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: []),
            fileManager: fileManager,
            processSnapshot: CmuxTopProcessSnapshot(
                processes: [envBackedProcess, missingEnvProcess],
                sampledAt: Date(timeIntervalSince1970: 123),
                includesProcessDetails: false
            ),
            processArguments: { pid in
                guard pid == envBackedProcess.pid || pid == missingEnvProcess.pid else { return nil }
                var environment = [
                    "CODEX_HOME": codexHome.path,
                    "PWD": workingDirectory
                ]
                if pid == envBackedProcess.pid {
                    environment["CODEX_THREAD_ID"] = childSessionId
                }
                return CmuxTopProcessArguments(
                    arguments: [
                        "/Users/lawrence/.bun/bin/codex",
                        "fork",
                        parentSessionId,
                        "--model",
                        "gpt-5.4",
                        "stale fork prompt"
                    ],
                    environment: environment
                )
            }
        )

        let envBackedSnapshot = try XCTUnwrap(
            detected[RestorableAgentSessionIndex.PanelKey(workspaceId: envBackedWorkspaceId, panelId: envBackedPanelId)]?.snapshot
        )
        let missingEnvSnapshot = try XCTUnwrap(
            detected[RestorableAgentSessionIndex.PanelKey(workspaceId: missingEnvWorkspaceId, panelId: missingEnvPanelId)]?.snapshot
        )
        XCTAssertEqual(envBackedSnapshot.kind, .codex)
        XCTAssertEqual(missingEnvSnapshot.kind, .codex)
        XCTAssertEqual(envBackedSnapshot.sessionId, childSessionId)
        XCTAssertEqual(missingEnvSnapshot.sessionId, parentSessionId)
    }

    func testProcessDetectionKeepsCodexForkCommandWhenThreadEnvironmentMissing() throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let ttyDevice: Int64 = 44_032
        let process = makeTopProcess(
            pid: 10_032,
            name: "codex",
            path: "/Users/lawrence/.bun/bin/codex",
            ttyDevice: ttyDevice,
            workspaceId: workspaceId,
            panelId: panelId
        )
        let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: []),
            fileManager: .default,
            processSnapshot: CmuxTopProcessSnapshot(
                processes: [process],
                sampledAt: Date(timeIntervalSince1970: 123),
                includesProcessDetails: false
            ),
            processArguments: { pid in
                guard pid == process.pid else { return nil }
                return CmuxTopProcessArguments(
                    arguments: [
                        "/Users/lawrence/.bun/bin/codex",
                        "fork",
                        "019dad34-d218-7943-b81a-eddac5c87951",
                        "--model",
                        "gpt-5.4",
                        "stale fork prompt"
                    ],
                    environment: [
                        "CODEX_HOME": "/tmp/codex home",
                        "PWD": "/tmp/codex fork repo"
                    ]
                )
            }
        )

        let snapshot = try XCTUnwrap(
            detected[RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)]?.snapshot
        )
        XCTAssertEqual(snapshot.kind, .codex)
        XCTAssertEqual(snapshot.sessionId, "019dad34-d218-7943-b81a-eddac5c87951")
        XCTAssertEqual(
            snapshot.forkCommand,
            "cd '/tmp/codex fork repo' && 'env' 'CODEX_HOME=/tmp/codex home' '/Users/lawrence/.bun/bin/codex' 'fork' '019dad34-d218-7943-b81a-eddac5c87951' '--model' 'gpt-5.4'"
        )
    }

    func testProcessDetectionKeepsCMUXScopedClaudeOverFocusedTTYFallback() throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let ttyDevice: Int64 = 44_003
        let scopedClaude = makeTopProcess(
            pid: 10_003,
            name: "claude",
            path: "/Users/lawrence/.local/bin/claude",
            ttyDevice: ttyDevice,
            workspaceId: workspaceId,
            panelId: panelId
        )
        let fallbackClaude = makeTopProcess(
            pid: 10_004,
            name: "claude",
            path: "/Users/lawrence/.local/bin/claude",
            ttyDevice: ttyDevice
        )
        let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: []),
            fileManager: .default,
            fallbackScope: RestorableAgentProcessDetectionScope(
                workspaceId: workspaceId,
                panelId: panelId,
                ttyDevice: ttyDevice
            ),
            processSnapshot: CmuxTopProcessSnapshot(
                processes: [scopedClaude, fallbackClaude],
                sampledAt: Date(timeIntervalSince1970: 123),
                includesProcessDetails: false
            ),
            processArguments: { pid in
                switch pid {
                case scopedClaude.pid:
                    return CmuxTopProcessArguments(
                        arguments: [
                            "/Users/lawrence/.local/bin/claude",
                            "--resume",
                            "5531b99b-317e-4571-9c33-c2ca69ab3cb0"
                        ],
                        environment: ["PWD": "/tmp/scoped claude repo"]
                    )
                case fallbackClaude.pid:
                    return CmuxTopProcessArguments(
                        arguments: [
                            "/Users/lawrence/.local/bin/claude",
                            "--resume",
                            "5449ecd8-b511-41da-8a74-195497f79a64"
                        ],
                        environment: ["PWD": "/tmp/fallback claude repo"]
                    )
                default:
                    return nil
                }
            }
        )

        let snapshot = try XCTUnwrap(
            detected[RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)]?.snapshot
        )
        XCTAssertEqual(snapshot.kind, .claude)
        XCTAssertEqual(snapshot.sessionId, "5531b99b-317e-4571-9c33-c2ca69ab3cb0")
        XCTAssertEqual(snapshot.workingDirectory, "/tmp/scoped claude repo")
    }

    func testProcessDetectionKeepsFocusedTTYScopedClaudeOverOtherSamePanelScopedClaude() throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let focusedTTYDevice: Int64 = 44_008
        let otherTTYDevice: Int64 = 44_009
        let focusedClaude = makeTopProcess(
            pid: 10_012,
            name: "claude",
            path: "/Users/lawrence/.local/bin/claude",
            ttyDevice: focusedTTYDevice,
            workspaceId: workspaceId,
            panelId: panelId
        )
        let otherClaude = makeTopProcess(
            pid: 10_013,
            name: "claude",
            path: "/Users/lawrence/.local/bin/claude",
            ttyDevice: otherTTYDevice,
            workspaceId: workspaceId,
            panelId: panelId
        )
        let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: []),
            fileManager: .default,
            fallbackScope: RestorableAgentProcessDetectionScope(
                workspaceId: workspaceId,
                panelId: panelId,
                ttyDevice: focusedTTYDevice
            ),
            processSnapshot: CmuxTopProcessSnapshot(
                processes: [focusedClaude, otherClaude],
                sampledAt: Date(timeIntervalSince1970: 123),
                includesProcessDetails: false
            ),
            processArguments: { pid in
                switch pid {
                case focusedClaude.pid:
                    return CmuxTopProcessArguments(
                        arguments: [
                            "/Users/lawrence/.local/bin/claude",
                            "--resume",
                            "3a3537ea-70de-4baf-b483-a1ae60b2bb38"
                        ],
                        environment: ["PWD": "/tmp/focused tty claude repo"]
                    )
                case otherClaude.pid:
                    return CmuxTopProcessArguments(
                        arguments: [
                            "/Users/lawrence/.local/bin/claude",
                            "--resume",
                            "b0a9b600-d7f6-429d-b350-a9c58da53505"
                        ],
                        environment: ["PWD": "/tmp/other tty claude repo"]
                    )
                default:
                    return nil
                }
            }
        )

        let snapshot = try XCTUnwrap(
            detected[RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)]?.snapshot
        )
        XCTAssertEqual(snapshot.kind, .claude)
        XCTAssertEqual(snapshot.sessionId, "3a3537ea-70de-4baf-b483-a1ae60b2bb38")
        XCTAssertEqual(snapshot.workingDirectory, "/tmp/focused tty claude repo")
    }

    func testProcessDetectionKeepsNestedTTYCMUXScopedClaudeOverFocusedTTYFallback() throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let scopedSessionId = "4a7594e8-067f-47d6-9d5e-bf78c22f7a20"
        let fallbackSessionId = "9b493c70-aae8-48cb-bbb4-4669e4474969"
        let focusedTTYDevice: Int64 = 44_020
        let nestedTTYDevice: Int64 = 44_021
        let scopedNestedClaude = makeTopProcess(
            pid: 10_020,
            name: "claude",
            path: "/Users/lawrence/.local/bin/claude",
            ttyDevice: nestedTTYDevice,
            workspaceId: workspaceId,
            panelId: panelId
        )
        let fallbackClaude = makeTopProcess(
            pid: 10_021,
            name: "claude",
            path: "/Users/lawrence/.local/bin/claude",
            ttyDevice: focusedTTYDevice
        )
        let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: []),
            fileManager: .default,
            fallbackScope: RestorableAgentProcessDetectionScope(
                workspaceId: workspaceId,
                panelId: panelId,
                ttyDevice: focusedTTYDevice
            ),
            processSnapshot: CmuxTopProcessSnapshot(
                processes: [scopedNestedClaude, fallbackClaude],
                sampledAt: Date(timeIntervalSince1970: 123),
                includesProcessDetails: false
            ),
            processArguments: { pid in
                switch pid {
                case scopedNestedClaude.pid:
                    return CmuxTopProcessArguments(
                        arguments: [
                            "/Users/lawrence/.local/bin/claude",
                            "--resume",
                            scopedSessionId
                        ],
                        environment: ["PWD": "/tmp/scoped nested claude repo"]
                    )
                case fallbackClaude.pid:
                    return CmuxTopProcessArguments(
                        arguments: [
                            "/Users/lawrence/.local/bin/claude",
                            "--resume",
                            fallbackSessionId
                        ],
                        environment: ["PWD": "/tmp/focused fallback claude repo"]
                    )
                default:
                    return nil
                }
            }
        )

        let snapshot = try XCTUnwrap(
            detected[RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)]?.snapshot
        )
        XCTAssertEqual(snapshot.kind, .claude)
        XCTAssertEqual(snapshot.sessionId, scopedSessionId)
        XCTAssertEqual(snapshot.workingDirectory, "/tmp/scoped nested claude repo")
    }

    func testProcessDetectionKeepsCMUXScopedClaudeWhenFallbackTTYIsStale() throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let scopedClaude = makeTopProcess(
            pid: 10_014,
            name: "claude",
            path: "/Users/lawrence/.local/bin/claude",
            ttyDevice: 44_010,
            workspaceId: workspaceId,
            panelId: panelId
        )
        let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: []),
            fileManager: .default,
            fallbackScope: RestorableAgentProcessDetectionScope(
                workspaceId: workspaceId,
                panelId: panelId,
                ttyName: "cmux-stale-tty"
            ),
            processSnapshot: CmuxTopProcessSnapshot(
                processes: [scopedClaude],
                sampledAt: Date(timeIntervalSince1970: 123),
                includesProcessDetails: false
            ),
            processArguments: { pid in
                guard pid == scopedClaude.pid else { return nil }
                return CmuxTopProcessArguments(
                    arguments: [
                        "/Users/lawrence/.local/bin/claude",
                        "--resume",
                        "717c09f4-7a51-4d5f-96ad-7aef1877f83b"
                    ],
                    environment: ["PWD": "/tmp/stale tty scoped claude repo"]
                )
            }
        )

        let snapshot = try XCTUnwrap(
            detected[RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)]?.snapshot
        )
        XCTAssertEqual(snapshot.kind, .claude)
        XCTAssertEqual(snapshot.sessionId, "717c09f4-7a51-4d5f-96ad-7aef1877f83b")
        XCTAssertEqual(snapshot.workingDirectory, "/tmp/stale tty scoped claude repo")
    }

    func testProcessDetectionRemapsMovedCMUXScopedClaudeByFocusedTTYFallback() throws {
        let oldWorkspaceId = UUID()
        let oldPanelId = UUID()
        let newWorkspaceId = UUID()
        let newPanelId = UUID()
        let ttyDevice: Int64 = 44_024
        let scopedClaude = makeTopProcess(
            pid: 10_024,
            name: "claude",
            path: "/Users/lawrence/.local/bin/claude",
            ttyDevice: ttyDevice,
            workspaceId: oldWorkspaceId,
            panelId: oldPanelId
        )
        let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: []),
            fileManager: .default,
            fallbackScope: RestorableAgentProcessDetectionScope(
                workspaceId: newWorkspaceId,
                panelId: newPanelId,
                ttyDevice: ttyDevice
            ),
            processSnapshot: CmuxTopProcessSnapshot(
                processes: [scopedClaude],
                sampledAt: Date(timeIntervalSince1970: 123),
                includesProcessDetails: false
            ),
            processArguments: { pid in
                guard pid == scopedClaude.pid else { return nil }
                return CmuxTopProcessArguments(
                    arguments: [
                        "/Users/lawrence/.local/bin/claude",
                        "--resume",
                        "6a4f9b09-7144-48b5-b5b6-76a3d9c4b490"
                    ],
                    environment: ["PWD": "/tmp/moved claude repo"]
                )
            }
        )

        let snapshot = try XCTUnwrap(
            detected[RestorableAgentSessionIndex.PanelKey(workspaceId: newWorkspaceId, panelId: newPanelId)]?.snapshot
        )
        XCTAssertEqual(snapshot.kind, .claude)
        XCTAssertEqual(snapshot.sessionId, "6a4f9b09-7144-48b5-b5b6-76a3d9c4b490")
        XCTAssertEqual(snapshot.workingDirectory, "/tmp/moved claude repo")
    }

    func testProcessDetectionRemapsMovedCMUXScopedOpenCodeByFocusedTTYFallback() throws {
        let oldWorkspaceId = UUID()
        let oldPanelId = UUID()
        let newWorkspaceId = UUID()
        let newPanelId = UUID()
        let ttyDevice: Int64 = 44_025
        let scopedOpenCode = makeTopProcess(
            pid: 10_025,
            name: "opencode",
            path: "/opt/homebrew/bin/opencode",
            ttyDevice: ttyDevice,
            workspaceId: oldWorkspaceId,
            panelId: oldPanelId
        )
        let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: []),
            fileManager: .default,
            fallbackScope: RestorableAgentProcessDetectionScope(
                workspaceId: newWorkspaceId,
                panelId: newPanelId,
                ttyDevice: ttyDevice
            ),
            processSnapshot: CmuxTopProcessSnapshot(
                processes: [scopedOpenCode],
                sampledAt: Date(timeIntervalSince1970: 123),
                includesProcessDetails: false
            ),
            processArguments: { pid in
                guard pid == scopedOpenCode.pid else { return nil }
                return CmuxTopProcessArguments(
                    arguments: [
                        "/opt/homebrew/bin/opencode",
                        "--session",
                        "opencode-moved-session"
                    ],
                    environment: ["PWD": "/tmp/moved opencode repo"]
                )
            }
        )

        let snapshot = try XCTUnwrap(
            detected[RestorableAgentSessionIndex.PanelKey(workspaceId: newWorkspaceId, panelId: newPanelId)]?.snapshot
        )
        XCTAssertEqual(snapshot.kind, .opencode)
        XCTAssertEqual(snapshot.sessionId, "opencode-moved-session")
        XCTAssertEqual(snapshot.workingDirectory, "/tmp/moved opencode repo")
    }

    func testProcessDetectionRemapsMovedCMUXScopedOpenCodeForkByFocusedTTYFallback() throws {
        let oldWorkspaceId = UUID()
        let oldPanelId = UUID()
        let newWorkspaceId = UUID()
        let newPanelId = UUID()
        let ttyDevice: Int64 = 44_026
        let scopedOpenCode = makeTopProcess(
            pid: 10_026,
            name: "opencode",
            path: "/opt/homebrew/bin/opencode",
            ttyDevice: ttyDevice,
            workspaceId: oldWorkspaceId,
            panelId: oldPanelId
        )
        var latestLookups: [(workingDirectory: String?, parentSessionId: String?)] = []
        let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: []),
            fileManager: .default,
            fallbackScope: RestorableAgentProcessDetectionScope(
                workspaceId: newWorkspaceId,
                panelId: newPanelId,
                ttyDevice: ttyDevice
            ),
            processSnapshot: CmuxTopProcessSnapshot(
                processes: [scopedOpenCode],
                sampledAt: Date(timeIntervalSince1970: 123),
                includesProcessDetails: false
            ),
            processArguments: { pid in
                guard pid == scopedOpenCode.pid else { return nil }
                return CmuxTopProcessArguments(
                    arguments: [
                        "/opt/homebrew/bin/opencode",
                        "--session",
                        "opencode-parent-session",
                        "--fork"
                    ],
                    environment: ["PWD": "/tmp/moved opencode fork repo"]
                )
            },
            latestOpenCodeSessionId: { workingDirectory, parentSessionId, _ in
                latestLookups.append((workingDirectory, parentSessionId))
                return "opencode-child-session"
            }
        )

        let snapshot = try XCTUnwrap(
            detected[RestorableAgentSessionIndex.PanelKey(workspaceId: newWorkspaceId, panelId: newPanelId)]?.snapshot
        )
        XCTAssertEqual(latestLookups.count, 1)
        XCTAssertEqual(latestLookups.first?.workingDirectory, "/tmp/moved opencode fork repo")
        XCTAssertEqual(latestLookups.first?.parentSessionId, "opencode-parent-session")
        XCTAssertEqual(snapshot.kind, .opencode)
        XCTAssertEqual(snapshot.sessionId, "opencode-child-session")
        XCTAssertEqual(snapshot.workingDirectory, "/tmp/moved opencode fork repo")
    }

    func testProcessDetectionSkipsInheritedClaudeHelperWithMismatchedWrapperPID() throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let ttyDevice: Int64 = 44_005
        let realClaude = makeTopProcess(
            pid: 10_007,
            name: "claude",
            path: "/Users/lawrence/.local/bin/claude",
            ttyDevice: ttyDevice,
            workspaceId: workspaceId,
            panelId: panelId
        )
        let inheritedHelper = makeTopProcess(
            pid: 10_008,
            name: "node",
            path: "/opt/homebrew/bin/node",
            ttyDevice: ttyDevice,
            workspaceId: workspaceId,
            panelId: panelId
        )
        let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: []),
            fileManager: .default,
            processSnapshot: CmuxTopProcessSnapshot(
                processes: [realClaude, inheritedHelper],
                sampledAt: Date(timeIntervalSince1970: 123),
                includesProcessDetails: false
            ),
            processArguments: { pid in
                switch pid {
                case realClaude.pid:
                    return CmuxTopProcessArguments(
                        arguments: [
                            "/Users/lawrence/.local/bin/claude",
                            "--resume",
                            "37b81293-e6f0-4143-af3e-73242df890e4"
                        ],
                        environment: [
                            "CMUX_CLAUDE_PID": String(realClaude.pid),
                            "PWD": "/tmp/real claude repo"
                        ]
                    )
                case inheritedHelper.pid:
                    return CmuxTopProcessArguments(
                        arguments: [
                            "node",
                            "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js",
                            "--resume",
                            "1eb612b9-9d72-4c14-a069-77637661a273"
                        ],
                        environment: [
                            "CMUX_CLAUDE_PID": String(realClaude.pid),
                            "PWD": "/tmp/helper claude repo"
                        ]
                    )
                default:
                    return nil
                }
            }
        )

        let snapshot = try XCTUnwrap(
            detected[RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)]?.snapshot
        )
        XCTAssertEqual(snapshot.kind, .claude)
        XCTAssertEqual(snapshot.sessionId, "37b81293-e6f0-4143-af3e-73242df890e4")
        XCTAssertEqual(snapshot.workingDirectory, "/tmp/real claude repo")
    }

    func testProcessDetectionKeepsCMUXScopedOpenCodeOverFocusedTTYFallback() throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let ttyDevice: Int64 = 44_004
        let scopedOpenCode = makeTopProcess(
            pid: 10_005,
            name: "opencode",
            path: "/opt/homebrew/bin/opencode",
            ttyDevice: ttyDevice,
            workspaceId: workspaceId,
            panelId: panelId
        )
        let fallbackOpenCode = makeTopProcess(
            pid: 10_006,
            name: "opencode",
            path: "/opt/homebrew/bin/opencode",
            ttyDevice: ttyDevice
        )
        let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: []),
            fileManager: .default,
            fallbackScope: RestorableAgentProcessDetectionScope(
                workspaceId: workspaceId,
                panelId: panelId,
                ttyDevice: ttyDevice
            ),
            processSnapshot: CmuxTopProcessSnapshot(
                processes: [scopedOpenCode, fallbackOpenCode],
                sampledAt: Date(timeIntervalSince1970: 123),
                includesProcessDetails: false
            ),
            processArguments: { pid in
                switch pid {
                case scopedOpenCode.pid:
                    return CmuxTopProcessArguments(
                        arguments: [
                            "/opt/homebrew/bin/opencode",
                            "--session",
                            "opencode-scoped-session"
                        ],
                        environment: ["PWD": "/tmp/scoped opencode repo"]
                    )
                case fallbackOpenCode.pid:
                    return CmuxTopProcessArguments(
                        arguments: [
                            "/opt/homebrew/bin/opencode",
                            "--session",
                            "opencode-fallback-session"
                        ],
                        environment: ["PWD": "/tmp/fallback opencode repo"]
                    )
                default:
                    return nil
                }
            }
        )

        let snapshot = try XCTUnwrap(
            detected[RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)]?.snapshot
        )
        XCTAssertEqual(snapshot.kind, .opencode)
        XCTAssertEqual(snapshot.sessionId, "opencode-scoped-session")
        XCTAssertEqual(snapshot.workingDirectory, "/tmp/scoped opencode repo")
    }

    func testProcessDetectionKeepsNestedTTYCMUXScopedOpenCodeOverFocusedTTYFallback() throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let focusedTTYDevice: Int64 = 44_022
        let nestedTTYDevice: Int64 = 44_023
        let scopedNestedOpenCode = makeTopProcess(
            pid: 10_022,
            name: "opencode",
            path: "/opt/homebrew/bin/opencode",
            ttyDevice: nestedTTYDevice,
            workspaceId: workspaceId,
            panelId: panelId
        )
        let fallbackOpenCode = makeTopProcess(
            pid: 10_023,
            name: "opencode",
            path: "/opt/homebrew/bin/opencode",
            ttyDevice: focusedTTYDevice
        )
        let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: []),
            fileManager: .default,
            fallbackScope: RestorableAgentProcessDetectionScope(
                workspaceId: workspaceId,
                panelId: panelId,
                ttyDevice: focusedTTYDevice
            ),
            processSnapshot: CmuxTopProcessSnapshot(
                processes: [scopedNestedOpenCode, fallbackOpenCode],
                sampledAt: Date(timeIntervalSince1970: 123),
                includesProcessDetails: false
            ),
            processArguments: { pid in
                switch pid {
                case scopedNestedOpenCode.pid:
                    return CmuxTopProcessArguments(
                        arguments: [
                            "/opt/homebrew/bin/opencode",
                            "--session",
                            "opencode-scoped-nested-session"
                        ],
                        environment: ["PWD": "/tmp/scoped nested opencode repo"]
                    )
                case fallbackOpenCode.pid:
                    return CmuxTopProcessArguments(
                        arguments: [
                            "/opt/homebrew/bin/opencode",
                            "--session",
                            "opencode-focused-fallback-session"
                        ],
                        environment: ["PWD": "/tmp/focused fallback opencode repo"]
                    )
                default:
                    return nil
                }
            }
        )

        let snapshot = try XCTUnwrap(
            detected[RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)]?.snapshot
        )
        XCTAssertEqual(snapshot.kind, .opencode)
        XCTAssertEqual(snapshot.sessionId, "opencode-scoped-nested-session")
        XCTAssertEqual(snapshot.workingDirectory, "/tmp/scoped nested opencode repo")
    }

    func testProcessDetectionKeepsCMUXScopedRegisteredAgentOverFocusedTTYFallback() throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let ttyDevice: Int64 = 44_006
        let registration = CmuxVaultAgentRegistration(
            id: "acme-agent",
            name: "Acme Agent",
            detect: CmuxVaultAgentDetectRule(processName: "acme-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "acme-agent --session {{sessionId}}",
            cwd: .preserve
        )
        let scopedAgent = makeTopProcess(
            pid: 10_008,
            name: "acme-agent",
            path: "/usr/local/bin/acme-agent",
            ttyDevice: ttyDevice,
            workspaceId: workspaceId,
            panelId: panelId
        )
        let fallbackAgent = makeTopProcess(
            pid: 10_009,
            name: "acme-agent",
            path: "/usr/local/bin/acme-agent",
            ttyDevice: ttyDevice
        )
        let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: [registration]),
            fileManager: .default,
            fallbackScope: RestorableAgentProcessDetectionScope(
                workspaceId: workspaceId,
                panelId: panelId,
                ttyDevice: ttyDevice
            ),
            processSnapshot: CmuxTopProcessSnapshot(
                processes: [scopedAgent, fallbackAgent],
                sampledAt: Date(timeIntervalSince1970: 123),
                includesProcessDetails: false
            ),
            processArguments: { pid in
                switch pid {
                case scopedAgent.pid:
                    return CmuxTopProcessArguments(
                        arguments: [
                            "/usr/local/bin/acme-agent",
                            "--session",
                            "custom-scoped-session"
                        ],
                        environment: ["PWD": "/tmp/scoped custom repo"]
                    )
                case fallbackAgent.pid:
                    return CmuxTopProcessArguments(
                        arguments: [
                            "/usr/local/bin/acme-agent",
                            "--session",
                            "custom-fallback-session"
                        ],
                        environment: ["PWD": "/tmp/fallback custom repo"]
                    )
                default:
                    return nil
                }
            }
        )

        let snapshot = try XCTUnwrap(
            detected[RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)]?.snapshot
        )
        XCTAssertEqual(snapshot.kind, .custom("acme-agent"))
        XCTAssertEqual(snapshot.sessionId, "custom-scoped-session")
        XCTAssertEqual(snapshot.workingDirectory, "/tmp/scoped custom repo")
    }

    func testProcessDetectionKeepsForegroundRegisteredAgentOverUnknownStatusForSamePanel() throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let registration = CmuxVaultAgentRegistration(
            id: "acme-agent",
            name: "Acme Agent",
            detect: CmuxVaultAgentDetectRule(processName: "acme-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "acme-agent --session {{sessionId}}",
            cwd: .preserve
        )
        let foregroundAgent = makeTopProcess(
            pid: 10_010,
            name: "acme-agent",
            path: "/usr/local/bin/acme-agent",
            ttyDevice: 44_007,
            workspaceId: workspaceId,
            panelId: panelId,
            processGroupID: 101,
            terminalProcessGroupID: 101
        )
        let unknownStatusAgent = makeTopProcess(
            pid: 10_011,
            name: "acme-agent",
            path: "/usr/local/bin/acme-agent",
            ttyDevice: 44_007,
            workspaceId: workspaceId,
            panelId: panelId,
            processGroupID: nil,
            terminalProcessGroupID: nil
        )
        let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: [registration]),
            fileManager: .default,
            processSnapshot: CmuxTopProcessSnapshot(
                processes: [foregroundAgent, unknownStatusAgent],
                sampledAt: Date(timeIntervalSince1970: 123),
                includesProcessDetails: false
            ),
            processArguments: { pid in
                switch pid {
                case foregroundAgent.pid:
                    return CmuxTopProcessArguments(
                        arguments: [
                            "/usr/local/bin/acme-agent",
                            "--session",
                            "custom-foreground-session"
                        ],
                        environment: ["PWD": "/tmp/foreground custom repo"]
                    )
                case unknownStatusAgent.pid:
                    return CmuxTopProcessArguments(
                        arguments: [
                            "/usr/local/bin/acme-agent",
                            "--session",
                            "custom-unknown-status-session"
                        ],
                        environment: ["PWD": "/tmp/unknown custom repo"]
                    )
                default:
                    return nil
                }
            }
        )

        let snapshot = try XCTUnwrap(
            detected[RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)]?.snapshot
        )
        XCTAssertEqual(snapshot.kind, .custom("acme-agent"))
        XCTAssertEqual(snapshot.sessionId, "custom-foreground-session")
        XCTAssertEqual(snapshot.workingDirectory, "/tmp/foreground custom repo")
    }

    func testProcessDetectionSkipsClaudeForkParentResumeSessionId() {
        let workspaceId = UUID()
        let panelId = UUID()
        let process = makeTopProcess(
            pid: 10_007,
            name: "claude",
            path: "/Users/lawrence/.local/bin/claude",
            ttyDevice: 44_005,
            workspaceId: workspaceId,
            panelId: panelId
        )
        let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: []),
            fileManager: .default,
            processSnapshot: CmuxTopProcessSnapshot(
                processes: [process],
                sampledAt: Date(timeIntervalSince1970: 123),
                includesProcessDetails: false
            ),
            processArguments: { pid in
                guard pid == process.pid else { return nil }
                return CmuxTopProcessArguments(
                    arguments: [
                        "/Users/lawrence/.local/bin/claude",
                        "--resume",
                        "parent-session",
                        "--fork-session",
                        "--model",
                        "opus"
                    ],
                    environment: ["PWD": "/tmp/claude fork repo"]
                )
            }
        )

        XCTAssertNil(
            detected[RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)]?.snapshot
        )
    }

    func testProcessDetectionPrefersForegroundClaudeOverBackgroundClaudeForSamePanel() throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let ttyDevice: Int64 = 44_006
        let foregroundClaude = makeTopProcess(
            pid: 10_008,
            name: "claude",
            path: "/Users/lawrence/.local/bin/claude",
            ttyDevice: ttyDevice,
            workspaceId: workspaceId,
            panelId: panelId,
            processGroupID: 300,
            terminalProcessGroupID: 300
        )
        let backgroundClaude = makeTopProcess(
            pid: 10_009,
            name: "claude",
            path: "/Users/lawrence/.local/bin/claude",
            ttyDevice: ttyDevice,
            workspaceId: workspaceId,
            panelId: panelId,
            processGroupID: 100,
            terminalProcessGroupID: 300
        )
        let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: []),
            fileManager: .default,
            processSnapshot: CmuxTopProcessSnapshot(
                processes: [foregroundClaude, backgroundClaude],
                sampledAt: Date(timeIntervalSince1970: 123),
                includesProcessDetails: false
            ),
            processArguments: { pid in
                switch pid {
                case foregroundClaude.pid:
                    return CmuxTopProcessArguments(
                        arguments: [
                            "/Users/lawrence/.local/bin/claude",
                            "--resume",
                            "03991fdd-6581-4d4f-8d76-bf0371c2b014"
                        ],
                        environment: ["PWD": "/tmp/foreground claude repo"]
                    )
                case backgroundClaude.pid:
                    return CmuxTopProcessArguments(
                        arguments: [
                            "/Users/lawrence/.local/bin/claude",
                            "--resume",
                            "a7580994-c8f6-4cf4-b8aa-8ca1a3c77856"
                        ],
                        environment: ["PWD": "/tmp/background claude repo"]
                    )
                default:
                    return nil
                }
            }
        )

        let snapshot = try XCTUnwrap(
            detected[RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)]?.snapshot
        )
        XCTAssertEqual(snapshot.kind, .claude)
        XCTAssertEqual(snapshot.sessionId, "03991fdd-6581-4d4f-8d76-bf0371c2b014")
    }

    func testProcessDetectionSkipsBackgroundClaudeWithoutForegroundCandidate() {
        let workspaceId = UUID()
        let panelId = UUID()
        let ttyDevice: Int64 = 44_008
        let backgroundClaude = makeTopProcess(
            pid: 10_010,
            name: "claude",
            path: "/Users/lawrence/.local/bin/claude",
            ttyDevice: ttyDevice,
            workspaceId: workspaceId,
            panelId: panelId,
            processGroupID: 100,
            terminalProcessGroupID: 300
        )
        let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: []),
            fileManager: .default,
            processSnapshot: CmuxTopProcessSnapshot(
                processes: [backgroundClaude],
                sampledAt: Date(timeIntervalSince1970: 123),
                includesProcessDetails: false
            ),
            processArguments: { pid in
                guard pid == backgroundClaude.pid else { return nil }
                return CmuxTopProcessArguments(
                    arguments: [
                        "/Users/lawrence/.local/bin/claude",
                        "--resume",
                        "claude-background-session"
                    ],
                    environment: ["PWD": "/tmp/background claude repo"]
                )
            }
        )

        XCTAssertNil(
            detected[RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)]?.snapshot
        )
    }

    func testProcessDetectionPrefersForegroundOpenCodeOverBackgroundClaudeForSamePanel() throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let ttyDevice: Int64 = 44_003
        let backgroundClaude = makeTopProcess(
            pid: 10_003,
            name: "claude",
            path: "/Users/lawrence/.local/bin/claude",
            ttyDevice: ttyDevice,
            workspaceId: workspaceId,
            panelId: panelId,
            processGroupID: 100,
            terminalProcessGroupID: 200
        )
        let foregroundOpenCode = makeTopProcess(
            pid: 10_004,
            name: "opencode",
            path: "/opt/homebrew/bin/opencode",
            ttyDevice: ttyDevice,
            workspaceId: workspaceId,
            panelId: panelId,
            processGroupID: 300,
            terminalProcessGroupID: 300
        )
        let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: []),
            fileManager: .default,
            processSnapshot: CmuxTopProcessSnapshot(
                processes: [backgroundClaude, foregroundOpenCode],
                sampledAt: Date(timeIntervalSince1970: 123),
                includesProcessDetails: false
            ),
            processArguments: { pid in
                switch pid {
                case backgroundClaude.pid:
                    return CmuxTopProcessArguments(
                        arguments: [
                            "/Users/lawrence/.local/bin/claude",
                            "--resume",
                            "claude-background-session"
                        ],
                        environment: ["PWD": "/tmp/claude repo"]
                    )
                case foregroundOpenCode.pid:
                    return CmuxTopProcessArguments(
                        arguments: [
                            "/opt/homebrew/bin/opencode",
                            "--session",
                            "opencode-foreground-session"
                        ],
                        environment: ["PWD": "/tmp/opencode repo"]
                    )
                default:
                    return nil
                }
            }
        )

        let snapshot = try XCTUnwrap(
            detected[RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)]?.snapshot
        )
        XCTAssertEqual(snapshot.kind, .opencode)
        XCTAssertEqual(snapshot.sessionId, "opencode-foreground-session")
    }

    func testProcessDetectionPrefersFocusedTTYOpenCodeOverForegroundClaudeForSamePanel() throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let claudeTTYDevice: Int64 = 44_027
        let openCodeTTYDevice: Int64 = 44_028
        let foregroundClaude = makeTopProcess(
            pid: 10_027,
            name: "claude",
            path: "/Users/lawrence/.local/bin/claude",
            ttyDevice: claudeTTYDevice,
            workspaceId: workspaceId,
            panelId: panelId,
            processGroupID: 300,
            terminalProcessGroupID: 300
        )
        let focusedOpenCode = makeTopProcess(
            pid: 10_028,
            name: "opencode",
            path: "/opt/homebrew/bin/opencode",
            ttyDevice: openCodeTTYDevice,
            workspaceId: workspaceId,
            panelId: panelId,
            processGroupID: 400,
            terminalProcessGroupID: 400
        )
        let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: []),
            fileManager: .default,
            fallbackScope: RestorableAgentProcessDetectionScope(
                workspaceId: workspaceId,
                panelId: panelId,
                ttyDevice: openCodeTTYDevice
            ),
            processSnapshot: CmuxTopProcessSnapshot(
                processes: [foregroundClaude, focusedOpenCode],
                sampledAt: Date(timeIntervalSince1970: 123),
                includesProcessDetails: false
            ),
            processArguments: { pid in
                switch pid {
                case foregroundClaude.pid:
                    return CmuxTopProcessArguments(
                        arguments: [
                            "/Users/lawrence/.local/bin/claude",
                            "--resume",
                            "claude-foreground-session"
                        ],
                        environment: ["PWD": "/tmp/foreground claude repo"]
                    )
                case focusedOpenCode.pid:
                    return CmuxTopProcessArguments(
                        arguments: [
                            "/opt/homebrew/bin/opencode",
                            "--session",
                            "opencode-focused-session"
                        ],
                        environment: ["PWD": "/tmp/focused opencode repo"]
                    )
                default:
                    return nil
                }
            }
        )

        let snapshot = try XCTUnwrap(
            detected[RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)]?.snapshot
        )
        XCTAssertEqual(snapshot.kind, .opencode)
        XCTAssertEqual(snapshot.sessionId, "opencode-focused-session")
    }

    func testProcessDetectionPrefersFocusedTTYCodexOverForegroundClaudeForSamePanel() throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let claudeTTYDevice: Int64 = 44_032
        let codexTTYDevice: Int64 = 44_033
        let foregroundClaude = makeTopProcess(
            pid: 10_032,
            name: "claude",
            path: "/Users/lawrence/.local/bin/claude",
            ttyDevice: claudeTTYDevice,
            workspaceId: workspaceId,
            panelId: panelId,
            processGroupID: 300,
            terminalProcessGroupID: 300
        )
        let focusedCodex = makeTopProcess(
            pid: 10_033,
            name: "codex",
            path: "/Users/lawrence/.bun/bin/codex",
            ttyDevice: codexTTYDevice,
            workspaceId: workspaceId,
            panelId: panelId,
            processGroupID: 400,
            terminalProcessGroupID: 400
        )
        let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: []),
            fileManager: .default,
            fallbackScope: RestorableAgentProcessDetectionScope(
                workspaceId: workspaceId,
                panelId: panelId,
                ttyDevice: codexTTYDevice
            ),
            processSnapshot: CmuxTopProcessSnapshot(
                processes: [foregroundClaude, focusedCodex],
                sampledAt: Date(timeIntervalSince1970: 123),
                includesProcessDetails: false
            ),
            processArguments: { pid in
                switch pid {
                case foregroundClaude.pid:
                    return CmuxTopProcessArguments(
                        arguments: [
                            "/Users/lawrence/.local/bin/claude",
                            "--resume",
                            "claude-foreground-session"
                        ],
                        environment: ["PWD": "/tmp/foreground claude repo"]
                    )
                case focusedCodex.pid:
                    return CmuxTopProcessArguments(
                        arguments: [
                            "/Users/lawrence/.bun/bin/codex",
                            "--model",
                            "gpt-5.4"
                        ],
                        environment: [
                            "CODEX_THREAD_ID": "019e26a3-2c4b-7e62-b8d3-825ec5f3c696",
                            "PWD": "/tmp/focused codex repo"
                        ]
                    )
                default:
                    return nil
                }
            }
        )

        let snapshot = try XCTUnwrap(
            detected[RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)]?.snapshot
        )
        XCTAssertEqual(snapshot.kind, .codex)
        XCTAssertEqual(snapshot.sessionId, "019e26a3-2c4b-7e62-b8d3-825ec5f3c696")
    }

    func testProcessDetectionSkipsBackgroundOpenCodeWithoutForegroundCandidate() {
        let workspaceId = UUID()
        let panelId = UUID()
        let ttyDevice: Int64 = 44_009
        let backgroundOpenCode = makeTopProcess(
            pid: 10_011,
            name: "opencode",
            path: "/opt/homebrew/bin/opencode",
            ttyDevice: ttyDevice,
            workspaceId: workspaceId,
            panelId: panelId,
            processGroupID: 100,
            terminalProcessGroupID: 300
        )
        let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: []),
            fileManager: .default,
            processSnapshot: CmuxTopProcessSnapshot(
                processes: [backgroundOpenCode],
                sampledAt: Date(timeIntervalSince1970: 123),
                includesProcessDetails: false
            ),
            processArguments: { pid in
                guard pid == backgroundOpenCode.pid else { return nil }
                return CmuxTopProcessArguments(
                    arguments: [
                        "/opt/homebrew/bin/opencode",
                        "--session",
                        "opencode-background-session"
                    ],
                    environment: ["PWD": "/tmp/background opencode repo"]
                )
            }
        )

        XCTAssertNil(
            detected[RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)]?.snapshot
        )
    }

    func testProcessDetectionFocusedTTYFallbackRejectsBackgroundAndMismatchedProcesses() {
        let workspaceId = UUID()
        let panelId = UUID()
        let ttyDevice: Int64 = 44_004
        let background = makeTopProcess(
            pid: 10_005,
            name: "claude",
            path: "/Users/lawrence/.local/bin/claude",
            ttyDevice: ttyDevice,
            processGroupID: 100,
            terminalProcessGroupID: 200
        )
        let mismatched = makeTopProcess(
            pid: 10_006,
            name: "opencode",
            path: "/opt/homebrew/bin/opencode",
            ttyDevice: ttyDevice,
            workspaceId: UUID(),
            panelId: nil
        )
        let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: []),
            fileManager: .default,
            fallbackScope: RestorableAgentProcessDetectionScope(
                workspaceId: workspaceId,
                panelId: panelId,
                ttyDevice: ttyDevice
            ),
            processSnapshot: CmuxTopProcessSnapshot(
                processes: [background, mismatched],
                sampledAt: Date(timeIntervalSince1970: 123),
                includesProcessDetails: false
            ),
            processArguments: { pid in
                switch pid {
                case background.pid:
                    return CmuxTopProcessArguments(
                        arguments: [
                            "/Users/lawrence/.local/bin/claude",
                            "--resume",
                            "background-session"
                        ],
                        environment: ["PWD": "/tmp/background"]
                    )
                case mismatched.pid:
                    return CmuxTopProcessArguments(
                        arguments: [
                            "/opt/homebrew/bin/opencode",
                            "--session",
                            "mismatched-session"
                        ],
                        environment: ["PWD": "/tmp/mismatched"]
                    )
                default:
                    return nil
                }
            }
        )

        XCTAssertNil(
            detected[RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)]?.snapshot
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
                    updatedAt: 999
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
                    updatedAt: 999
                ),
            ]
        )
        let snapshot = try XCTUnwrap(index.snapshot(workspaceId: workspaceId, panelId: panelId))

        XCTAssertEqual(snapshot.sessionId, "live-process-session")
        XCTAssertEqual(snapshot.launchCommand?.source, "process")
    }

    private func makeTopProcess(
        pid: Int,
        name: String,
        path: String?,
        ttyDevice: Int64,
        workspaceId: UUID? = nil,
        panelId: UUID? = nil,
        processGroupID: Int? = 100,
        terminalProcessGroupID: Int? = 100
    ) -> CmuxTopProcessInfo {
        CmuxTopProcessInfo(
            pid: pid,
            parentPID: 1,
            name: name,
            path: path,
            ttyDevice: ttyDevice,
            cmuxWorkspaceID: workspaceId,
            cmuxSurfaceID: panelId,
            cmuxAttributionReason: workspaceId == nil && panelId == nil ? nil : "test",
            processGroupID: processGroupID,
            terminalProcessGroupID: terminalProcessGroupID,
            cpuPercent: 0,
            residentBytes: 0,
            virtualBytes: 0,
            threadCount: 1
        )
    }

    private func base64NULSeparated(_ values: [String]) -> String {
        var data = Data()
        for value in values {
            data.append(contentsOf: value.utf8)
            data.append(0)
        }
        return data.base64EncodedString()
    }

    private func writeCodexSessionMeta(
        codexHome: URL,
        sessionId: String,
        forkedFromId: String?,
        cwd: String,
        createdAt: Date? = nil,
        modifiedAt: Date
    ) throws {
        let directory = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026", isDirectory: true)
            .appendingPathComponent("05", isDirectory: true)
            .appendingPathComponent("17", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("rollout-2026-05-17T00-00-00-\(sessionId).jsonl")
        var payload: [String: Any] = [
            "id": sessionId,
            "cwd": cwd,
        ]
        if let forkedFromId {
            payload["forked_from_id"] = forkedFromId
        }
        let object: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: createdAt ?? modifiedAt),
            "type": "session_meta",
            "payload": payload,
        ]
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: fileURL.path)
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

extension SessionPersistenceTests {
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
