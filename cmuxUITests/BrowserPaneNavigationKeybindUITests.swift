import XCTest
import Foundation

final class BrowserPaneNavigationKeybindUITests: XCTestCase {
    private struct WorkspaceContext {
        let workspaceId: String
        let windowId: String
    }

    private var dataPath = ""
    private var socketPath = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIApplication().terminate()
        dataPath = "/tmp/cmux-ui-test-goto-split-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: dataPath)
        socketPath = "/tmp/cmux-ui-test-socket-\(UUID().uuidString).sock"
        try? FileManager.default.removeItem(atPath: socketPath)
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
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_BROWSER_URL"] = focusedInputRoundTripPageURL
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
            "Expected setup data including focused page input to be written. path=\(dataPath) data=\(loadData() ?? [:])"
        )

        guard let setup = loadData() else {
            XCTFail("Missing goto_split setup data")
            return
        }

        XCTAssertEqual(setup["webViewFocused"], "true", "Expected WKWebView to be first responder for this test")
        XCTAssertEqual(setup["webInputFocusSeeded"], "true", "Expected test page input to be focused before Cmd+L")

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
                data["browserPageTitle"] == "cmux-ui-focus-primary:cmux-ui-focus-primary"
        }) {
            app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        }

        let restoredExpectedInput = waitForDataMatch(timeout: 6.0) { data in
            data["webViewFocusedAfterAddressBarExit"] == "true" &&
                data["browserPageTitle"] == "cmux-ui-focus-primary:cmux-ui-focus-primary"
        }
        if !restoredExpectedInput {
            let snapshot = loadData() ?? [:]
            XCTFail(
                "Expected Escape to restore focus to the previously focused page input. " +
                "webViewFocusedAfterAddressBarExit=\(snapshot["webViewFocusedAfterAddressBarExit"] ?? "nil") " +
                "browserPageTitle=\(snapshot["browserPageTitle"] ?? "nil") " +
                "browserPageURL=\(snapshot["browserPageURL"] ?? "nil")"
            )
        }

        app.typeText("z")
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                data["browserPageTitle"] == "cmux-ui-focus-primary:cmux-ui-focus-primaryz"
            },
            "Expected typing after Escape to stay in the primary page input"
        )

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

        let clickedSecondary = waitForDataMatch(timeout: 6.0) { data in
            data["browserPageTitle"] == "cmux-ui-focus-secondary:cmux-ui-focus-secondary"
        }
        if !clickedSecondary {
            let snapshot = loadData() ?? [:]
            XCTFail(
                "Expected post-escape click to focus secondary page input before Cmd+L. " +
                "browserPageTitle=\(snapshot["browserPageTitle"] ?? "nil") " +
                "browserPageURL=\(snapshot["browserPageURL"] ?? "nil")"
            )
        }

        app.typeKey("l", modifierFlags: [.command])
        XCTAssertTrue(
            waitForDataMatch(timeout: 5.0) { data in
                data["webViewFocusedAfterAddressBarFocus"] == "false"
            },
            "Expected Cmd+L to focus omnibar after clicking the secondary page input"
        )

        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        if !waitForDataMatch(timeout: 2.0, predicate: { data in
            data["webViewFocusedAfterAddressBarExit"] == "true" &&
                data["browserPageTitle"] == "cmux-ui-focus-secondary:cmux-ui-focus-secondary"
        }) {
            app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        }

        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                data["webViewFocusedAfterAddressBarExit"] == "true" &&
                    data["browserPageTitle"] == "cmux-ui-focus-secondary:cmux-ui-focus-secondary"
            },
            "Expected Escape to restore focus to the clicked secondary page input"
        )

        app.typeText("y")
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                data["browserPageTitle"] == "cmux-ui-focus-secondary:cmux-ui-focus-secondaryy"
            },
            "Expected typing after Escape to stay in the clicked secondary page input"
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

    func testCmdFOpensBrowserFindAfterCmdDCmdLNavigation() {
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

        let browserFindField = app.textFields["BrowserFindSearchTextField"].firstMatch
        XCTAssertTrue(browserFindField.waitForExistence(timeout: 6.0), "Expected browser find field after Cmd+F")

        let omnibarValueBeforeFindTyping = (omnibar.value as? String) ?? ""
        app.typeText("needle")

        XCTAssertTrue(
            waitForCondition(timeout: 4.0) {
                ((browserFindField.value as? String) ?? "") == "needle"
            },
            "Expected Cmd+F to focus browser find after Cmd+D, Cmd+L, and navigation. " +
                "findValue=\(String(describing: browserFindField.value)) omnibarValue=\(String(describing: omnibar.value))"
        )
        let omnibarValueAfterFindTyping = (omnibar.value as? String) ?? ""
        XCTAssertFalse(
            omnibarValueAfterFindTyping.contains("needle"),
            "Expected typing after Cmd+F to stay out of the omnibar. " +
                "omnibarValueBefore=\(omnibarValueBeforeFindTyping) " +
                "omnibarValueAfter=\(String(describing: omnibar.value)) " +
                "findValue=\(String(describing: browserFindField.value))"
        )

        XCTAssertFalse(
            app.textFields["FileExplorerSearchField"].firstMatch.exists,
            "Expected browser Cmd+F to use browser find rather than right-sidebar Find"
        )
    }

    func testRightSidebarFindFieldKeepsFocusAfterNewWorkspaceRoundTrip() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_RECORD_ONLY"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        launchAndEnsureForeground(app)

        let window = app.windows.firstMatch
        _ = window.waitForExistence(timeout: 2.0)
        XCTAssertTrue(waitForSocketPong(timeout: 12.0), "Expected control socket at \(socketPath)")

        guard let originalWorkspace = currentWorkspaceContext() else {
            XCTFail("Expected current workspace context before leaving the original workspace")
            return
        }

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

        let findField = app.textFields["FileExplorerSearchField"].firstMatch
        XCTAssertTrue(findField.waitForExistence(timeout: 6.0), "Expected right sidebar file search after Cmd+F")

        app.typeText("seed")
        XCTAssertTrue(
            waitForCondition(timeout: 4.0) {
                ((findField.value as? String) ?? "") == "seed"
            },
            "Expected right sidebar file search to capture initial typing. value=\(String(describing: findField.value))"
        )

        openCommandPaletteForNewWorkspace(app, windowId: originalWorkspace.windowId)
        XCTAssertTrue(
            selectWorkspace(originalWorkspace.workspaceId),
            "Expected to return to the original workspace by identity"
        )

        let restoredFindField = app.textFields["FileExplorerSearchField"].firstMatch
        XCTAssertTrue(restoredFindField.waitForExistence(timeout: 6.0), "Expected right sidebar file search after returning to workspace 1")
        XCTAssertTrue(
            waitForCondition(timeout: 4.0) {
                ((restoredFindField.value as? String) ?? "") == "seed"
            },
            "Expected existing file search query to persist after returning. value=\(String(describing: restoredFindField.value))"
        )

        app.typeText("x")
        XCTAssertTrue(
            waitForCondition(timeout: 4.0) {
                ((restoredFindField.value as? String) ?? "") == "seedx"
            },
            "Expected typing after returning from a new workspace to stay in right sidebar file search. " +
                "findValue=\(String(describing: restoredFindField.value)) omnibarValue=\(String(describing: omnibar.value))"
        )
    }

    func testEscapeAfterBrowserFindPaneRoundTripRestoresPageInputFocus() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_FOCUS_SHORTCUTS"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_INPUT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_BROWSER_URL"] = focusedInputRoundTripPageURL
        launchAndEnsureForeground(app)

        XCTAssertTrue(
            waitForData(
                keys: [
                    "browserPanelId",
                    "terminalPaneId",
                    "webViewFocused",
                    "webInputFocusSeeded",
                    "webInputFocusElementId"
                ],
                timeout: 12.0
            ),
            "Expected setup data including focused page input to be written. path=\(dataPath) data=\(loadData() ?? [:])"
        )

        guard let setup = loadData() else {
            XCTFail("Missing goto_split setup data")
            return
        }

        XCTAssertEqual(setup["webViewFocused"], "true", "Expected WKWebView to be first responder for this test")
        XCTAssertEqual(setup["webInputFocusSeeded"], "true", "Expected test page input to be focused before Cmd+F")

        guard let expectedTerminalPaneId = setup["terminalPaneId"] else {
            XCTFail("Missing terminalPaneId in setup data")
            return
        }

        app.typeKey("f", modifierFlags: [.command])
        let findField = app.textFields["BrowserFindSearchTextField"].firstMatch
        XCTAssertTrue(findField.waitForExistence(timeout: 6.0), "Expected browser find field after Cmd+F")

        app.typeText("seed")
        XCTAssertTrue(
            waitForCondition(timeout: 4.0) {
                ((findField.value as? String) ?? "") == "seed"
            },
            "Expected browser find field to capture initial typing. value=\(String(describing: findField.value))"
        )

        app.typeKey("h", modifierFlags: [.command, .control])
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                data["focusedPaneId"] == expectedTerminalPaneId &&
                    data["focusedPanelKind"] == "terminal" &&
                    data["browserFindNeedle"] == "seed"
            },
            "Expected Cmd+Ctrl+H to focus the terminal pane while browser find stays open. data=\(loadData() ?? [:])"
        )

        app.typeKey("l", modifierFlags: [.command, .control])
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                data["focusedPanelKind"] == "browser" &&
                    data["browserFindNeedle"] == "seed"
            },
            "Expected Cmd+Ctrl+L to return to the browser pane with browser find still active. data=\(loadData() ?? [:])"
        )

        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(waitForNonExistence(findField, timeout: 5.0), "Expected Escape to close browser find")
        XCTAssertTrue(
            waitForDataMatch(timeout: 5.0) { data in
                data["browserFindVisible"] == "false"
            },
            "Expected browser find state to be cleared after Escape. data=\(loadData() ?? [:])"
        )

        app.typeText("z")
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                data["browserPageTitle"] == "cmux-ui-focus-primary:cmux-ui-focus-primaryz"
            },
            "Expected typing after Escape to return to the page input. data=\(loadData() ?? [:])"
        )
    }

    func testEscapeAfterBrowserFindRestoresPageInputFocusWithoutPaneSwitch() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_INPUT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_BROWSER_URL"] = focusedInputRoundTripPageURL
        launchAndEnsureForeground(app)

        XCTAssertTrue(
            waitForData(
                keys: [
                    "browserPanelId",
                    "webViewFocused",
                    "webInputFocusSeeded",
                    "webInputFocusElementId"
                ],
                timeout: 12.0
            ),
            "Expected setup data including focused page input to be written. path=\(dataPath) data=\(loadData() ?? [:])"
        )

        guard let setup = loadData() else {
            XCTFail("Missing goto_split setup data")
            return
        }

        XCTAssertEqual(setup["webViewFocused"], "true", "Expected WKWebView to be first responder for this test")
        XCTAssertEqual(setup["webInputFocusSeeded"], "true", "Expected test page input to be focused before Cmd+F")

        app.typeKey("f", modifierFlags: [.command])
        let findField = app.textFields["BrowserFindSearchTextField"].firstMatch
        XCTAssertTrue(findField.waitForExistence(timeout: 6.0), "Expected browser find field after Cmd+F")

        app.typeText("seed")
        XCTAssertTrue(
            waitForCondition(timeout: 4.0) {
                ((findField.value as? String) ?? "") == "seed"
            },
            "Expected browser find field to capture typing. value=\(String(describing: findField.value))"
        )

        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(waitForNonExistence(findField, timeout: 5.0), "Expected Escape to close browser find")
        XCTAssertTrue(
            waitForDataMatch(timeout: 5.0) { data in
                data["browserFindVisible"] == "false"
            },
            "Expected browser find state to be cleared after Escape. data=\(loadData() ?? [:])"
        )

        app.typeText("z")
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                data["browserPageTitle"] == "cmux-ui-focus-primary:cmux-ui-focus-primaryz"
            },
            "Expected typing after Escape to return to the page input without pane switching. data=\(loadData() ?? [:])"
        )
    }

    func testRepeatedEscapeAfterBrowserFindCmdOptionPaneRoundTripRestoresPageInputFocus() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_INPUT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_BROWSER_URL"] = focusedInputRoundTripPageURL
        launchAndEnsureForeground(app)

        XCTAssertTrue(
            waitForData(
                keys: [
                    "browserPanelId",
                    "terminalPaneId",
                    "webViewFocused",
                    "webInputFocusSeeded",
                    "webInputFocusElementId"
                ],
                timeout: 12.0
            ),
            "Expected setup data including focused page input to be written. path=\(dataPath) data=\(loadData() ?? [:])"
        )

        guard let setup = loadData() else {
            XCTFail("Missing goto_split setup data")
            return
        }

        XCTAssertEqual(setup["webViewFocused"], "true", "Expected WKWebView to be first responder for this test")
        XCTAssertEqual(setup["webInputFocusSeeded"], "true", "Expected test page input to be focused before Cmd+F")

        guard let expectedTerminalPaneId = setup["terminalPaneId"] else {
            XCTFail("Missing terminalPaneId in setup data")
            return
        }

        let iterationMarkers = Array("abcdefghijklmnopqrstuvwxyzabcd")
        var expectedInputValueAfterTyping = "cmux-ui-focus-primary"

        for iteration in 1...30 {
            let marker = String(iterationMarkers[iteration - 1])
            let typedTextAfterEscape = " \(marker)"
            expectedInputValueAfterTyping += typedTextAfterEscape
            assertBrowserFindPaneRoundTripRestoresPageInput(
                app,
                expectedTerminalPaneId: expectedTerminalPaneId,
                route: .cmdOptionArrows,
                findNeedle: "seed\(iteration)",
                typedTextAfterEscape: typedTextAfterEscape,
                expectedInputValueAfterTyping: expectedInputValueAfterTyping,
                iteration: iteration
            )
        }
    }

    func testGoogleLikeSearchInputKeepsCaretAndSpacesAfterRepeatedPaneFocusRoundTrips() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_BROWSER_URL"] = googleLikeSearchPageURL
        launchAndEnsureForeground(app)

        XCTAssertTrue(
            waitForData(
                keys: [
                    "browserPanelId",
                    "terminalPaneId",
                    "webViewFocused",
                    "browserPageTitle"
                ],
                timeout: 12.0
            ),
            "Expected setup data including Google-like page state to be written. path=\(dataPath) data=\(loadData() ?? [:])"
        )

        guard let setup = loadData() else {
            XCTFail("Missing goto_split setup data")
            return
        }

        XCTAssertEqual(setup["webViewFocused"], "true", "Expected WKWebView to be first responder for this test")

        guard let expectedTerminalPaneId = setup["terminalPaneId"] else {
            XCTFail("Missing terminalPaneId in setup data")
            return
        }

        var expectedSearchValue = "cmux google"
        XCTAssertTrue(
            waitForGoogleLikeSearchState(expectedValue: expectedSearchValue, timeout: 8.0),
            "Expected Google-like page input to start focused with the caret at the end. data=\(loadData() ?? [:])"
        )

        let iterationMarkers = Array("abcdefghijklmnopqrstuvwxyzabcd")
        for iteration in 1...30 {
            focusLeftPaneForFindScenario(app, route: .cmdOptionArrows)
            XCTAssertTrue(
                waitForDataMatch(timeout: 6.0) { data in
                    data["focusedPaneId"] == expectedTerminalPaneId &&
                        data["focusedPanelKind"] == "terminal"
                },
                "Expected focus-left shortcut to focus the terminal pane. iteration=\(iteration) data=\(loadData() ?? [:])"
            )

            focusRightPaneForFindScenario(app, route: .cmdOptionArrows)
            XCTAssertTrue(
                waitForDataMatch(timeout: 6.0) { data in
                    data["focusedPanelKind"] == "browser"
                },
                "Expected focus-right shortcut to return to the browser pane. iteration=\(iteration) data=\(loadData() ?? [:])"
            )

            let marker = String(iterationMarkers[iteration - 1])
            let typedText = " \(marker)"
            expectedSearchValue += typedText
            app.typeText(typedText)

            XCTAssertTrue(
                waitForGoogleLikeSearchState(expectedValue: expectedSearchValue, timeout: 8.0),
                "Expected Google-like search input, suggestion text, and caret to include the typed leading space. " +
                    "iteration=\(iteration) expected=\(expectedSearchValue) data=\(loadData() ?? [:])"
            )
        }
    }

    func testWorkspaceRoundTripPreservesFocusedTerminalFindWhenBrowserFindIsAlsoOpen() {
        runSplitFindWorkspaceRoundTripScenario(restoredOwner: .terminal)
    }

    func testWorkspaceRoundTripPreservesFocusedBrowserFindWhenTerminalFindIsAlsoOpen() {
        runSplitFindWorkspaceRoundTripScenario(restoredOwner: .browser)
    }

    private enum FindFocusRoute {
        case cmdOptionArrows
        case cmdCtrlLetters
    }

    private enum SplitFindOwner {
        case terminal
        case browser

        var focusedPanelKind: String {
            switch self {
            case .terminal:
                return "terminal"
            case .browser:
                return "browser"
            }
        }
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

    private func runSplitFindWorkspaceRoundTripScenario(restoredOwner: SplitFindOwner) {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_RECORD_ONLY"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        launchAndEnsureForeground(app)

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10.0), "Expected main window to exist")
        XCTAssertTrue(waitForSocketPong(timeout: 12.0), "Expected control socket at \(socketPath)")

        guard let originalWorkspace = currentWorkspaceContext() else {
            XCTFail("Expected current workspace context before leaving workspace 1")
            return
        }

        app.typeKey("d", modifierFlags: [.command])
        focusRightPaneForFindScenario(app, route: .cmdOptionArrows)

        app.typeKey("l", modifierFlags: [.command, .shift])
        let omnibar = app.textFields["BrowserOmnibarTextField"].firstMatch
        XCTAssertTrue(omnibar.waitForExistence(timeout: 8.0), "Expected browser omnibar after Cmd+Shift+L")

        app.typeKey("a", modifierFlags: [.command])
        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        app.typeText("example.com")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

        XCTAssertTrue(
            waitForOmnibarToContainExampleDomain(omnibar, timeout: 8.0),
            "Expected browser navigation to example domain before running workspace round trip. value=\(String(describing: omnibar.value))"
        )

        focusLeftPaneForFindScenario(app, route: .cmdOptionArrows)
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                data["focusedPanelKind"] == "terminal"
            },
            "Expected left terminal pane to be focused before opening terminal find. data=\(String(describing: loadData()))"
        )
        app.typeKey("f", modifierFlags: [.command])
        app.typeText("la")

        focusRightPaneForFindScenario(app, route: .cmdOptionArrows)
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                data["focusedPanelKind"] == "browser"
                    && data["terminalFindNeedle"] == "la"
            },
            "Expected terminal find query to persist before opening browser find. data=\(String(describing: loadData()))"
        )
        app.typeKey("f", modifierFlags: [.command])
        app.typeText("am")

        switch restoredOwner {
        case .terminal:
            focusLeftPaneForFindScenario(app, route: .cmdOptionArrows)
        case .browser:
            break
        }

        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                data["focusedPanelKind"] == restoredOwner.focusedPanelKind
                    && data["terminalFindNeedle"] == "la"
                    && data["browserFindNeedle"] == "am"
            },
            "Expected the intended find owner before leaving workspace 1. data=\(String(describing: loadData()))"
        )

        openCommandPaletteForNewWorkspace(app, windowId: originalWorkspace.windowId)
        XCTAssertTrue(
            selectWorkspace(originalWorkspace.workspaceId),
            "Expected to return to the original workspace by identity"
        )

        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                data["focusedPanelKind"] == restoredOwner.focusedPanelKind
                    && data["terminalFindNeedle"] == "la"
                    && data["browserFindNeedle"] == "am"
            },
            "Expected the previously focused find owner to be restored after the workspace round trip. data=\(String(describing: loadData()))"
        )

        switch restoredOwner {
        case .terminal:
            app.typeText("foo")
            XCTAssertTrue(
                waitForDataMatch(timeout: 6.0) { data in
                    data["focusedPanelKind"] == "terminal"
                        && data["terminalFindNeedle"] == "lafoo"
                        && data["browserFindNeedle"] == "am"
                },
                "Expected typing after returning to stay in terminal find. data=\(String(describing: loadData()))"
            )
        case .browser:
            app.typeText("do")
            XCTAssertTrue(
                waitForDataMatch(timeout: 6.0) { data in
                    data["focusedPanelKind"] == "browser"
                        && data["terminalFindNeedle"] == "la"
                        && data["browserFindNeedle"] == "amdo"
                },
                "Expected typing after returning to stay in browser find. data=\(String(describing: loadData()))"
            )
        }
    }

    private func openCommandPaletteForNewWorkspace(_ app: XCUIApplication, windowId: String) {
        app.typeKey("p", modifierFlags: [.command, .shift])

        let paletteSearchField = app.textFields["CommandPaletteSearchField"].firstMatch
        XCTAssertTrue(paletteSearchField.waitForExistence(timeout: 5.0), "Expected command palette search field")
        paletteSearchField.click()
        paletteSearchField.typeText("New Workspace")

        guard let snapshot = waitForCommandPaletteSnapshot(
            windowId: windowId,
            mode: "commands",
            query: "New Workspace",
            timeout: 5.0,
            predicate: { snapshot in
                guard let firstRow = self.commandPaletteResultRows(from: snapshot).first else { return false }
                return (firstRow["command_id"] as? String) == "palette.newWorkspace"
            }
        ) else {
            XCTFail("Expected palette.newWorkspace to be the selected command palette result")
            return
        }
        XCTAssertEqual(
            commandPaletteResultRows(from: snapshot).first?["command_id"] as? String,
            "palette.newWorkspace",
            "Expected palette.newWorkspace to be selected before pressing Return"
        )

        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

        XCTAssertTrue(
            waitForNonExistence(paletteSearchField, timeout: 5.0),
            "Expected command palette to dismiss after creating a workspace"
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

    private func assertBrowserFindPaneRoundTripRestoresPageInput(
        _ app: XCUIApplication,
        expectedTerminalPaneId: String,
        route: FindFocusRoute,
        findNeedle: String,
        typedTextAfterEscape: String,
        expectedInputValueAfterTyping: String,
        iteration: Int
    ) {
        app.typeKey("f", modifierFlags: [.command])
        let findField = app.textFields["BrowserFindSearchTextField"].firstMatch
        XCTAssertTrue(findField.waitForExistence(timeout: 6.0), "Expected browser find field after Cmd+F. iteration=\(iteration)")

        app.typeKey("a", modifierFlags: [.command])
        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        app.typeText(findNeedle)
        XCTAssertTrue(
            waitForCondition(timeout: 4.0) {
                ((findField.value as? String) ?? "") == findNeedle
            },
            "Expected browser find field to capture typing. iteration=\(iteration) value=\(String(describing: findField.value))"
        )

        focusLeftPaneForFindScenario(app, route: route)
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                data["focusedPaneId"] == expectedTerminalPaneId &&
                    data["focusedPanelKind"] == "terminal" &&
                    data["browserFindNeedle"] == findNeedle
            },
            "Expected focus-left shortcut to focus the terminal pane while browser find stays open. iteration=\(iteration) data=\(loadData() ?? [:])"
        )

        focusRightPaneForFindScenario(app, route: route)
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                data["focusedPanelKind"] == "browser" &&
                    data["browserFindNeedle"] == findNeedle
            },
            "Expected focus-right shortcut to return to the browser pane with browser find still active. iteration=\(iteration) data=\(loadData() ?? [:])"
        )

        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(waitForNonExistence(findField, timeout: 5.0), "Expected Escape to close browser find. iteration=\(iteration)")
        XCTAssertTrue(
            waitForDataMatch(timeout: 5.0) { data in
                data["browserFindVisible"] == "false"
            },
            "Expected browser find state to be cleared after Escape. iteration=\(iteration) data=\(loadData() ?? [:])"
        )

        app.typeText(typedTextAfterEscape)
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                data["browserPageTitle"] == "cmux-ui-focus-primary:\(expectedInputValueAfterTyping)"
            },
            "Expected typing after Escape to return to the page input. iteration=\(iteration) data=\(loadData() ?? [:])"
        )
    }

    private func waitForGoogleLikeSearchState(expectedValue: String, timeout: TimeInterval) -> Bool {
        waitForDataMatch(timeout: timeout) { data in
            let state = self.googleLikeSearchState(from: data)
            let expectedEncoded = self.googleLikeTitleEncoded(expectedValue)
            let expectedCaret = String(expectedValue.count)
            return state["value"] == expectedEncoded &&
                state["suggestion"] == expectedEncoded &&
                state["start"] == expectedCaret &&
                state["end"] == expectedCaret &&
                state["active"] == "q"
        }
    }

    private func googleLikeSearchState(from data: [String: String]) -> [String: String] {
        guard let title = data["browserPageTitle"],
              title.hasPrefix("cmux-google-like|") else {
            return [:]
        }

        return title
            .split(separator: "|")
            .dropFirst()
            .reduce(into: [String: String]()) { result, component in
                let parts = component.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { return }
                result[String(parts[0])] = String(parts[1])
            }
    }

    private func googleLikeTitleEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
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

    private func waitForSocketPong(timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            self.socketCommand("ping") == "PONG"
        }
    }

    private func currentWorkspaceContext() -> WorkspaceContext? {
        guard let envelope = socketJSON(method: "workspace.current", params: [:]),
              let ok = envelope["ok"] as? Bool,
              ok,
              let result = envelope["result"] as? [String: Any],
              let workspaceId = result["workspace_id"] as? String,
              let windowId = result["window_id"] as? String else {
            return nil
        }
        return WorkspaceContext(workspaceId: workspaceId, windowId: windowId)
    }

    private func selectWorkspace(_ workspaceId: String) -> Bool {
        guard let envelope = socketJSON(
            method: "workspace.select",
            params: ["workspace_id": workspaceId]
        ),
        let ok = envelope["ok"] as? Bool,
        ok else {
            return false
        }

        return waitForCondition(timeout: 5.0) {
            self.currentWorkspaceContext()?.workspaceId == workspaceId
        }
    }

    private func socketCommand(_ command: String) -> String? {
        ControlSocketClient(path: socketPath, responseTimeout: 2.0).sendLine(command)
    }

    private func socketJSON(method: String, params: [String: Any]) -> [String: Any]? {
        let request: [String: Any] = [
            "id": UUID().uuidString,
            "method": method,
            "params": params,
        ]
        return ControlSocketClient(path: socketPath, responseTimeout: 2.0).sendJSON(request)
    }

    private func commandPaletteResultRows(from snapshot: [String: Any]) -> [[String: Any]] {
        snapshot["results"] as? [[String: Any]] ?? []
    }

    private func waitForCommandPaletteSnapshot(
        windowId: String,
        mode: String,
        query: String,
        timeout: TimeInterval,
        predicate: (([String: Any]) -> Bool)? = nil
    ) -> [String: Any]? {
        var latest: [String: Any]?
        let matched = waitForCondition(timeout: timeout) {
            guard let snapshot = self.commandPaletteSnapshot(windowId: windowId) else { return false }
            latest = snapshot
            guard (snapshot["visible"] as? Bool) == true else { return false }
            guard (snapshot["mode"] as? String) == mode else { return false }
            guard (snapshot["query"] as? String) == query else { return false }
            return predicate?(snapshot) ?? true
        }
        return matched ? latest : nil
    }

    private func commandPaletteSnapshot(windowId: String) -> [String: Any]? {
        let envelope = socketJSON(
            method: "debug.command_palette.results",
            params: [
                "window_id": windowId,
                "limit": 20,
            ]
        )
        guard let ok = envelope?["ok"] as? Bool, ok else { return nil }
        return envelope?["result"] as? [String: Any]
    }

    private var autofocusRacePageURL: String {
        "data:text/html,%3Cinput%20id%3D%22q%22%3E%3Cscript%3EsetTimeout%28function%28%29%7Bdocument.getElementById%28%22q%22%29.focus%28%29%3Blocation.hash%3D%22focused%22%3B%7D%2C700%29%3B%3C%2Fscript%3E"
    }

    private var focusedInputRoundTripPageURL: String {
        let html = """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <title>cmux-ui-focus-loading</title>
          <style>
            body {
              margin: 0;
              min-height: 100vh;
              background: #fff;
              font-family: system-ui, -apple-system, sans-serif;
            }
            input {
              position: fixed;
              left: 24px;
              width: min(520px, calc(100vw - 48px));
              height: 40px;
              box-sizing: border-box;
              padding: 0 10px;
              border: 1px solid #5f6368;
              border-radius: 6px;
              font-size: 14px;
              background: #fff;
              color: #000;
            }
            #cmux-ui-test-focus-input {
              top: 24px;
            }
            #cmux-ui-test-focus-input-secondary {
              top: 76px;
            }
          </style>
        </head>
        <body>
          <input
            id="cmux-ui-test-focus-input"
            type="text"
            value="cmux-ui-focus-primary"
            autocapitalize="off"
            autocomplete="off"
            spellcheck="false"
          >
          <input
            id="cmux-ui-test-focus-input-secondary"
            type="text"
            value="cmux-ui-focus-secondary"
            autocapitalize="off"
            autocomplete="off"
            spellcheck="false"
          >
          <script>
            const primary = document.getElementById('cmux-ui-test-focus-input');
            const secondary = document.getElementById('cmux-ui-test-focus-input-secondary');

            const updateTitle = () => {
              const active = document.activeElement === secondary ? secondary : primary;
              const prefix = active === secondary ? 'cmux-ui-focus-secondary:' : 'cmux-ui-focus-primary:';
              document.title = prefix + String(active.value || '');
            };

            [primary, secondary].forEach((input) => {
              input.addEventListener('focus', updateTitle, true);
              input.addEventListener('input', updateTitle, true);
            });

            window.addEventListener('load', () => {
              primary.focus({ preventScroll: true });
              if (typeof primary.setSelectionRange === 'function') {
                const end = primary.value.length;
                primary.setSelectionRange(end, end);
              }
              updateTitle();
            }, { once: true });
          </script>
        </body>
        </html>
        """
        let encoded = html.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return "data:text/html,\(encoded)"
    }

    private var googleLikeSearchPageURL: String {
        let html = """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <title>cmux-google-like-loading</title>
          <style>
            body {
              margin: 0;
              min-height: 100vh;
              background: #fff;
              color: #202124;
              font-family: Arial, sans-serif;
            }
            main {
              width: min(640px, calc(100vw - 48px));
              margin: 72px auto 0;
            }
            input {
              width: 100%;
              height: 46px;
              box-sizing: border-box;
              padding: 0 16px;
              border: 1px solid #dfe1e5;
              border-radius: 23px;
              font-size: 16px;
              outline: none;
            }
            input:focus {
              box-shadow: 0 1px 6px rgba(32, 33, 36, 0.28);
            }
            #suggestions {
              margin-top: 8px;
              padding: 8px 16px;
              border: 1px solid #dfe1e5;
              border-radius: 8px;
              font-size: 14px;
              min-height: 20px;
            }
          </style>
        </head>
        <body>
          <main>
            <input
              id="q"
              type="search"
              value="cmux google"
              autocomplete="off"
              autocorrect="off"
              autocapitalize="off"
              spellcheck="false"
              aria-label="Search"
            >
            <div id="suggestions"></div>
          </main>
          <script>
            const q = document.getElementById('q');
            const suggestions = document.getElementById('suggestions');
            let lastKey = 'none';
            let lastBeforeInput = 'none';
            let suggestionMirror = q.value;
            let suggestionCaret = q.value.length;

            const encode = (value) => encodeURIComponent(String(value || ''));
            const updateTitle = () => {
              const start = typeof q.selectionStart === 'number' ? q.selectionStart : -1;
              const end = typeof q.selectionEnd === 'number' ? q.selectionEnd : -1;
              const active = document.activeElement === q ? 'q' : 'other';
              suggestions.textContent = suggestionMirror;
              document.title = [
                'cmux-google-like',
                'value=' + encode(q.value),
                'suggestion=' + encode(suggestions.textContent),
                'start=' + start,
                'end=' + end,
                'active=' + active,
                'lastKey=' + encode(lastKey),
                'before=' + encode(lastBeforeInput)
              ].join('|');
            };

            const updateSoon = () => {
              updateTitle();
              requestAnimationFrame(updateTitle);
            };

            q.addEventListener('keydown', (event) => {
              lastKey = event.key === ' ' ? 'Space' : event.key;
              updateSoon();
            }, true);
            q.addEventListener('beforeinput', (event) => {
              lastBeforeInput = event.data === ' ' ? 'Space' : (event.data || event.inputType || 'none');
              if (event.inputType === 'insertText' && typeof event.data === 'string' && event.data.length > 0) {
                const start = Math.max(0, Math.min(suggestionCaret, suggestionMirror.length));
                suggestionMirror = suggestionMirror.slice(0, start) + event.data + suggestionMirror.slice(start);
                suggestionCaret = start + event.data.length;
              }
              updateSoon();
            }, true);
            q.addEventListener('input', () => {
              if (q.value === suggestionMirror && typeof q.selectionEnd === 'number') {
                suggestionCaret = q.selectionEnd;
              }
              updateSoon();
            }, true);
            q.addEventListener('keyup', updateSoon, true);
            q.addEventListener('focus', updateSoon, true);
            q.addEventListener('blur', updateSoon, true);
            document.addEventListener('selectionchange', updateSoon, true);
            window.addEventListener('focus', updateSoon, true);
            window.addEventListener('blur', updateSoon, true);
            window.addEventListener('load', () => {
              q.focus({ preventScroll: true });
              const end = q.value.length;
              q.setSelectionRange(end, end);
              updateSoon();
            }, { once: true });
          </script>
        </body>
        </html>
        """
        let encoded = html.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return "data:text/html,\(encoded)"
    }

    private var zoomRoundTripPageURL: String {
        "data:text/html,%3Ctitle%3EIssue%201144%3C/title%3E%3Cbody%20style%3D%22margin:0;background:%231d1f24;color:white;font-family:system-ui;height:2200px%22%3E%3Cmain%20style%3D%22padding:32px%22%3E%3Ch1%3EIssue%201144%20Regression%20Page%3C/h1%3E%3Cp%3EZoom%20should%20not%20leave%20stale%20split%20chrome%20above%20the%20browser%20omnibar.%3C/p%3E%3C/main%3E%3C/body%3E"
    }

    private func launchAndEnsureForeground(_ app: XCUIApplication, timeout: TimeInterval = 12.0) {
        // On headless CI runners (no GUI session), XCUIApplication.launch()
        // blocks ~60s then fails with "Failed to activate application
        // (current state: Running Background)". Mark this as an expected
        // failure so the test can continue — keyboard and element APIs work
        // via accessibility even when the app is in .runningBackground.
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: options) {
            app.launch()
        }

        if app.state == .runningForeground { return }

        if app.state == .runningBackground {
            // App launched but couldn't activate — continue in background.
            // XCUIElement queries and keyboard input work through the
            // accessibility framework regardless of activation state.
            return
        }

        XCTFail("App failed to start. state=\(app.state.rawValue)")
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

    private func waitForCondition(timeout: TimeInterval, predicate: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in predicate() },
            object: nil
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private final class ControlSocketClient {
        private let path: String
        private let responseTimeout: TimeInterval

        init(path: String, responseTimeout: TimeInterval) {
            self.path = path
            self.responseTimeout = responseTimeout
        }

        func sendJSON(_ object: [String: Any]) -> [String: Any]? {
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object),
                  let line = String(data: data, encoding: .utf8),
                  let response = sendLine(line),
                  let responseData = response.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                return nil
            }
            return parsed
        }

        func sendLine(_ line: String) -> String? {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }

