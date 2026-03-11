import XCTest
import Foundation

final class BrowserPaneNavigationKeybindUITests: XCTestCase {
    private var dataPath = ""
    private var socketPath = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        dataPath = "/tmp/cmux-ui-test-goto-split-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: dataPath)
        socketPath = "/tmp/cmux-ui-test-socket-\(UUID().uuidString).sock"
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    func testCmdCtrlHMovesLeftWhenWebViewFocused() {
        runCmdCtrlHMovesLeftWhenWebViewFocused(useGraphV1: false)
    }

    func testGraphV1CmdCtrlHMovesLeftWhenWebViewFocused() {
        runCmdCtrlHMovesLeftWhenWebViewFocused(useGraphV1: true)
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
        let pill = app.descendants(matching: .any).matching(identifier: "BrowserOmnibarPill").firstMatch
        XCTAssertTrue(omnibar.waitForExistence(timeout: 6.0), "Expected browser omnibar text field")
        XCTAssertTrue(pill.waitForExistence(timeout: 6.0), "Expected browser omnibar pill")
        XCTAssertTrue(
            focusBrowserOmnibar(omnibar: omnibar, pill: pill, timeout: 6.0),
            "Expected browser omnibar surface to accept click focus. pill=\(pill.frame) omnibar=\(omnibar.frame)"
        )
        XCTAssertTrue(
            waitForDataMatch(timeout: 5.0) { data in
                data["focusedPanelId"] == expectedBrowserPanelId &&
                    data["focusedPanelKind"] == "browser"
            },
            "Expected omnibar click to focus the browser pane before Cmd+L. data=\(loadData() ?? [:])"
        )

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

        clickBrowserContent(
            app,
            panelId: expectedBrowserPanelId,
            timeout: 5.0,
            failureMessage: "Expected browser pane content for click target"
        )
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
        runCmdDSplitsRightWhenWebViewFocused(useGraphV1: false)
    }

    func testGraphV1CmdDSplitsRightWhenWebViewFocused() {
        runCmdDSplitsRightWhenWebViewFocused(useGraphV1: true)
    }

    func testCmdShiftDSplitsDownWhenWebViewFocused() {
        runCmdShiftDSplitsDownWhenWebViewFocused(useGraphV1: false)
    }

    func testGraphV1CmdShiftDSplitsDownWhenWebViewFocused() {
        runCmdShiftDSplitsDownWhenWebViewFocused(useGraphV1: true)
    }

    func testCmdShiftEnterKeepsBrowserOmnibarHittableAcrossZoomRoundTripWhenWebViewFocused() {
        runCmdShiftEnterKeepsBrowserOmnibarHittableAcrossZoomRoundTripWhenWebViewFocused(useGraphV1: false)
    }

    func testGraphV1CmdShiftEnterKeepsBrowserOmnibarHittableAcrossZoomRoundTripWhenWebViewFocused() {
        runCmdShiftEnterKeepsBrowserOmnibarHittableAcrossZoomRoundTripWhenWebViewFocused(useGraphV1: true)
    }

    func testCmdShiftEnterHidesBrowserPortalWhenTerminalPaneZooms() {
        runCmdShiftEnterHidesBrowserPortalWhenTerminalPaneZooms(useGraphV1: false)
    }

    func testGraphV1CmdShiftEnterHidesBrowserPortalWhenTerminalPaneZooms() {
        runCmdShiftEnterHidesBrowserPortalWhenTerminalPaneZooms(useGraphV1: true)
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
            app.typeText(makeAutofocusRacePageURL())
        } else {
            app.typeText("example.com")
        }
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

