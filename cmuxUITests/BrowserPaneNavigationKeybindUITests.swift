import XCTest
import Foundation

final class BrowserPaneNavigationKeybindUITests: XCTestCase {
    private var dataPath = ""
    private var socketPath = ""
    private var launchDiagnosticsPath = ""
    private var launchTag = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        dataPath = "/tmp/cmux-ui-test-goto-split-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: dataPath)
        socketPath = "/tmp/cmux-ui-test-socket-\(UUID().uuidString).sock"
        try? FileManager.default.removeItem(atPath: socketPath)
        launchDiagnosticsPath = "/tmp/cmux-ui-test-launch-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: launchDiagnosticsPath)
        launchTag = "ui-tests-browser-nav-\(UUID().uuidString.prefix(8))"

        let diagnosticsPath = launchDiagnosticsPath
        addTeardownBlock { [weak self] in
            guard let self,
                  let contents = try? String(contentsOfFile: diagnosticsPath, encoding: .utf8),
                  !contents.isEmpty else {
                return
            }
            print("UI_TEST_LAUNCH_DIAGNOSTICS_BEGIN")
            print(contents)
            print("UI_TEST_LAUNCH_DIAGNOSTICS_END")
            let attachment = XCTAttachment(string: contents)
            attachment.name = "ui-test-launch-diagnostics"
            attachment.lifetime = .deleteOnSuccess
            self.add(attachment)
        }

        let cleanup = XCUIApplication()
        cleanup.terminate()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    func testCmdCtrlHMovesLeftWhenWebViewFocused() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_FOCUS_SHORTCUTS"] = "1"
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        launchAndEnsureForeground(app)

        XCTAssertTrue(
            waitForData(keys: ["terminalPaneId", "browserPaneId", "webViewFocused"], timeout: 10.0),
            "Expected goto_split setup data to be written"
        )

        guard let setup = loadData() else {
            XCTFail("Missing goto_split setup data")
            return
        }

        XCTAssertEqual(setup["webViewFocused"], "true", "Expected WKWebView to be first responder for this test")

        guard let expectedTerminalPaneId = setup["terminalPaneId"] else {
            XCTFail("Missing terminalPaneId in goto_split setup data")
            return
        }

        // Trigger pane navigation via the actual key event path (while WebKit is first responder).
        app.typeKey("h", modifierFlags: [.command, .control])

