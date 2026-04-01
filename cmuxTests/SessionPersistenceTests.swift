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
    func testWorkspaceSessionSnapshotRestoresSerialTerminalConfiguration() throws {
        let configuration = SerialConsoleConfiguration(
            devicePath: "/dev/cu.usbserial-1410",
            baudRate: 115_200,
            dataBits: .seven,
            stopBits: .two,
            parity: .even,
            flowControl: .hardware
        )

        let workspace = Workspace(
            title: configuration.displayTitle,
            initialTerminalSerialConfiguration: configuration
        )

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let terminalSnapshot = try XCTUnwrap(snapshot.panels.first?.terminal)
        XCTAssertEqual(terminalSnapshot.serialConfiguration, configuration)

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)

        let restoredPanel = try XCTUnwrap(restored.focusedTerminalPanel)
        XCTAssertEqual(restoredPanel.serialConfiguration, configuration)
    }

    func testLoadDecodesSerialConfigurationWithUnknownEnumValues() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let panelID = UUID()
        var snapshot = makeSnapshot(version: SessionSnapshotSchema.currentVersion)
        snapshot.windows[0].tabManager.workspaces[0].focusedPanelId = panelID
        snapshot.windows[0].tabManager.workspaces[0].layout = .pane(
            SessionPaneLayoutSnapshot(panelIds: [panelID], selectedPanelId: panelID)
        )
        snapshot.windows[0].tabManager.workspaces[0].panels = [
            SessionPanelSnapshot(
                id: panelID,
                type: .terminal,
                title: "Serial",
                customTitle: nil,
                directory: "/tmp",
                isPinned: false,
                isManuallyUnread: false,
                gitBranch: nil,
                listeningPorts: [],
                ttyName: nil,
                terminal: SessionTerminalPanelSnapshot(
                    workingDirectory: "/tmp",
                    scrollback: "boot log",
                    serialConfiguration: SerialConsoleConfiguration(
                        devicePath: "/dev/cu.usbserial-1410",
                        baudRate: 115_200,
                        dataBits: .seven,
                        stopBits: .two,
                        parity: .even,
                        flowControl: .hardware
                    )
                ),
                browser: nil,
                markdown: nil
            )
        ]

        let encoded = try JSONEncoder().encode(snapshot)
        var jsonObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var windows = try XCTUnwrap(jsonObject["windows"] as? [[String: Any]])
        var window = try XCTUnwrap(windows.first)
        var tabManager = try XCTUnwrap(window["tabManager"] as? [String: Any])
        var workspaces = try XCTUnwrap(tabManager["workspaces"] as? [[String: Any]])
        var workspace = try XCTUnwrap(workspaces.first)
        var panels = try XCTUnwrap(workspace["panels"] as? [[String: Any]])
        var panel = try XCTUnwrap(panels.first)
        var terminal = try XCTUnwrap(panel["terminal"] as? [String: Any])
        var serialConfiguration = try XCTUnwrap(
            terminal["serialConfiguration"] as? [String: Any]
        )
        serialConfiguration["dataBits"] = 99
        serialConfiguration["stopBits"] = 3
        serialConfiguration["parity"] = "mark"
        serialConfiguration["flowControl"] = "custom"
        terminal["serialConfiguration"] = serialConfiguration
        panel["terminal"] = terminal
        panels[0] = panel
        workspace["panels"] = panels
        workspaces[0] = workspace
        tabManager["workspaces"] = workspaces
        window["tabManager"] = tabManager
        windows[0] = window
        jsonObject["windows"] = windows

        let snapshotURL = tempDir.appendingPathComponent("session.json", isDirectory: false)
        let mutated = try JSONSerialization.data(withJSONObject: jsonObject)
        try mutated.write(to: snapshotURL)

        let loaded = try XCTUnwrap(SessionPersistenceStore.load(fileURL: snapshotURL))
        let serialConfigurationAfterLoad = try XCTUnwrap(
            loaded.windows.first?
                .tabManager.workspaces.first?
                .panels.first?
                .terminal?
                .serialConfiguration
        )
        XCTAssertEqual(serialConfigurationAfterLoad.devicePath, "/dev/cu.usbserial-1410")
        XCTAssertEqual(serialConfigurationAfterLoad.baudRate, 115_200)
        XCTAssertEqual(serialConfigurationAfterLoad.dataBits, .eight)
        XCTAssertEqual(serialConfigurationAfterLoad.stopBits, .one)
        XCTAssertEqual(serialConfigurationAfterLoad.parity, .none)
        XCTAssertEqual(serialConfigurationAfterLoad.flowControl, .none)
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