#if os(macOS)
            var noSigPipe: Int32 = 1
            _ = withUnsafePointer(to: &noSigPipe) { ptr in
                setsockopt(
                    fd,
                    SOL_SOCKET,
                    SO_NOSIGPIPE,
                    ptr,
                    socklen_t(MemoryLayout<Int32>.size)
                )
            }
#endif

            var addr = sockaddr_un()
            memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
            addr.sun_family = sa_family_t(AF_UNIX)

            let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
            let bytes = Array(path.utf8CString)
            guard bytes.count <= maxLen else { return nil }
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                let raw = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
                memset(raw, 0, maxLen)
                for index in 0..<bytes.count {
                    raw[index] = bytes[index]
                }
            }

            let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
            let addrLen = socklen_t(pathOffset + bytes.count)
#if os(macOS)
            addr.sun_len = UInt8(min(Int(addrLen), 255))
#endif

            let connected = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    connect(fd, sa, addrLen)
                }
            }
            guard connected == 0 else { return nil }

            let payload = line + "\n"
            let wrote: Bool = payload.withCString { cString in
                var remaining = strlen(cString)
                var pointer = UnsafeRawPointer(cString)
                while remaining > 0 {
                    let written = write(fd, pointer, remaining)
                    if written <= 0 { return false }
                    remaining -= written
                    pointer = pointer.advanced(by: written)
                }
                return true
            }
            guard wrote else { return nil }

            let deadline = Date().addingTimeInterval(responseTimeout)
            var buffer = [UInt8](repeating: 0, count: 4096)
            var accumulator = ""
            while Date() < deadline {
                var pollDescriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pollDescriptor, 1, 100)
                if ready < 0 {
                    return nil
                }
                if ready == 0 {
                    continue
                }
                let count = read(fd, &buffer, buffer.count)
                if count <= 0 { break }
                if let chunk = String(bytes: buffer[0..<count], encoding: .utf8) {
                    accumulator.append(chunk)
                    if let newline = accumulator.firstIndex(of: "\n") {
                        return String(accumulator[..<newline])
                    }
                }
            }

            return accumulator.isEmpty ? nil : accumulator.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