        if useAutofocusRacePage {
            XCTAssertTrue(
                waitForOmnibarToContain(omnibar, value: "cmux-ui-test-autofocus-race-", timeout: 8.0),
                "Expected browser navigation to autofocus race fixture before running find flow. value=\(String(describing: omnibar.value))"
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
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let value = (omnibar.value as? String) ?? ""
            if value.contains("example.com") || value.contains("example.org") {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let value = (omnibar.value as? String) ?? ""
        return value.contains("example.com") || value.contains("example.org")
    }

    private func waitForOmnibarToContain(_ omnibar: XCUIElement, value expectedSubstring: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let value = (omnibar.value as? String) ?? ""
            if value.contains(expectedSubstring) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let value = (omnibar.value as? String) ?? ""
        return value.contains(expectedSubstring)
    }

    private func waitForElementToBecomeHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isHittable {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return element.exists && element.isHittable
    }

    private func focusBrowserOmnibar(
        omnibar: XCUIElement,
        pill: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pill.exists && pill.frame.width > 1 && pill.frame.height > 1 {
                pill.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
                return true
            }
            if omnibar.exists && omnibar.frame.width > 1 && omnibar.frame.height > 1 {
                omnibar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        if pill.exists && pill.frame.width > 1 && pill.frame.height > 1 {
            pill.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            return true
        }
        if omnibar.exists && omnibar.frame.width > 1 && omnibar.frame.height > 1 {
            omnibar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            return true
        }

        return false
    }

    private func makeAutofocusRacePageURL() -> String {
        writeTemporaryHTMLFixture(
            prefix: "autofocus-race",
            html: """
            <!doctype html>
            <html>
            <body>
            <input id="q">
            <script>
            setTimeout(function () {
              document.getElementById("q").focus();
              location.hash = "focused";
            }, 700);
            </script>
            </body>
            </html>
            """
        )
    }

    private func makeZoomRoundTripPageURL() -> String {
        writeTemporaryHTMLFixture(
            prefix: "zoom-round-trip",
            html: """
            <!doctype html>
            <html>
            <head>
            <title>Issue 1144</title>
            </head>
            <body style="margin:0;background:#1d1f24;color:white;font-family:system-ui;height:2200px">
            <main style="padding:32px">
            <h1>Issue 1144 Regression Page</h1>
            <p>Zoom should not leave stale split chrome above the browser omnibar.</p>
            </main>
            </body>
            </html>
            """
        )
    }

    private func writeTemporaryHTMLFixture(prefix: String, html: String) -> String {
        let directoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("cmux-ui-test-\(prefix)-\(UUID().uuidString).html")
        do {
            try html.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            XCTFail("Failed to write temporary HTML fixture: \(error)")
            return "about:blank"
        }

        addTeardownBlock {
            try? FileManager.default.removeItem(at: fileURL)
        }
        return fileURL.absoluteString
    }

    private func configuredApp(useGraphV1: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        if useGraphV1 {
            app.launchEnvironment["CMUX_WORKSPACE_ENGINE"] = "graph-v1"
        }
        return app
    }

    private func runCmdCtrlHMovesLeftWhenWebViewFocused(useGraphV1: Bool) {
        let app = configuredApp(useGraphV1: useGraphV1)
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

        app.typeKey("h", modifierFlags: [.command, .control])

        XCTAssertTrue(
            waitForDataMatch(timeout: 5.0) { data in
                data["lastMoveDirection"] == "left" && data["focusedPaneId"] == expectedTerminalPaneId
            },
            "Expected Cmd+Ctrl+H to move focus to left pane (terminal)"
        )
    }

    private func runCmdDSplitsRightWhenWebViewFocused(useGraphV1: Bool) {
        let app = configuredApp(useGraphV1: useGraphV1)
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

    private func runCmdShiftDSplitsDownWhenWebViewFocused(useGraphV1: Bool) {
        let app = configuredApp(useGraphV1: useGraphV1)
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

    private func runCmdShiftEnterKeepsBrowserOmnibarHittableAcrossZoomRoundTripWhenWebViewFocused(useGraphV1: Bool) {
        let app = configuredApp(useGraphV1: useGraphV1)
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

        app.typeKey("l", modifierFlags: [.command])
        XCTAssertTrue(
            waitForDataMatch(timeout: 5.0) { data in
                data["webViewFocusedAfterAddressBarFocus"] == "false" &&
                    data["webViewFocusedAfterAddressBarFocusPanelId"] == browserPanelId
            },
            "Expected Cmd+L to focus the browser omnibar before navigation. data=\(loadData() ?? [:])"
        )
        app.typeKey("a", modifierFlags: [.command])
        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        app.typeText(makeZoomRoundTripPageURL())
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

        XCTAssertTrue(
            waitForOmnibarToContain(omnibar, value: "cmux-ui-test-zoom-round-trip-", timeout: 8.0),
            "Expected browser to finish navigating to the regression page before zoom. value=\(String(describing: omnibar.value))"
        )

        clickBrowserContent(
            app,
            panelId: browserPanelId,
            timeout: 6.0,
            failureMessage: "Expected browser pane content before zoom"
        )

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
        let page = app.webViews.firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 6.0), "Expected browser web area after Cmd+Shift+Enter")
        XCTAssertLessThanOrEqual(
            pill.frame.maxY,
            page.frame.minY + 12,
            "Expected browser omnibar to remain above the web content after Cmd+Shift+Enter. pill=\(pill.frame) page=\(page.frame)"
        )

        XCTAssertTrue(
            focusBrowserOmnibar(omnibar: omnibar, pill: pill, timeout: 6.0),
            "Expected browser omnibar to stay focusable after Cmd+Shift+Enter. data=\(loadData() ?? [:]) pill=\(pill.frame) omnibar=\(omnibar.frame)"
        )
        app.typeKey("a", modifierFlags: [.command])
        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        app.typeText("issue1144")

        XCTAssertTrue(
            waitForOmnibarToContain(omnibar, value: "issue1144", timeout: 4.0),
            "Expected browser omnibar to stay editable after Cmd+Shift+Enter. value=\(String(describing: omnibar.value))"
        )
    }

    private func runCmdShiftEnterHidesBrowserPortalWhenTerminalPaneZooms(useGraphV1: Bool) {
        let app = configuredApp(useGraphV1: useGraphV1)
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

    private func clickBrowserContent(
        _ app: XCUIApplication,
        panelId: String,
        timeout: TimeInterval,
        failureMessage: String
    ) {
        let browserPane = app.otherElements["BrowserPanelContent.\(panelId)"].firstMatch
        if browserPane.waitForExistence(timeout: timeout) {
            browserPane.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            return
        }

        let page = app.webViews.firstMatch
        guard page.waitForExistence(timeout: timeout) else {
            XCTFail(failureMessage)
            return
        }
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    private func launchAndEnsureForeground(_ app: XCUIApplication, timeout: TimeInterval = 12.0) {
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: timeout),
            "Expected app to launch in foreground. state=\(app.state.rawValue)"
        )
    }

    private func ensureForegroundAfterLaunch(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        if app.wait(for: .runningForeground, timeout: timeout) {
            return true
        }
        if app.state == .runningBackground {
            app.activate()
            return app.wait(for: .runningForeground, timeout: 6.0)
        }
        return false
    }

    private func waitForData(keys: [String], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = loadData(), keys.allSatisfy({ data[$0] != nil }) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if let data = loadData(), keys.allSatisfy({ data[$0] != nil }) {
            return true
        }
        return false
    }

    private func waitForDataMatch(timeout: TimeInterval, predicate: ([String: String]) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = loadData(), predicate(data) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if let data = loadData(), predicate(data) {
            return true
        }
        return false
    }

    private func waitForNonExistence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func loadData() -> [String: String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: dataPath)) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
    }
}