        XCTAssertTrue(
            waitForDataMatch(timeout: 5.0) { data in
                data["lastMoveDirection"] == "left" && data["focusedPaneId"] == expectedTerminalPaneId
            },
            "Expected Cmd+Ctrl+H to move focus to left pane (terminal)"
        )
    }

    func testCmdCtrlHMovesLeftWhenWebViewFocusedUsingGhosttyConfigKeybind() {
        // Write a test Ghostty config in the preferred macOS location so GhosttyKit loads it at app startup.
        let fileManager = FileManager.default
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            XCTFail("Missing Application Support directory")
            return
        }

        let ghosttyDir = appSupport.appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)
        let configURL = ghosttyDir.appendingPathComponent("config.ghostty", isDirectory: false)

        do {
            try fileManager.createDirectory(at: ghosttyDir, withIntermediateDirectories: true)
        } catch {
            XCTFail("Failed to create Ghostty app support dir: \(error)")
            return
        }

        let originalConfigData = try? Data(contentsOf: configURL)
        addTeardownBlock {
            if let originalConfigData {
                try? originalConfigData.write(to: configURL, options: .atomic)
            } else {
                try? fileManager.removeItem(at: configURL)
            }
        }

        let home = fileManager.homeDirectoryForCurrentUser
        let configContents = """
        # cmux ui test
        working-directory = \(home.path)
        keybind = cmd+ctrl+h=goto_split:left
        """
        do {
            try configContents.write(to: configURL, atomically: true, encoding: .utf8)
        } catch {
            XCTFail("Failed to write Ghostty config: \(error)")
            return
        }

        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_FOCUS_SHORTCUTS"] = "1"
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_USE_GHOSTTY_CONFIG"] = "1"
        launchAndEnsureForeground(app)

        XCTAssertTrue(
            waitForData(keys: ["terminalPaneId", "browserPaneId", "webViewFocused", "ghosttyGotoSplitLeftShortcut"], timeout: 10.0),
            "Expected goto_split setup data to be written"
        )

        guard let setup = loadData() else {
            XCTFail("Missing goto_split setup data")
            return
        }

        XCTAssertEqual(setup["webViewFocused"], "true", "Expected WKWebView to be first responder for this test")
        XCTAssertFalse((setup["ghosttyGotoSplitLeftShortcut"] ?? "").isEmpty, "Expected Ghostty trigger metadata to be present")

        guard let expectedTerminalPaneId = setup["terminalPaneId"] else {
            XCTFail("Missing terminalPaneId in goto_split setup data")
            return
        }

        // Trigger pane navigation via the actual key event path (while WebKit is first responder).
        app.typeKey("h", modifierFlags: [.command, .control])

        XCTAssertTrue(
            waitForDataMatch(timeout: 5.0) { data in
                data["lastMoveDirection"] == "left" && data["focusedPaneId"] == expectedTerminalPaneId
            },
            "Expected Cmd+Ctrl+H to move focus to left pane (terminal) via Ghostty config trigger"
        )
    }

    func testEscapeLeavesOmnibarAndFocusesWebView() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_FOCUS_SHORTCUTS"] = "1"
        launchAndEnsureForeground(app)

        XCTAssertTrue(
            waitForData(keys: ["browserPanelId", "webViewFocused"], timeout: 10.0),
            "Expected goto_split setup data to be written"
        )

        guard let setup = loadData() else {
            XCTFail("Missing goto_split setup data")
            return
        }

        XCTAssertEqual(setup["webViewFocused"], "true", "Expected WKWebView to be first responder for this test")

        // Cmd+L focuses the omnibar (so WebKit is no longer first responder).
        app.typeKey("l", modifierFlags: [.command])
        XCTAssertTrue(
            waitForDataMatch(timeout: 5.0) { data in
                data["webViewFocusedAfterAddressBarFocus"] == "false"
            },
            "Expected Cmd+L to focus omnibar (WebKit not first responder)"
        )

        // Escape should leave the omnibar and focus WebKit again.
        // Send Escape twice: the first may only clear suggestions/editing state
        // (Chrome-like two-stage escape), the second triggers blur to WebView.
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        if !waitForDataMatch(timeout: 2.0, predicate: { $0["webViewFocusedAfterAddressBarExit"] == "true" }) {
            app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        }
        XCTAssertTrue(
            waitForDataMatch(timeout: 5.0) { data in
                data["webViewFocusedAfterAddressBarExit"] == "true"
            },
            "Expected Escape to return focus to WebKit"
        )
    }

    func testEscapeRestoresFocusedPageInputAfterCmdL() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_FOCUS_SHORTCUTS"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_INPUT_SETUP"] = "1"
        launchAndEnsureForeground(app)

        XCTAssertTrue(
            waitForData(
                keys: [
                    "browserPanelId",
                    "webViewFocused",
                    "webInputFocusSeeded",
                    "webInputFocusElementId",
                    "webInputFocusSecondaryElementId",
                    "webInputFocusSecondaryClickOffsetX",
                    "webInputFocusSecondaryClickOffsetY"
                ],
                timeout: 12.0
            ),
            "Expected setup data including focused page input to be written"
        )

        guard let setup = loadData() else {
            XCTFail("Missing goto_split setup data")
            return
        }

        XCTAssertEqual(setup["webViewFocused"], "true", "Expected WKWebView to be first responder for this test")
        XCTAssertEqual(setup["webInputFocusSeeded"], "true", "Expected test page input to be focused before Cmd+L")

        guard let expectedInputId = setup["webInputFocusElementId"], !expectedInputId.isEmpty else {
            XCTFail("Missing webInputFocusElementId in setup data")
            return
        }
        guard let expectedSecondaryInputId = setup["webInputFocusSecondaryElementId"], !expectedSecondaryInputId.isEmpty else {
            XCTFail("Missing webInputFocusSecondaryElementId in setup data")
            return
        }
        guard let secondaryClickOffsetXRaw = setup["webInputFocusSecondaryClickOffsetX"],
              let secondaryClickOffsetYRaw = setup["webInputFocusSecondaryClickOffsetY"],
              let secondaryClickOffsetX = Double(secondaryClickOffsetXRaw),
              let secondaryClickOffsetY = Double(secondaryClickOffsetYRaw) else {
            XCTFail(
                "Missing or invalid secondary input click offsets in setup data. " +
                "webInputFocusSecondaryClickOffsetX=\(setup["webInputFocusSecondaryClickOffsetX"] ?? "nil") " +
                "webInputFocusSecondaryClickOffsetY=\(setup["webInputFocusSecondaryClickOffsetY"] ?? "nil")"
            )
            return
        }

        app.typeKey("l", modifierFlags: [.command])
        XCTAssertTrue(
            waitForDataMatch(timeout: 5.0) { data in
                data["webViewFocusedAfterAddressBarFocus"] == "false"
            },
            "Expected Cmd+L to focus omnibar"
        )

        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        if !waitForDataMatch(timeout: 2.0, predicate: { data in
            data["webViewFocusedAfterAddressBarExit"] == "true" &&
                data["addressBarExitActiveElementId"] == expectedInputId &&
                data["addressBarExitActiveElementEditable"] == "true"
        }) {
            app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        }

        let restoredExpectedInput = waitForDataMatch(timeout: 6.0) { data in
            data["webViewFocusedAfterAddressBarExit"] == "true" &&
                data["addressBarExitActiveElementId"] == expectedInputId &&
                data["addressBarExitActiveElementEditable"] == "true"
        }
        if !restoredExpectedInput {
            let snapshot = loadData() ?? [:]
            XCTFail(
                "Expected Escape to restore focus to the previously focused page input. " +
                "expectedInputId=\(expectedInputId) " +
                "webViewFocusedAfterAddressBarExit=\(snapshot["webViewFocusedAfterAddressBarExit"] ?? "nil") " +
                "addressBarExitActiveElementId=\(snapshot["addressBarExitActiveElementId"] ?? "nil") " +
                "addressBarExitActiveElementTag=\(snapshot["addressBarExitActiveElementTag"] ?? "nil") " +
                "addressBarExitActiveElementType=\(snapshot["addressBarExitActiveElementType"] ?? "nil") " +
                "addressBarExitActiveElementEditable=\(snapshot["addressBarExitActiveElementEditable"] ?? "nil") " +
                "addressBarExitTrackedFocusStateId=\(snapshot["addressBarExitTrackedFocusStateId"] ?? "nil") " +
                "addressBarExitFocusTrackerInstalled=\(snapshot["addressBarExitFocusTrackerInstalled"] ?? "nil") " +
                "addressBarFocusActiveElementId=\(snapshot["addressBarFocusActiveElementId"] ?? "nil") " +
                "addressBarFocusTrackedFocusStateId=\(snapshot["addressBarFocusTrackedFocusStateId"] ?? "nil") " +
                "addressBarFocusFocusTrackerInstalled=\(snapshot["addressBarFocusFocusTrackerInstalled"] ?? "nil") " +
                "webInputFocusElementId=\(snapshot["webInputFocusElementId"] ?? "nil") " +
                "webInputFocusTrackerInstalled=\(snapshot["webInputFocusTrackerInstalled"] ?? "nil") " +
                "webInputFocusTrackedStateId=\(snapshot["webInputFocusTrackedStateId"] ?? "nil")"
            )
        }

        let window = app.windows.firstMatch
        XCTAssertTrue(
            window.waitForExistence(timeout: 6.0),
            "Expected app window for post-escape click regression check"
        )

        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        window
            .coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.0))
            .withOffset(CGVector(dx: secondaryClickOffsetX, dy: secondaryClickOffsetY))
            .click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))

        app.typeKey("l", modifierFlags: [.command])
        let clickMovedFocusToSecondary = waitForDataMatch(timeout: 6.0) { data in
            data["webViewFocusedAfterAddressBarFocus"] == "false" &&
                data["addressBarFocusActiveElementId"] == expectedSecondaryInputId &&
                data["addressBarFocusActiveElementEditable"] == "true"
        }
        if !clickMovedFocusToSecondary {
            let snapshot = loadData() ?? [:]
            XCTFail(
                "Expected post-escape click to focus secondary page input before Cmd+L. " +
                "secondaryInputId=\(expectedSecondaryInputId) " +
                "addressBarFocusActiveElementId=\(snapshot["addressBarFocusActiveElementId"] ?? "nil") " +
                "addressBarFocusActiveElementTag=\(snapshot["addressBarFocusActiveElementTag"] ?? "nil") " +
                "addressBarFocusActiveElementType=\(snapshot["addressBarFocusActiveElementType"] ?? "nil") " +
                "addressBarFocusActiveElementEditable=\(snapshot["addressBarFocusActiveElementEditable"] ?? "nil") " +
                "addressBarFocusTrackedFocusStateId=\(snapshot["addressBarFocusTrackedFocusStateId"] ?? "nil") " +
                "addressBarFocusFocusTrackerInstalled=\(snapshot["addressBarFocusFocusTrackerInstalled"] ?? "nil")"
            )
        }

        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        if !waitForDataMatch(timeout: 2.0, predicate: { data in
            data["webViewFocusedAfterAddressBarExit"] == "true" &&
                data["addressBarExitActiveElementId"] == expectedSecondaryInputId &&
                data["addressBarExitActiveElementEditable"] == "true"
        }) {
            app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        }

        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                data["webViewFocusedAfterAddressBarExit"] == "true" &&
                    data["addressBarExitActiveElementId"] == expectedSecondaryInputId &&
                    data["addressBarExitActiveElementEditable"] == "true"
            },
            "Expected Escape to restore focus to the clicked secondary page input"
        )
    }

    func testArrowKeysReachClickedPageInputAfterCmdL() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_FOCUS_SHORTCUTS"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_INPUT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_ARROW_SETUP"] = "1"
        launchAndEnsureForeground(app)

        XCTAssertTrue(
            waitForData(
                keys: [
                    "browserPanelId",
                    "webViewFocused",
                    "webInputFocusSeeded",
                    "webInputFocusElementId",
                    "webInputFocusSecondaryElementId",
                    "webInputFocusPrimaryClickOffsetX",
                    "webInputFocusPrimaryClickOffsetY",
                    "webInputFocusSecondaryClickOffsetX",
                    "webInputFocusSecondaryClickOffsetY"
                ],
                timeout: 20.0
            ),
            "Expected focused page input setup data to be written. data=\(String(describing: loadData()))"
        )

        guard let setup = loadData() else {
            XCTFail("Missing goto_split setup data")
            return
        }

        XCTAssertEqual(setup["webInputFocusSeeded"], "true", "Expected test page input to be focused before arrow-key checks")
        guard let primaryInputId = setup["webInputFocusElementId"], !primaryInputId.isEmpty else {
            XCTFail("Missing webInputFocusElementId in setup data")
            return
        }
        guard let secondaryInputId = setup["webInputFocusSecondaryElementId"], !secondaryInputId.isEmpty else {
            XCTFail("Missing webInputFocusSecondaryElementId in setup data")
            return
        }
        guard let primaryClickOffsetXRaw = setup["webInputFocusPrimaryClickOffsetX"],
              let primaryClickOffsetYRaw = setup["webInputFocusPrimaryClickOffsetY"],
              let primaryClickOffsetX = Double(primaryClickOffsetXRaw),
              let primaryClickOffsetY = Double(primaryClickOffsetYRaw) else {
            XCTFail(
                "Missing or invalid primary input click offsets in setup data. " +
                "webInputFocusPrimaryClickOffsetX=\(setup["webInputFocusPrimaryClickOffsetX"] ?? "nil") " +
                "webInputFocusPrimaryClickOffsetY=\(setup["webInputFocusPrimaryClickOffsetY"] ?? "nil")"
            )
            return
        }
        guard let secondaryClickOffsetXRaw = setup["webInputFocusSecondaryClickOffsetX"],
              let secondaryClickOffsetYRaw = setup["webInputFocusSecondaryClickOffsetY"],
              let secondaryClickOffsetX = Double(secondaryClickOffsetXRaw),
              let secondaryClickOffsetY = Double(secondaryClickOffsetYRaw) else {
            XCTFail(
                "Missing or invalid secondary input click offsets in setup data. " +
                "webInputFocusSecondaryClickOffsetX=\(setup["webInputFocusSecondaryClickOffsetX"] ?? "nil") " +
                "webInputFocusSecondaryClickOffsetY=\(setup["webInputFocusSecondaryClickOffsetY"] ?? "nil")"
            )
            return
        }

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5.0), "Expected main window before arrow-key regression check")

        window
            .coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.0))
            .withOffset(CGVector(dx: primaryClickOffsetX, dy: primaryClickOffsetY))
            .click()

        guard let initialArrowSnapshot = waitForDataSnapshot(
            timeout: 8.0,
            predicate: { data in
                data["browserArrowInstalled"] == "true" &&
                    data["browserArrowActiveElementId"] == primaryInputId &&
                    data["browserArrowDownCount"] == "0" &&
                    data["browserArrowUpCount"] == "0"
            }
        ) else {
            XCTFail(
                "Expected arrow recorder to initialize with the primary page input focused. " +
                "data=\(String(describing: loadData()))"
            )
            return
        }
        let initialDownCount = Int(initialArrowSnapshot["browserArrowDownCount"] ?? "") ?? -1
        let initialUpCount = Int(initialArrowSnapshot["browserArrowUpCount"] ?? "") ?? -1

        simulateShortcut("down", app: app)
        guard let baselineDownSnapshot = waitForDataSnapshot(
            timeout: 5.0,
            predicate: { data in
                data["browserArrowActiveElementId"] == primaryInputId &&
                    data["browserArrowDownCount"] == "\(initialDownCount + 1)" &&
                    data["browserArrowUpCount"] == "\(initialUpCount)"
            }
        ) else {
            XCTFail(
                "Expected baseline Down Arrow to reach the primary page input. " +
                "data=\(String(describing: loadData()))"
            )
            return
        }
        let baselineDownCount = Int(baselineDownSnapshot["browserArrowDownCount"] ?? "") ?? -1
        let baselineUpCount = Int(baselineDownSnapshot["browserArrowUpCount"] ?? "") ?? -1

        simulateShortcut("up", app: app)
        guard let baselineUpSnapshot = waitForDataSnapshot(
            timeout: 5.0,
            predicate: { data in
                data["browserArrowActiveElementId"] == primaryInputId &&
                    data["browserArrowDownCount"] == "\(baselineDownCount)" &&
                    data["browserArrowUpCount"] == "\(baselineUpCount + 1)"
            }
        ) else {
            XCTFail(
                "Expected baseline Up Arrow to reach the primary page input. " +
                "data=\(String(describing: loadData()))"
            )
            return
        }
        let baselineUpCountAfterUp = Int(baselineUpSnapshot["browserArrowUpCount"] ?? "") ?? -1

        app.typeKey("l", modifierFlags: [.command])
        XCTAssertTrue(
            waitForDataMatch(timeout: 5.0) { data in
                data["webViewFocusedAfterAddressBarFocus"] == "false"
            },
            "Expected Cmd+L to focus the omnibar before the page-click arrow-key check"
        )

        window
            .coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.0))
            .withOffset(CGVector(dx: secondaryClickOffsetX, dy: secondaryClickOffsetY))
            .click()

        guard waitForDataMatch(
            timeout: 5.0,
            predicate: { data in
                data["browserArrowActiveElementId"] == secondaryInputId
            }
        ) else {
            XCTFail(
                "Expected clicking the page to focus the secondary page input before sending arrows. " +
                "data=\(String(describing: loadData()))"
            )
            return
        }

        simulateShortcut("down", app: app)
        guard let postCmdLDownSnapshot = waitForDataSnapshot(
            timeout: 5.0,
            predicate: { data in
                data["browserArrowActiveElementId"] == secondaryInputId &&
                    data["browserArrowDownCount"] == "\(baselineDownCount + 1)" &&
                    data["browserArrowUpCount"] == "\(baselineUpCountAfterUp)"
            }
        ) else {
            XCTFail(
                "Expected Down Arrow after Cmd+L and page click to reach the secondary page input. " +
                "data=\(String(describing: loadData()))"
            )
            return
        }
        let postCmdLDownCount = Int(postCmdLDownSnapshot["browserArrowDownCount"] ?? "") ?? -1

        simulateShortcut("up", app: app)
        guard let postCmdLUpSnapshot = waitForDataSnapshot(
            timeout: 5.0,
            predicate: { data in
                data["browserArrowActiveElementId"] == secondaryInputId &&
                    data["browserArrowDownCount"] == "\(postCmdLDownCount)" &&
                    data["browserArrowUpCount"] == "\(baselineUpCountAfterUp + 1)"
            }
        ) else {
            XCTFail(
                "Expected Up Arrow after Cmd+L and page click to reach the secondary page input. " +
                "postCmdLDownSnapshot=\(postCmdLDownSnapshot) " +
                "data=\(String(describing: loadData()))"
            )
            return
        }

        let baselineCommandShiftDownCount = Int(postCmdLUpSnapshot["browserArrowCommandShiftDownCount"] ?? "") ?? -1
        let baselineCommandShiftUpCount = Int(postCmdLUpSnapshot["browserArrowCommandShiftUpCount"] ?? "") ?? -1
        guard baselineCommandShiftDownCount >= 0, baselineCommandShiftUpCount >= 0 else {
            XCTFail(
                "Expected browser arrow recorder to report Cmd+Shift+arrow counters. " +
                "data=\(String(describing: loadData()))"
            )
            return
        }

        simulateShortcut("cmdShiftDown", app: app)
        guard let postCmdLCommandShiftDownSnapshot = waitForDataSnapshot(
            timeout: 5.0,
            predicate: { data in
                data["browserArrowActiveElementId"] == secondaryInputId &&
                    data["browserArrowCommandShiftDownCount"] == "\(baselineCommandShiftDownCount + 1)" &&
                    data["browserArrowCommandShiftUpCount"] == "\(baselineCommandShiftUpCount)"
            }
        ) else {
            XCTFail(
                "Expected Cmd+Shift+Down after Cmd+L and page click to reach the secondary page input. " +
                "data=\(String(describing: loadData()))"
            )
            return
        }
        let postCmdLCommandShiftDownCount = Int(postCmdLCommandShiftDownSnapshot["browserArrowCommandShiftDownCount"] ?? "") ?? -1
        let postCmdLCommandShiftUpCount = Int(postCmdLCommandShiftDownSnapshot["browserArrowCommandShiftUpCount"] ?? "") ?? -1
        guard postCmdLCommandShiftDownCount >= 0, postCmdLCommandShiftUpCount >= 0 else {
            XCTFail(
                "Expected browser arrow recorder to report Cmd+Shift+Down counters. " +
                "data=\(String(describing: loadData()))"
            )
            return
        }

        simulateShortcut("cmdShiftUp", app: app)
        guard let postCmdLCommandShiftUpSnapshot = waitForDataSnapshot(
            timeout: 5.0,
            predicate: { data in
                data["browserArrowActiveElementId"] == secondaryInputId &&
                    data["browserArrowCommandShiftDownCount"] == "\(postCmdLCommandShiftDownCount)" &&
                    data["browserArrowCommandShiftUpCount"] == "\(postCmdLCommandShiftUpCount + 1)"
            }
        ) else {
            XCTFail(
                "Expected Cmd+Shift+Up after Cmd+L and page click to reach the secondary page input. " +
                "data=\(String(describing: loadData()))"
            )
            return
        }

        XCTAssertEqual(postCmdLUpSnapshot["browserArrowActiveElementId"], secondaryInputId, "Expected the clicked secondary page input to remain focused")
        XCTAssertEqual(postCmdLCommandShiftUpSnapshot["browserArrowActiveElementId"], secondaryInputId, "Expected the clicked secondary page input to remain focused after Cmd+Shift+arrows")
    }

    func testArrowKeysDoNotLeakToPageWhileOmnibarFocused() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_FOCUS_SHORTCUTS"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_INPUT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_ARROW_SETUP"] = "1"
        launchAndEnsureForeground(app)

        XCTAssertTrue(
            waitForData(
                keys: [
                    "browserPanelId",
                    "webInputFocusSeeded",
                    "webInputFocusElementId",
                    "webInputFocusPrimaryClickOffsetX",
                    "webInputFocusPrimaryClickOffsetY"
                ],
                timeout: 20.0
            ),
            "Expected focused page input setup data before omnibar leak check. data=\(String(describing: loadData()))"
        )

        guard let setup = loadData() else {
            XCTFail("Missing goto_split setup data")
            return
        }

        guard let browserPanelId = setup["browserPanelId"], !browserPanelId.isEmpty else {
            XCTFail("Missing browserPanelId in setup data")
            return
        }
        guard let primaryInputId = setup["webInputFocusElementId"], !primaryInputId.isEmpty else {
            XCTFail("Missing webInputFocusElementId in setup data")
            return
        }
        guard let primaryClickOffsetXRaw = setup["webInputFocusPrimaryClickOffsetX"],
              let primaryClickOffsetYRaw = setup["webInputFocusPrimaryClickOffsetY"],
              let primaryClickOffsetX = Double(primaryClickOffsetXRaw),
              let primaryClickOffsetY = Double(primaryClickOffsetYRaw) else {
            XCTFail(
                "Missing or invalid primary input click offsets in setup data. " +
                "webInputFocusPrimaryClickOffsetX=\(setup["webInputFocusPrimaryClickOffsetX"] ?? "nil") " +
                "webInputFocusPrimaryClickOffsetY=\(setup["webInputFocusPrimaryClickOffsetY"] ?? "nil")"
            )
            return
        }

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5.0), "Expected main window before omnibar leak check")

        window
            .coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.0))
            .withOffset(CGVector(dx: primaryClickOffsetX, dy: primaryClickOffsetY))
            .click()

        guard let initialSnapshot = waitForDataSnapshot(
            timeout: 8.0,
            predicate: { data in
                data["browserArrowInstalled"] == "true" &&
                    data["browserArrowActiveElementId"] == primaryInputId &&
                    data["browserArrowDownCount"] == "0" &&
                    data["browserArrowUpCount"] == "0" &&
                    data["browserArrowCommandShiftDownCount"] == "0" &&
                    data["browserArrowCommandShiftUpCount"] == "0"
            }
        ) else {
            XCTFail("Expected page input to be focused before omnibar leak check. data=\(String(describing: loadData()))")
            return
        }

        let baselineDownCount = Int(initialSnapshot["browserArrowDownCount"] ?? "") ?? -1
        let baselineUpCount = Int(initialSnapshot["browserArrowUpCount"] ?? "") ?? -1
        let baselineCommandShiftDownCount = Int(initialSnapshot["browserArrowCommandShiftDownCount"] ?? "") ?? -1
        let baselineCommandShiftUpCount = Int(initialSnapshot["browserArrowCommandShiftUpCount"] ?? "") ?? -1
        guard baselineDownCount == 0,
              baselineUpCount == 0,
              baselineCommandShiftDownCount == 0,
              baselineCommandShiftUpCount == 0 else {
            XCTFail("Expected zeroed arrow counters before omnibar leak check. data=\(initialSnapshot)")
            return
        }

        app.typeKey("l", modifierFlags: [.command])
        XCTAssertTrue(
            waitForDataMatch(timeout: 5.0) { data in
                data["webViewFocusedAfterAddressBarFocus"] == "false" &&
                    data["webViewFocusedAfterAddressBarFocusPanelId"] == browserPanelId &&
                    data["browserArrowFocusedAddressBarPanelId"] == browserPanelId
            },
            "Expected Cmd+L to keep omnibar focused before leak check. data=\(String(describing: loadData()))"
        )

        simulateShortcut("down", app: app)
        XCTAssertTrue(
            browserArrowCountersRemainUnchanged(
                down: baselineDownCount,
                up: baselineUpCount,
                commandShiftDown: baselineCommandShiftDownCount,
                commandShiftUp: baselineCommandShiftUpCount,
                timeout: 1.0
            ),
            "Expected Down Arrow to stay out of the page while omnibar remained focused. data=\(String(describing: loadData()))"
        )

        simulateShortcut("up", app: app)
        XCTAssertTrue(
            browserArrowCountersRemainUnchanged(
                down: baselineDownCount,
                up: baselineUpCount,
                commandShiftDown: baselineCommandShiftDownCount,
                commandShiftUp: baselineCommandShiftUpCount,
                timeout: 1.0
            ),
            "Expected Up Arrow to stay out of the page while omnibar remained focused. data=\(String(describing: loadData()))"
        )

        simulateShortcut("cmdShiftDown", app: app)
        XCTAssertTrue(
            browserArrowCountersRemainUnchanged(
                down: baselineDownCount,
                up: baselineUpCount,
                commandShiftDown: baselineCommandShiftDownCount,
                commandShiftUp: baselineCommandShiftUpCount,
                timeout: 1.0
            ),
            "Expected Cmd+Shift+Down to stay out of the page while omnibar remained focused. data=\(String(describing: loadData()))"
        )

        simulateShortcut("cmdShiftUp", app: app)
        XCTAssertTrue(
            browserArrowCountersRemainUnchanged(
                down: baselineDownCount,
                up: baselineUpCount,
                commandShiftDown: baselineCommandShiftDownCount,
                commandShiftUp: baselineCommandShiftUpCount,
                timeout: 1.0
            ),
            "Expected Cmd+Shift+Up to stay out of the page while omnibar remained focused. data=\(String(describing: loadData()))"
        )
    }

    func testArrowKeysReachClickedTextareaAfterCmdL() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_FOCUS_SHORTCUTS"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_INPUT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_ARROW_SETUP"] = "1"
        launchAndEnsureForeground(app)

        XCTAssertTrue(
            waitForData(
                keys: [
                    "browserPanelId",
                    "webViewFocused",
                    "webInputFocusSeeded",
                    "webInputFocusTextareaElementId",
                    "webInputFocusTextareaClickOffsetX",
                    "webInputFocusTextareaClickOffsetY"
                ],
                timeout: 20.0
            ),
            "Expected textarea setup data to be written. data=\(String(describing: loadData()))"
        )

        guard let setup = loadData() else {
            XCTFail("Missing goto_split setup data")
            return
        }

        guard let browserPanelId = setup["browserPanelId"], !browserPanelId.isEmpty else {
            XCTFail("Missing browserPanelId in setup data")
            return
        }
        XCTAssertEqual(setup["webInputFocusSeeded"], "true", "Expected page input harness to be seeded before textarea check")
        guard let textareaId = setup["webInputFocusTextareaElementId"], !textareaId.isEmpty else {
            XCTFail("Missing webInputFocusTextareaElementId in setup data")
            return
        }
        guard let textareaClickOffsetXRaw = setup["webInputFocusTextareaClickOffsetX"],
              let textareaClickOffsetYRaw = setup["webInputFocusTextareaClickOffsetY"],
              let textareaClickOffsetX = Double(textareaClickOffsetXRaw),
              let textareaClickOffsetY = Double(textareaClickOffsetYRaw) else {
            XCTFail(
                "Missing or invalid textarea click offsets in setup data. " +
                "webInputFocusTextareaClickOffsetX=\(setup["webInputFocusTextareaClickOffsetX"] ?? "nil") " +
                "webInputFocusTextareaClickOffsetY=\(setup["webInputFocusTextareaClickOffsetY"] ?? "nil")"
            )
            return
        }

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5.0), "Expected main window before textarea regression check")

        window
            .coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.0))
            .withOffset(CGVector(dx: textareaClickOffsetX, dy: textareaClickOffsetY))
            .click()

        guard let initialSnapshot = waitForDataSnapshot(
            timeout: 8.0,
            predicate: { data in
                data["browserArrowInstalled"] == "true" &&
                    data["browserArrowActiveElementId"] == textareaId &&
                    data["browserArrowDownCount"] == "0" &&
                    data["browserArrowUpCount"] == "0" &&
                    data["browserArrowCommandShiftDownCount"] == "0" &&
                    data["browserArrowCommandShiftUpCount"] == "0"
            }
        ) else {
            XCTFail("Expected textarea to be focused before baseline arrows. data=\(String(describing: loadData()))")
            return
        }

        let initialDownCount = Int(initialSnapshot["browserArrowDownCount"] ?? "") ?? -1
        let initialUpCount = Int(initialSnapshot["browserArrowUpCount"] ?? "") ?? -1
        let initialCommandShiftDownCount = Int(initialSnapshot["browserArrowCommandShiftDownCount"] ?? "") ?? -1
        let initialCommandShiftUpCount = Int(initialSnapshot["browserArrowCommandShiftUpCount"] ?? "") ?? -1

        simulateShortcut("down", app: app)
        guard let baselineDownSnapshot = waitForDataSnapshot(
            timeout: 5.0,
            predicate: { data in
                data["browserArrowActiveElementId"] == textareaId &&
                    data["browserArrowDownCount"] == "\(initialDownCount + 1)" &&
                    data["browserArrowUpCount"] == "\(initialUpCount)"
            }
        ) else {
            XCTFail("Expected baseline Down Arrow to reach the textarea. data=\(String(describing: loadData()))")
            return
        }
        let baselineDownCount = Int(baselineDownSnapshot["browserArrowDownCount"] ?? "") ?? -1

        simulateShortcut("up", app: app)
        guard waitForDataMatch(
            timeout: 5.0,
            predicate: { data in
                data["browserArrowActiveElementId"] == textareaId &&
                    data["browserArrowDownCount"] == "\(baselineDownCount)" &&
                    data["browserArrowUpCount"] == "\(initialUpCount + 1)"
            }
        ) else {
            XCTFail("Expected baseline Up Arrow to reach the textarea. data=\(String(describing: loadData()))")
            return
        }
        simulateShortcut("cmdShiftDown", app: app)
        guard let baselineCommandShiftDownSnapshot = waitForDataSnapshot(
            timeout: 5.0,
            predicate: { data in
                data["browserArrowActiveElementId"] == textareaId &&
                    data["browserArrowCommandShiftDownCount"] == "\(initialCommandShiftDownCount + 1)" &&
                    data["browserArrowCommandShiftUpCount"] == "\(initialCommandShiftUpCount)"
            }
        ) else {
            XCTFail("Expected baseline Cmd+Shift+Down to reach the textarea. data=\(String(describing: loadData()))")
            return
        }
        let baselineCommandShiftDownCount = Int(baselineCommandShiftDownSnapshot["browserArrowCommandShiftDownCount"] ?? "") ?? -1

        simulateShortcut("cmdShiftUp", app: app)
        guard let baselineCommandShiftUpSnapshot = waitForDataSnapshot(
            timeout: 5.0,
            predicate: { data in
                data["browserArrowActiveElementId"] == textareaId &&
                    data["browserArrowCommandShiftDownCount"] == "\(baselineCommandShiftDownCount)" &&
                    data["browserArrowCommandShiftUpCount"] == "\(initialCommandShiftUpCount + 1)"
            }
        ) else {
            XCTFail("Expected baseline Cmd+Shift+Up to reach the textarea. data=\(String(describing: loadData()))")
            return
        }
        let baselineDownCountAfterModifiers = Int(baselineCommandShiftUpSnapshot["browserArrowDownCount"] ?? "") ?? -1
        let baselineUpCountAfterModifiers = Int(baselineCommandShiftUpSnapshot["browserArrowUpCount"] ?? "") ?? -1
        let baselineCommandShiftUpCount = Int(baselineCommandShiftUpSnapshot["browserArrowCommandShiftUpCount"] ?? "") ?? -1

        app.typeKey("l", modifierFlags: [.command])
        XCTAssertTrue(
            waitForDataMatch(timeout: 5.0) { data in
                data["webViewFocusedAfterAddressBarFocus"] == "false" &&
                    data["webViewFocusedAfterAddressBarFocusPanelId"] == browserPanelId &&
                    data["browserArrowFocusedAddressBarPanelId"] == browserPanelId
            },
            "Expected Cmd+L to focus omnibar before the textarea click path"
        )

        window
            .coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.0))
            .withOffset(CGVector(dx: textareaClickOffsetX, dy: textareaClickOffsetY))
            .click()

        guard waitForDataMatch(
            timeout: 5.0,
            predicate: { data in
                data["browserArrowActiveElementId"] == textareaId
            }
        ) else {
            XCTFail("Expected clicking the page to re-focus the textarea after Cmd+L. data=\(String(describing: loadData()))")
            return
        }

        simulateShortcut("down", app: app)
        guard let postCmdLDownSnapshot = waitForDataSnapshot(
            timeout: 5.0,
            predicate: { data in
                data["browserArrowActiveElementId"] == textareaId &&
                    data["browserArrowDownCount"] == "\(baselineDownCountAfterModifiers + 1)" &&
                    data["browserArrowUpCount"] == "\(baselineUpCountAfterModifiers)" &&
                    data["browserArrowCommandShiftDownCount"] == "\(baselineCommandShiftDownCount)" &&
                    data["browserArrowCommandShiftUpCount"] == "\(baselineCommandShiftUpCount)"
            }
        ) else {
            XCTFail("Expected Down Arrow after Cmd+L to reach the textarea. data=\(String(describing: loadData()))")
            return
        }
        let postCmdLDownCount = Int(postCmdLDownSnapshot["browserArrowDownCount"] ?? "") ?? -1

        simulateShortcut("up", app: app)
        guard let postCmdLUpSnapshot = waitForDataSnapshot(
            timeout: 5.0,
            predicate: { data in
                data["browserArrowActiveElementId"] == textareaId &&
                    data["browserArrowDownCount"] == "\(postCmdLDownCount)" &&
                    data["browserArrowUpCount"] == "\(baselineUpCountAfterModifiers + 1)"
            }
        ) else {
            XCTFail("Expected Up Arrow after Cmd+L to reach the textarea. data=\(String(describing: loadData()))")
            return
        }
        let postCmdLUpCount = Int(postCmdLUpSnapshot["browserArrowUpCount"] ?? "") ?? -1

        simulateShortcut("cmdShiftDown", app: app)
        guard let postCmdLCommandShiftDownSnapshot = waitForDataSnapshot(
            timeout: 5.0,
            predicate: { data in
                data["browserArrowActiveElementId"] == textareaId &&
                    data["browserArrowDownCount"] == "\(postCmdLDownCount + 1)" &&
                    data["browserArrowUpCount"] == "\(postCmdLUpCount)" &&
                    data["browserArrowCommandShiftDownCount"] == "\(baselineCommandShiftDownCount + 1)" &&
                    data["browserArrowCommandShiftUpCount"] == "\(baselineCommandShiftUpCount)"
            }
        ) else {
            XCTFail("Expected Cmd+Shift+Down after Cmd+L to reach the textarea. data=\(String(describing: loadData()))")
            return
        }
        let postCmdLDownCountAfterCommandShiftDown = Int(postCmdLCommandShiftDownSnapshot["browserArrowDownCount"] ?? "") ?? -1
        let postCmdLCommandShiftDownCount = Int(postCmdLCommandShiftDownSnapshot["browserArrowCommandShiftDownCount"] ?? "") ?? -1

        simulateShortcut("cmdShiftUp", app: app)
        guard let postCmdLCommandShiftUpSnapshot = waitForDataSnapshot(
            timeout: 5.0,
            predicate: { data in
                data["browserArrowActiveElementId"] == textareaId &&
                    data["browserArrowDownCount"] == "\(postCmdLDownCountAfterCommandShiftDown)" &&
                    data["browserArrowUpCount"] == "\(postCmdLUpCount + 1)" &&
                    data["browserArrowCommandShiftDownCount"] == "\(postCmdLCommandShiftDownCount)" &&
                    data["browserArrowCommandShiftUpCount"] == "\(baselineCommandShiftUpCount + 1)"
            }
        ) else {
            XCTFail("Expected Cmd+Shift+Up after Cmd+L to reach the textarea. data=\(String(describing: loadData()))")
            return
        }

        XCTAssertEqual(
            postCmdLCommandShiftUpSnapshot["browserArrowActiveElementId"],
            textareaId,
            "Expected the clicked textarea to remain focused after Cmd+Shift+arrows"
        )
    }

    func testArrowKeysReachClickedContentEditableAfterCmdL() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_FOCUS_SHORTCUTS"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_INPUT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_ARROW_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_CONTENTEDITABLE_SETUP"] = "1"
        launchAndEnsureForeground(app)

        XCTAssertTrue(
            waitForData(
                keys: [
                    "browserPanelId",
                    "webInputFocusSeeded",
                    "webContentEditableSeeded",
                    "webContentEditableElementId",
                    "webContentEditableClickOffsetX",
                    "webContentEditableClickOffsetY"
                ],
                timeout: 20.0
            ),
            "Expected focused page input setup data before contenteditable regression check. data=\(String(describing: loadData()))"
        )

        guard let setup = loadData() else {
            XCTFail("Missing goto_split setup data")
            return
        }

        guard let browserPanelId = setup["browserPanelId"], !browserPanelId.isEmpty else {
            XCTFail("Missing browserPanelId in setup data")
            return
        }
        XCTAssertEqual(setup["webInputFocusSeeded"], "true", "Expected test page inputs to be seeded before contenteditable regression check")
        XCTAssertEqual(setup["webContentEditableSeeded"], "true", "Expected contenteditable fixture to be seeded before contenteditable regression check")
        guard let editorId = setup["webContentEditableElementId"], !editorId.isEmpty else {
            XCTFail("Missing webContentEditableElementId in setup data")
            return
        }
        guard let editorClickOffsetXRaw = setup["webContentEditableClickOffsetX"],
              let editorClickOffsetYRaw = setup["webContentEditableClickOffsetY"],
              let editorClickOffsetX = Double(editorClickOffsetXRaw),
              let editorClickOffsetY = Double(editorClickOffsetYRaw) else {
            XCTFail(
                "Missing or invalid contenteditable click offsets in setup data. " +
                "webContentEditableClickOffsetX=\(setup["webContentEditableClickOffsetX"] ?? "nil") " +
                "webContentEditableClickOffsetY=\(setup["webContentEditableClickOffsetY"] ?? "nil")"
            )
            return
        }

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5.0), "Expected main window before contenteditable regression check")

        window
            .coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.0))
            .withOffset(CGVector(dx: editorClickOffsetX, dy: editorClickOffsetY))
            .click()

        guard let initialSnapshot = waitForDataSnapshot(
            timeout: 5.0,
            predicate: { data in
                data["browserContentEditableInstalled"] == "true" &&
                    data["browserContentEditableActiveElementId"] == editorId &&
                    data["browserContentEditableDownCount"] == "0" &&
                    data["browserContentEditableUpCount"] == "0" &&
                    data["browserContentEditableCommandShiftDownCount"] == "0" &&
                    data["browserContentEditableCommandShiftUpCount"] == "0"
            }
        ) else {
            XCTFail("Expected contenteditable fixture to be focused before baseline arrows. data=\(String(describing: loadData()))")
            return
        }
        let initialDownCount = Int(initialSnapshot["browserContentEditableDownCount"] ?? "") ?? -1
        let initialUpCount = Int(initialSnapshot["browserContentEditableUpCount"] ?? "") ?? -1
        let initialCommandShiftDownCount = Int(initialSnapshot["browserContentEditableCommandShiftDownCount"] ?? "") ?? -1
        let initialCommandShiftUpCount = Int(initialSnapshot["browserContentEditableCommandShiftUpCount"] ?? "") ?? -1

        simulateShortcut("down", app: app)
        guard let baselineDownSnapshot = waitForDataSnapshot(
            timeout: 5.0,
            predicate: { data in
                data["browserContentEditableActiveElementId"] == editorId &&
                    data["browserContentEditableDownCount"] == "\(initialDownCount + 1)" &&
                    data["browserContentEditableUpCount"] == "\(initialUpCount)"
            }
        ) else {
            XCTFail("Expected baseline Down Arrow to reach the contenteditable fixture. data=\(String(describing: loadData()))")
            return
        }
        let baselineDownCount = Int(baselineDownSnapshot["browserContentEditableDownCount"] ?? "") ?? -1

        simulateShortcut("up", app: app)
        guard waitForDataMatch(
            timeout: 5.0,
            predicate: { data in
                data["browserContentEditableActiveElementId"] == editorId &&
                    data["browserContentEditableDownCount"] == "\(baselineDownCount)" &&
                    data["browserContentEditableUpCount"] == "\(initialUpCount + 1)"
            }
        ) else {
            XCTFail("Expected baseline Up Arrow to reach the contenteditable fixture. data=\(String(describing: loadData()))")
            return
        }
        simulateShortcut("cmdShiftDown", app: app)
        guard let baselineCommandShiftDownSnapshot = waitForDataSnapshot(
            timeout: 5.0,
            predicate: { data in
                data["browserContentEditableActiveElementId"] == editorId &&
                    data["browserContentEditableCommandShiftDownCount"] == "\(initialCommandShiftDownCount + 1)" &&
                    data["browserContentEditableCommandShiftUpCount"] == "\(initialCommandShiftUpCount)"
            }
        ) else {
            XCTFail("Expected baseline Cmd+Shift+Down to reach the contenteditable fixture. data=\(String(describing: loadData()))")
            return
        }
        let baselineCommandShiftDownCount = Int(baselineCommandShiftDownSnapshot["browserContentEditableCommandShiftDownCount"] ?? "") ?? -1

        simulateShortcut("cmdShiftUp", app: app)
        guard let baselineCommandShiftUpSnapshot = waitForDataSnapshot(
            timeout: 5.0,
            predicate: { data in
                data["browserContentEditableActiveElementId"] == editorId &&
                    data["browserContentEditableCommandShiftDownCount"] == "\(baselineCommandShiftDownCount)" &&
                    data["browserContentEditableCommandShiftUpCount"] == "\(initialCommandShiftUpCount + 1)"
            }
        ) else {
            XCTFail("Expected baseline Cmd+Shift+Up to reach the contenteditable fixture. data=\(String(describing: loadData()))")
            return
        }
        let baselineDownCountAfterModifiers = Int(baselineCommandShiftUpSnapshot["browserContentEditableDownCount"] ?? "") ?? -1
        let baselineUpCountAfterModifiers = Int(baselineCommandShiftUpSnapshot["browserContentEditableUpCount"] ?? "") ?? -1
        let baselineCommandShiftUpCount = Int(baselineCommandShiftUpSnapshot["browserContentEditableCommandShiftUpCount"] ?? "") ?? -1

        app.typeKey("l", modifierFlags: [.command])
        XCTAssertTrue(
            waitForDataMatch(timeout: 5.0) { data in
                data["webViewFocusedAfterAddressBarFocus"] == "false" &&
                    data["webViewFocusedAfterAddressBarFocusPanelId"] == browserPanelId &&
                    data["browserArrowFocusedAddressBarPanelId"] == browserPanelId
            },
            "Expected Cmd+L to focus omnibar before the contenteditable click path"
        )

        window
            .coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.0))
            .withOffset(CGVector(dx: editorClickOffsetX, dy: editorClickOffsetY))
            .click()

        guard waitForDataMatch(
            timeout: 5.0,
            predicate: { data in
                data["browserContentEditableActiveElementId"] == editorId
            }
        ) else {
            XCTFail("Expected clicking the page to re-focus the contenteditable fixture after Cmd+L. data=\(String(describing: loadData()))")
            return
        }

        simulateShortcut("down", app: app)
        guard let postCmdLDownSnapshot = waitForDataSnapshot(
            timeout: 5.0,
            predicate: { data in
                data["browserContentEditableActiveElementId"] == editorId &&
                    data["browserContentEditableDownCount"] == "\(baselineDownCountAfterModifiers + 1)" &&
                    data["browserContentEditableUpCount"] == "\(baselineUpCountAfterModifiers)" &&
                    data["browserContentEditableCommandShiftDownCount"] == "\(baselineCommandShiftDownCount)" &&
                    data["browserContentEditableCommandShiftUpCount"] == "\(baselineCommandShiftUpCount)"
            }
        ) else {
            XCTFail("Expected Down Arrow after Cmd+L to reach the contenteditable fixture. data=\(String(describing: loadData()))")
            return
        }
        let postCmdLDownCount = Int(postCmdLDownSnapshot["browserContentEditableDownCount"] ?? "") ?? -1

        simulateShortcut("up", app: app)
        guard let postCmdLUpSnapshot = waitForDataSnapshot(
            timeout: 5.0,
            predicate: { data in
                data["browserContentEditableActiveElementId"] == editorId &&
                    data["browserContentEditableDownCount"] == "\(postCmdLDownCount)" &&
                    data["browserContentEditableUpCount"] == "\(baselineUpCountAfterModifiers + 1)"
            }
        ) else {
            XCTFail("Expected Up Arrow after Cmd+L to reach the contenteditable fixture. data=\(String(describing: loadData()))")
            return
        }
        let postCmdLUpCount = Int(postCmdLUpSnapshot["browserContentEditableUpCount"] ?? "") ?? -1

        simulateShortcut("cmdShiftDown", app: app)
        guard let postCmdLCommandShiftDownSnapshot = waitForDataSnapshot(
            timeout: 5.0,
            predicate: { data in
                data["browserContentEditableActiveElementId"] == editorId &&
                    data["browserContentEditableDownCount"] == "\(postCmdLDownCount + 1)" &&
                    data["browserContentEditableUpCount"] == "\(postCmdLUpCount)" &&
                    data["browserContentEditableCommandShiftDownCount"] == "\(baselineCommandShiftDownCount + 1)" &&
                    data["browserContentEditableCommandShiftUpCount"] == "\(baselineCommandShiftUpCount)"
            }
        ) else {
            XCTFail("Expected Cmd+Shift+Down after Cmd+L to reach the contenteditable fixture. data=\(String(describing: loadData()))")
            return
        }
        let postCmdLDownCountAfterCommandShiftDown = Int(postCmdLCommandShiftDownSnapshot["browserContentEditableDownCount"] ?? "") ?? -1
        let postCmdLCommandShiftDownCount = Int(postCmdLCommandShiftDownSnapshot["browserContentEditableCommandShiftDownCount"] ?? "") ?? -1

        simulateShortcut("cmdShiftUp", app: app)
        guard let postCmdLCommandShiftUpSnapshot = waitForDataSnapshot(
            timeout: 5.0,
            predicate: { data in
                data["browserContentEditableActiveElementId"] == editorId &&
                    data["browserContentEditableDownCount"] == "\(postCmdLDownCountAfterCommandShiftDown)" &&
                    data["browserContentEditableUpCount"] == "\(postCmdLUpCount + 1)" &&
                    data["browserContentEditableCommandShiftDownCount"] == "\(postCmdLCommandShiftDownCount)" &&
                    data["browserContentEditableCommandShiftUpCount"] == "\(baselineCommandShiftUpCount + 1)"
            }
        ) else {
            XCTFail("Expected Cmd+Shift+Up after Cmd+L to reach the contenteditable fixture. data=\(String(describing: loadData()))")
            return
        }

        XCTAssertEqual(
            postCmdLCommandShiftUpSnapshot["browserContentEditableActiveElementId"],
            editorId,
            "Expected the clicked contenteditable fixture to remain focused after Cmd+Shift+arrows"
        )
    }

    func testCmdLOpensBrowserWhenTerminalFocused() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_FOCUS_SHORTCUTS"] = "1"
        launchAndEnsureForeground(app)

        XCTAssertTrue(
            waitForData(keys: ["browserPanelId", "terminalPaneId", "webViewFocused"], timeout: 10.0),
            "Expected goto_split setup data to be written"
        )

        guard let setup = loadData() else {
            XCTFail("Missing goto_split setup data")
            return
        }

        guard let originalBrowserPanelId = setup["browserPanelId"] else {
            XCTFail("Missing browserPanelId in goto_split setup data")
            return
        }

        guard let expectedTerminalPaneId = setup["terminalPaneId"] else {
            XCTFail("Missing terminalPaneId in goto_split setup data")
            return
        }

        // Move focus to the terminal pane first.
        app.typeKey("h", modifierFlags: [.command, .control])
        XCTAssertTrue(
            waitForDataMatch(timeout: 5.0) { data in
                data["lastMoveDirection"] == "left" && data["focusedPaneId"] == expectedTerminalPaneId
            },
            "Expected Cmd+Ctrl+H to move focus to left pane (terminal)"
        )

        // Cmd+L should open a browser in the focused pane, then focus omnibar.
        app.typeKey("l", modifierFlags: [.command])
        XCTAssertTrue(
            waitForDataMatch(timeout: 5.0) { data in
                guard data["webViewFocusedAfterAddressBarFocus"] == "false" else { return false }
                guard let focusedAddressPanelId = data["webViewFocusedAfterAddressBarFocusPanelId"] else { return false }
                return focusedAddressPanelId != originalBrowserPanelId
            },
            "Expected Cmd+L on terminal focus to open a new browser and focus omnibar"
        )
    }

    func testClickingOmnibarFocusesBrowserPane() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_FOCUS_SHORTCUTS"] = "1"
        launchAndEnsureForeground(app)

        XCTAssertTrue(
            waitForData(keys: ["browserPanelId", "terminalPaneId", "webViewFocused"], timeout: 10.0),
            "Expected goto_split setup data to be written"
        )

        guard let setup = loadData() else {
            XCTFail("Missing goto_split setup data")
            return
        }

        guard let expectedBrowserPanelId = setup["browserPanelId"] else {
            XCTFail("Missing browserPanelId in goto_split setup data")
            return
        }

        guard let expectedTerminalPaneId = setup["terminalPaneId"] else {
            XCTFail("Missing terminalPaneId in goto_split setup data")
            return
        }

        // Move focus away from browser to terminal first.
        app.typeKey("h", modifierFlags: [.command, .control])
        XCTAssertTrue(
            waitForDataMatch(timeout: 5.0) { data in
                data["lastMoveDirection"] == "left" && data["focusedPaneId"] == expectedTerminalPaneId
            },
            "Expected Cmd+Ctrl+H to move focus to left pane (terminal)"
        )

        let omnibar = app.textFields["BrowserOmnibarTextField"].firstMatch
        XCTAssertTrue(omnibar.waitForExistence(timeout: 6.0), "Expected browser omnibar text field")
        omnibar.click()

        // Cmd+L behavior is context-aware:
        // - If terminal is focused: opens a new browser and focuses that new omnibar.
        // - If browser is focused: focuses current browser omnibar.
        // After clicking the omnibar, Cmd+L should stay on the existing browser panel.
        app.typeKey("l", modifierFlags: [.command])
        XCTAssertTrue(
            waitForDataMatch(timeout: 5.0) { data in
                guard data["webViewFocusedAfterAddressBarFocus"] == "false" else { return false }
                return data["webViewFocusedAfterAddressBarFocusPanelId"] == expectedBrowserPanelId
            },
            "Expected omnibar click to focus browser panel so Cmd+L stays on that browser"
        )
    }

    func testClickingBrowserDismissesCommandPaletteAndKeepsBrowserFocus() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_FOCUS_SHORTCUTS"] = "1"
        launchAndEnsureForeground(app)

        XCTAssertTrue(
            waitForData(keys: ["browserPanelId", "terminalPaneId", "webViewFocused"], timeout: 10.0),
            "Expected goto_split setup data to be written"
        )

        guard let setup = loadData() else {
            XCTFail("Missing goto_split setup data")
            return
        }

        guard let expectedBrowserPanelId = setup["browserPanelId"] else {
            XCTFail("Missing browserPanelId in goto_split setup data")
            return
        }

        guard let expectedTerminalPaneId = setup["terminalPaneId"] else {
            XCTFail("Missing terminalPaneId in goto_split setup data")
            return
        }

        // Move focus away from browser to terminal first so Cmd+R opens the rename overlay.
        app.typeKey("h", modifierFlags: [.command, .control])
        XCTAssertTrue(
            waitForDataMatch(timeout: 5.0) { data in
                data["lastMoveDirection"] == "left" && data["focusedPaneId"] == expectedTerminalPaneId
            },
            "Expected Cmd+Ctrl+H to move focus to left pane (terminal)"
        )

        let renameField = app.textFields["CommandPaletteRenameField"].firstMatch
        app.typeKey("r", modifierFlags: [.command])
        XCTAssertTrue(
            renameField.waitForExistence(timeout: 5.0),
            "Expected Cmd+R to open the rename command palette while terminal is focused"
        )

        let browserPane = app.otherElements["BrowserPanelContent.\(expectedBrowserPanelId)"].firstMatch
        XCTAssertTrue(browserPane.waitForExistence(timeout: 5.0), "Expected browser pane content for click target")
        browserPane.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(
            waitForNonExistence(renameField, timeout: 5.0),
            "Expected clicking the browser pane to dismiss the command palette"
        )

        // Cmd+L behavior is context-aware:
        // - If terminal is still focused: opens a new browser in that pane.
        // - If the original browser took focus: focuses that existing browser's omnibar.
        app.typeKey("l", modifierFlags: [.command])
        XCTAssertTrue(
            waitForDataMatch(timeout: 5.0) { data in
                guard data["webViewFocusedAfterAddressBarFocus"] == "false" else { return false }
                return data["webViewFocusedAfterAddressBarFocusPanelId"] == expectedBrowserPanelId
            },
            "Expected clicking browser content to dismiss the palette and keep focus on the existing browser pane"
        )
    }

    func testCmdDSplitsRightWhenWebViewFocused() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        launchAndEnsureForeground(app)

        XCTAssertTrue(
            waitForData(keys: ["webViewFocused", "initialPaneCount"], timeout: 10.0),
            "Expected goto_split setup data to be written"
        )

        guard let setup = loadData() else {
            XCTFail("Missing goto_split setup data")
            return
        }

        XCTAssertEqual(setup["webViewFocused"], "true", "Expected WKWebView to be first responder for this test")
        let initialPaneCount = Int(setup["initialPaneCount"] ?? "") ?? 0
        XCTAssertGreaterThanOrEqual(initialPaneCount, 2, "Expected at least two panes before split. data=\(setup)")

        app.typeKey("d", modifierFlags: [.command])

        XCTAssertTrue(
            waitForDataMatch(timeout: 5.0) { data in
                guard data["lastSplitDirection"] == "right" else { return false }
                guard let paneCountAfter = Int(data["paneCountAfterSplit"] ?? "") else { return false }
                return paneCountAfter == initialPaneCount + 1
            },
            "Expected Cmd+D to split right while WKWebView is first responder"
        )
    }

    func testCmdShiftDSplitsDownWhenWebViewFocused() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        launchAndEnsureForeground(app)

        XCTAssertTrue(
            waitForData(keys: ["webViewFocused", "initialPaneCount"], timeout: 10.0),
            "Expected goto_split setup data to be written"
        )

        guard let setup = loadData() else {
            XCTFail("Missing goto_split setup data")
            return
        }

        XCTAssertEqual(setup["webViewFocused"], "true", "Expected WKWebView to be first responder for this test")
        let initialPaneCount = Int(setup["initialPaneCount"] ?? "") ?? 0
        XCTAssertGreaterThanOrEqual(initialPaneCount, 2, "Expected at least two panes before split. data=\(setup)")

        app.typeKey("d", modifierFlags: [.command, .shift])

        XCTAssertTrue(
            waitForDataMatch(timeout: 5.0) { data in
                guard data["lastSplitDirection"] == "down" else { return false }
                guard let paneCountAfter = Int(data["paneCountAfterSplit"] ?? "") else { return false }
                return paneCountAfter == initialPaneCount + 1
            },
            "Expected Cmd+Shift+D to split down while WKWebView is first responder"
        )
    }

    func testCmdShiftEnterKeepsBrowserOmnibarHittableAcrossZoomRoundTripWhenWebViewFocused() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        launchAndEnsureForeground(app)

        XCTAssertTrue(
            waitForData(keys: ["browserPanelId", "webViewFocused"], timeout: 10.0),
            "Expected goto_split setup data to be written"
        )

        guard let setup = loadData() else {
            XCTFail("Missing goto_split setup data")
            return
        }

        guard let browserPanelId = setup["browserPanelId"] else {
            XCTFail("Missing browserPanelId in goto_split setup data")
            return
        }

        XCTAssertEqual(setup["webViewFocused"], "true", "Expected WKWebView to be first responder for this test")

        let omnibar = app.textFields["BrowserOmnibarTextField"].firstMatch
        let pill = app.descendants(matching: .any).matching(identifier: "BrowserOmnibarPill").firstMatch
        XCTAssertTrue(omnibar.waitForExistence(timeout: 6.0), "Expected browser omnibar text field before zoom")
        XCTAssertTrue(pill.waitForExistence(timeout: 6.0), "Expected browser omnibar pill before zoom")

        // Reproduce the loaded-page state from the bug report before toggling zoom.
        app.typeKey("l", modifierFlags: [.command])
        XCTAssertTrue(waitForElementToBecomeHittable(pill, timeout: 6.0), "Expected browser omnibar pill before navigation")
        pill.click()
        app.typeKey("a", modifierFlags: [.command])
        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        app.typeText(zoomRoundTripPageURL)
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

        XCTAssertTrue(
            waitForOmnibarToContain(omnibar, value: "data:text/html", timeout: 8.0),
            "Expected browser to finish navigating to the regression page before zoom. value=\(String(describing: omnibar.value))"
        )

        let browserPane = app.otherElements["BrowserPanelContent.\(browserPanelId)"].firstMatch
        XCTAssertTrue(browserPane.waitForExistence(timeout: 6.0), "Expected browser pane content before zoom")
        browserPane.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [.command, .shift])
        XCTAssertTrue(
            waitForDataMatch(timeout: 8.0) { data in
                data["splitZoomedAfterToggle"] == "true" &&
                    data["otherTerminalHostHiddenAfterToggle"] == "true" &&
                    data["otherTerminalVisibleFlagAfterToggle"] == "false"
            },
            "Expected Cmd+Shift+Enter zoom-in to hide the non-browser terminal portal. data=\(loadData() ?? [:])"
        )
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [.command, .shift])
        XCTAssertTrue(
            waitForDataMatch(timeout: 8.0) { data in
                data["splitZoomedAfterToggle"] == "false" &&
                    data["otherTerminalHostHiddenAfterToggle"] == "false" &&
                    data["otherTerminalVisibleFlagAfterToggle"] == "true"
            },
            "Expected Cmd+Shift+Enter zoom-out to restore the non-browser terminal portal. data=\(loadData() ?? [:])"
        )

        XCTAssertTrue(omnibar.waitForExistence(timeout: 6.0), "Expected browser omnibar text field after Cmd+Shift+Enter zoom round-trip")
        XCTAssertTrue(pill.waitForExistence(timeout: 6.0), "Expected browser omnibar pill after Cmd+Shift+Enter zoom round-trip")
        XCTAssertTrue(
            waitForElementToBecomeHittable(pill, timeout: 6.0),
            "Expected browser omnibar to stay hittable after Cmd+Shift+Enter zoom round-trip"
        )
        let page = app.webViews.firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 6.0), "Expected browser web area after Cmd+Shift+Enter")
        XCTAssertLessThanOrEqual(
            pill.frame.maxY,
            page.frame.minY + 12,
            "Expected browser omnibar to remain above the web content after Cmd+Shift+Enter. pill=\(pill.frame) page=\(page.frame)"
        )

        pill.click()
        app.typeKey("a", modifierFlags: [.command])
        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        app.typeText("issue1144")

        XCTAssertTrue(
            waitForOmnibarToContain(omnibar, value: "issue1144", timeout: 4.0),
            "Expected browser omnibar to stay editable after Cmd+Shift+Enter. value=\(String(describing: omnibar.value))"
        )
    }

    func testCmdShiftEnterHidesBrowserPortalWhenTerminalPaneZooms() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_FOCUS_SHORTCUTS"] = "1"
        launchAndEnsureForeground(app)

        XCTAssertTrue(
            waitForData(keys: ["terminalPaneId", "browserPanelId", "webViewFocused"], timeout: 10.0),
            "Expected goto_split setup data to be written"
        )

        guard let setup = loadData() else {
            XCTFail("Missing goto_split setup data")
            return
        }

        guard let expectedTerminalPaneId = setup["terminalPaneId"] else {
            XCTFail("Missing terminalPaneId in goto_split setup data")
            return
        }

        app.typeKey("h", modifierFlags: [.command, .control])

        XCTAssertTrue(
            waitForDataMatch(timeout: 5.0) { data in
                data["focusedPaneId"] == expectedTerminalPaneId && data["focusedPanelKind"] == "terminal"
            },
            "Expected Cmd+Ctrl+H to focus the terminal pane before zoom. data=\(loadData() ?? [:])"
        )

        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [.command, .shift])
        XCTAssertTrue(
            waitForDataMatch(timeout: 8.0) { data in
                data["splitZoomedAfterToggle"] == "true" &&
                    data["browserContainerHiddenAfterToggle"] == "true" &&
                    data["browserVisibleFlagAfterToggle"] == "false"
            },
            "Expected Cmd+Shift+Enter zoom-in on the terminal pane to hide the browser portal. data=\(loadData() ?? [:])"
        )

        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [.command, .shift])
        XCTAssertTrue(
            waitForDataMatch(timeout: 8.0) { data in
                data["splitZoomedAfterToggle"] == "false" &&
                    data["browserContainerHiddenAfterToggle"] == "false" &&
                    data["browserVisibleFlagAfterToggle"] == "true"
            },
            "Expected Cmd+Shift+Enter zoom-out from the terminal pane to restore the browser portal. data=\(loadData() ?? [:])"
        )
    }

    func testCmdDSplitsRightWhenOmnibarFocused() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        launchAndEnsureForeground(app)

        XCTAssertTrue(
            waitForData(keys: ["webViewFocused", "initialPaneCount"], timeout: 10.0),
            "Expected goto_split setup data to be written"
        )

        guard let setup = loadData() else {
            XCTFail("Missing goto_split setup data")
            return
        }

        let initialPaneCount = Int(setup["initialPaneCount"] ?? "") ?? 0
        XCTAssertGreaterThanOrEqual(initialPaneCount, 2, "Expected at least two panes before split. data=\(setup)")

        // Focus browser omnibar (WebKit no longer first responder).
        app.typeKey("l", modifierFlags: [.command])
        XCTAssertTrue(
            waitForDataMatch(timeout: 5.0) { data in
                data["webViewFocusedAfterAddressBarFocus"] == "false"
            },
            "Expected Cmd+L to focus omnibar before split"
        )

        app.typeKey("d", modifierFlags: [.command])

        XCTAssertTrue(
            waitForDataMatch(timeout: 5.0) { data in
                guard data["lastSplitDirection"] == "right" else { return false }
                guard let paneCountAfter = Int(data["paneCountAfterSplit"] ?? "") else { return false }
                return paneCountAfter == initialPaneCount + 1
            },
            "Expected Cmd+D to split right while omnibar is first responder"
        )
    }

    func testCmdShiftDSplitsDownWhenOmnibarFocused() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        launchAndEnsureForeground(app)

        XCTAssertTrue(
            waitForData(keys: ["webViewFocused", "initialPaneCount"], timeout: 10.0),
            "Expected goto_split setup data to be written"
        )

        guard let setup = loadData() else {
            XCTFail("Missing goto_split setup data")
            return
        }

        let initialPaneCount = Int(setup["initialPaneCount"] ?? "") ?? 0
        XCTAssertGreaterThanOrEqual(initialPaneCount, 2, "Expected at least two panes before split. data=\(setup)")

        // Focus browser omnibar (WebKit no longer first responder).
        app.typeKey("l", modifierFlags: [.command])
        XCTAssertTrue(
            waitForDataMatch(timeout: 5.0) { data in
                data["webViewFocusedAfterAddressBarFocus"] == "false"
            },
            "Expected Cmd+L to focus omnibar before split"
        )

        app.typeKey("d", modifierFlags: [.command, .shift])

        XCTAssertTrue(
            waitForDataMatch(timeout: 5.0) { data in
                guard data["lastSplitDirection"] == "down" else { return false }
                guard let paneCountAfter = Int(data["paneCountAfterSplit"] ?? "") else { return false }
                return paneCountAfter == initialPaneCount + 1
            },
            "Expected Cmd+Shift+D to split down while omnibar is first responder"
        )
    }

    func testCmdOptionPaneSwitchPreservesFindFieldFocus() {
        runFindFocusPersistenceScenario(route: .cmdOptionArrows, useAutofocusRacePage: false)
    }

    func testCmdCtrlPaneSwitchPreservesFindFieldFocus() {
        runFindFocusPersistenceScenario(route: .cmdCtrlLetters, useAutofocusRacePage: false)
    }

    func testCmdOptionPaneSwitchPreservesFindFieldFocusDuringPageAutofocusRace() {
        runFindFocusPersistenceScenario(route: .cmdOptionArrows, useAutofocusRacePage: true)
    }

    func testCmdFFocusesBrowserFindFieldAfterCmdDCmdLNavigation() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_RECORD_ONLY"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        launchAndEnsureForeground(app)

        let window = app.windows.firstMatch
        // On some CI runners the app accepts key events before XCUI exposes the window tree.
        _ = window.waitForExistence(timeout: 2.0)

        app.typeKey("d", modifierFlags: [.command])
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                guard data["lastSplitDirection"] == "right" else { return false }
                guard let paneCountAfterSplit = Int(data["paneCountAfterSplit"] ?? "") else { return false }
                return paneCountAfterSplit >= 2
            },
            "Expected Cmd+D to create a split before opening the browser. data=\(String(describing: loadData()))"
        )

        app.typeKey("l", modifierFlags: [.command])

        let omnibar = app.textFields["BrowserOmnibarTextField"].firstMatch
        XCTAssertTrue(omnibar.waitForExistence(timeout: 8.0), "Expected browser omnibar after Cmd+L")

        app.typeKey("a", modifierFlags: [.command])
        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        app.typeText("example.com")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

        XCTAssertTrue(
            waitForOmnibarToContainExampleDomain(omnibar, timeout: 8.0),
            "Expected browser navigation to example domain before opening find. value=\(String(describing: omnibar.value))"
        )

        app.typeKey("f", modifierFlags: [.command])

        let findField = app.textFields["BrowserFindSearchTextField"].firstMatch
        XCTAssertTrue(findField.waitForExistence(timeout: 6.0), "Expected browser find field after Cmd+F")

        let omnibarValueBeforeFindTyping = (omnibar.value as? String) ?? ""
        app.typeText("needle")

        XCTAssertTrue(
            waitForCondition(timeout: 4.0) {
                ((findField.value as? String) ?? "") == "needle"
            },
            "Expected Cmd+F to focus browser find after Cmd+D, Cmd+L, and navigation. " +
                "findValue=\(String(describing: findField.value)) omnibarValue=\(String(describing: omnibar.value))"
        )
        let omnibarValueAfterFindTyping = (omnibar.value as? String) ?? ""
        XCTAssertFalse(
            omnibarValueAfterFindTyping.contains("needle"),
            "Expected typing after Cmd+F to stay out of the omnibar. " +
                "omnibarValueBefore=\(omnibarValueBeforeFindTyping) " +
                "omnibarValueAfter=\(String(describing: omnibar.value)) " +
                "findValue=\(String(describing: findField.value))"
        )
    }

    private enum FindFocusRoute {
        case cmdOptionArrows
        case cmdCtrlLetters
    }

    private func runFindFocusPersistenceScenario(route: FindFocusRoute, useAutofocusRacePage: Bool) {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_RECORD_ONLY"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        if route == .cmdCtrlLetters {
            app.launchEnvironment["CMUX_UI_TEST_FOCUS_SHORTCUTS"] = "1"
        }
        launchAndEnsureForeground(app)

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10.0), "Expected main window to exist")

        // Repro setup: split, open browser split, navigate to example.com.
        app.typeKey("d", modifierFlags: [.command])
        focusRightPaneForFindScenario(app, route: route)

        app.typeKey("l", modifierFlags: [.command, .shift])
        let omnibar = app.textFields["BrowserOmnibarTextField"].firstMatch
        XCTAssertTrue(omnibar.waitForExistence(timeout: 8.0), "Expected browser omnibar after Cmd+Shift+L")

        app.typeKey("a", modifierFlags: [.command])
        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        if useAutofocusRacePage {
            app.typeText(autofocusRacePageURL)
        } else {
            app.typeText("example.com")
        }
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

        if useAutofocusRacePage {
            XCTAssertTrue(
                waitForOmnibarToContain(omnibar, value: "data:text/html", timeout: 8.0),
                "Expected browser navigation to data URL before running find flow. value=\(String(describing: omnibar.value))"
            )
        } else {
            XCTAssertTrue(
                waitForOmnibarToContainExampleDomain(omnibar, timeout: 8.0),
                "Expected browser navigation to example domain before running find flow. value=\(String(describing: omnibar.value))"
            )
        }

        // Left terminal: Cmd+F then type "la".
        focusLeftPaneForFindScenario(app, route: route)
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                data["focusedPanelKind"] == "terminal"
            },
            "Expected left terminal pane to be focused before terminal find. data=\(String(describing: loadData()))"
        )
        app.typeKey("f", modifierFlags: [.command])
        app.typeText("la")

        // Right browser: Cmd+F then type "am".
        focusRightPaneForFindScenario(app, route: route)
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                data["lastMoveDirection"] == "right"
                    && data["focusedPanelKind"] == "browser"
                    && data["terminalFindNeedle"] == "la"
            },
            "Expected terminal find query to persist as 'la' after focusing browser pane. data=\(String(describing: loadData()))"
        )
        app.typeKey("f", modifierFlags: [.command])
        app.typeText("am")

        if useAutofocusRacePage {
            XCTAssertTrue(
                waitForOmnibarToContain(omnibar, value: "#focused", timeout: 5.0),
                "Expected autofocus race page to signal focus handoff via URL hash. value=\(String(describing: omnibar.value))"
            )
        }

        // Left terminal: typing should keep going into terminal find field.
        focusLeftPaneForFindScenario(app, route: route)
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                data["lastMoveDirection"] == "left"
                    && data["focusedPanelKind"] == "terminal"
                    && data["browserFindNeedle"] == "am"
            },
            "Expected browser find query to persist as 'am' after returning left. data=\(String(describing: loadData()))"
        )
        app.typeText("foo")

        // Right browser: typing should keep going into browser find field.
        focusRightPaneForFindScenario(app, route: route)
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                data["lastMoveDirection"] == "right"
                    && data["focusedPanelKind"] == "browser"
                    && data["terminalFindNeedle"] == "lafoo"
            },
            "Expected terminal find query to stay focused and become 'lafoo'. data=\(String(describing: loadData()))"
        )
        app.typeText("do")

        // Move left once more so the recorder captures browser find state after typing.
        focusLeftPaneForFindScenario(app, route: route)
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                data["lastMoveDirection"] == "left"
                    && data["focusedPanelKind"] == "terminal"
                    && data["browserFindNeedle"] == "amdo"
            },
            "Expected browser find query to stay focused and become 'amdo'. data=\(String(describing: loadData()))"
        )
    }

    private func focusLeftPaneForFindScenario(_ app: XCUIApplication, route: FindFocusRoute) {
        switch route {
        case .cmdOptionArrows:
            app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [.command, .option])
        case .cmdCtrlLetters:
            app.typeKey("h", modifierFlags: [.command, .control])
        }
    }

    private func focusRightPaneForFindScenario(_ app: XCUIApplication, route: FindFocusRoute) {
        switch route {
        case .cmdOptionArrows:
            app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [.command, .option])
        case .cmdCtrlLetters:
            app.typeKey("l", modifierFlags: [.command, .control])
        }
    }

    private func waitForOmnibarToContainExampleDomain(_ omnibar: XCUIElement, timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            let value = (omnibar.value as? String) ?? ""
            return value.contains("example.com") || value.contains("example.org")
        }
    }

    private func waitForOmnibarToContain(_ omnibar: XCUIElement, value expectedSubstring: String, timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            let value = (omnibar.value as? String) ?? ""
            return value.contains(expectedSubstring)
        }
    }

    private func waitForElementToBecomeHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            element.exists && element.isHittable
        }
    }

    private var autofocusRacePageURL: String {
        "data:text/html,%3Cinput%20id%3D%22q%22%3E%3Cscript%3EsetTimeout%28function%28%29%7Bdocument.getElementById%28%22q%22%29.focus%28%29%3Blocation.hash%3D%22focused%22%3B%7D%2C700%29%3B%3C%2Fscript%3E"
    }

    private var zoomRoundTripPageURL: String {
        "data:text/html,%3Ctitle%3EIssue%201144%3C/title%3E%3Cbody%20style%3D%22margin:0;background:%231d1f24;color:white;font-family:system-ui;height:2200px%22%3E%3Cmain%20style%3D%22padding:32px%22%3E%3Ch1%3EIssue%201144%20Regression%20Page%3C/h1%3E%3Cp%3EZoom%20should%20not%20leave%20stale%20split%20chrome%20above%20the%20browser%20omnibar.%3C/p%3E%3C/main%3E%3C/body%3E"
    }

    private func launchAndEnsureForeground(_ app: XCUIApplication, timeout: TimeInterval = 12.0) {
        prepareLaunchEnvironment(app)

        // On headless CI runners (no GUI session), XCUIApplication.launch()
        // can fail activation even though the app is usable through
        // accessibility. Keep the launch diagnostics/socket setup above, then
        // tolerate a background-only launch before failing hard.
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: options) {
            app.launch()
        }

        if ensureForegroundAfterLaunch(app, timeout: timeout) {
            return
        }

        if app.state == .runningBackground {
            return
        }

        XCTFail("App failed to start. state=\(app.state.rawValue)")
    }

    private func prepareLaunchEnvironment(_ app: XCUIApplication) {
        if app.launchEnvironment["CMUX_UI_TEST_MODE"] == nil {
            app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        }
        if app.launchEnvironment["CMUX_TAG"] == nil {
            app.launchEnvironment["CMUX_TAG"] = launchTag
        }
        if app.launchEnvironment["CMUX_UI_TEST_DIAGNOSTICS_PATH"] == nil {
            app.launchEnvironment["CMUX_UI_TEST_DIAGNOSTICS_PATH"] = launchDiagnosticsPath
        }
        if app.launchEnvironment["CMUX_SOCKET_PATH"] != nil,
           app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] == nil {
            app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        }
        if app.launchEnvironment["CMUX_SOCKET_PATH"] != nil {
            if app.launchEnvironment["CMUX_ALLOW_SOCKET_OVERRIDE"] == nil {
                app.launchEnvironment["CMUX_ALLOW_SOCKET_OVERRIDE"] = "1"
            }
            if !app.launchArguments.contains("-socketControlMode") {
                app.launchArguments += ["-socketControlMode", "allowAll"]
            }
            if app.launchEnvironment["CMUX_SOCKET_ENABLE"] == nil {
                app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
            }
            if app.launchEnvironment["CMUX_SOCKET_MODE"] == nil {
                app.launchEnvironment["CMUX_SOCKET_MODE"] = "allowAll"
            }
        }
    }

    private func ensureForegroundAfterLaunch(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        if app.wait(for: .runningForeground, timeout: timeout) {
            return true
        }

        let activationDeadline = Date().addingTimeInterval(12.0)
        while app.state == .runningBackground && Date() < activationDeadline {
            app.activate()
            if app.wait(for: .runningForeground, timeout: 2.0) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        return app.state == .runningForeground
    }

    private func waitForData(keys: [String], timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            guard let data = self.loadData() else { return false }
            return keys.allSatisfy { data[$0] != nil }
        }
    }

    private func waitForDataMatch(timeout: TimeInterval, predicate: @escaping ([String: String]) -> Bool) -> Bool {
        waitForCondition(timeout: timeout) {
            guard let data = self.loadData() else { return false }
            return predicate(data)
        }
    }

    private func waitForDataSnapshot(
        timeout: TimeInterval,
        predicate: @escaping ([String: String]) -> Bool
    ) -> [String: String]? {
        var matched: [String: String]?
        let didMatch = waitForCondition(timeout: timeout) {
            guard let data = self.loadData(), predicate(data) else { return false }
            matched = data
            return true
        }
        return didMatch ? matched : nil
    }

    private func browserArrowCountersRemainUnchanged(
        down: Int,
        up: Int,
        commandShiftDown: Int,
        commandShiftUp: Int,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = loadData() {
                if data["browserArrowDownCount"] != "\(down)" ||
                    data["browserArrowUpCount"] != "\(up)" ||
                    data["browserArrowCommandShiftDownCount"] != "\(commandShiftDown)" ||
                    data["browserArrowCommandShiftUpCount"] != "\(commandShiftUp)" {
                    return false
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return true
    }

    private func waitForNonExistence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func simulateShortcut(_ combo: String, app: XCUIApplication) {
        switch combo {
        case "down":
            app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
        case "up":
            app.typeKey(XCUIKeyboardKey.upArrow.rawValue, modifierFlags: [])
        case "cmdShiftDown":
            app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [.command, .shift])
        case "cmdShiftUp":
            app.typeKey(XCUIKeyboardKey.upArrow.rawValue, modifierFlags: [.command, .shift])
        default:
            XCTFail("Unsupported test shortcut combo \(combo)")
        }
    }

    private func loadData() -> [String: String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: dataPath)) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
    }

    private func waitForCondition(timeout: TimeInterval, predicate: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in predicate() },
            object: nil
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

}
