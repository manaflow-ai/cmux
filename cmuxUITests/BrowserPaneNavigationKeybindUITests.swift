import XCTest
import Foundation
import CoreGraphics

final class BrowserPaneNavigationKeybindUITests: XCTestCase {
    private struct WorkspaceContext {
        let workspaceId: String
        let windowId: String
    }

    private var dataPath = ""
    private var socketPath = ""
    private var isPreLaunched = false
    private var prelaunchPID: pid_t = 0

    private static let prelaunchManifestPath = "/tmp/cmux-ui-test-browser-prelaunch.json"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        if let manifest = Self.loadPrelaunchManifest() {
            isPreLaunched = true
            prelaunchPID = pid_t(manifest.pid ?? 0)
            dataPath = manifest.dataPath ?? "/tmp/cmux-ui-test-goto-split-\(UUID().uuidString).json"
            socketPath = manifest.socketPath ?? "/tmp/cmux-ui-test-socket-\(UUID().uuidString).sock"
        } else {
            dataPath = "/tmp/cmux-ui-test-goto-split-\(UUID().uuidString).json"
            socketPath = "/tmp/cmux-ui-test-socket-\(UUID().uuidString).sock"
        }
        try? FileManager.default.removeItem(atPath: dataPath)
    }

    private struct BrowserPrelaunchManifest: Decodable {
        let dataPath: String?
        let socketPath: String?
        let pid: Int?
    }

    private static func loadPrelaunchManifest() -> BrowserPrelaunchManifest? {
        let url = URL(fileURLWithPath: prelaunchManifestPath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BrowserPrelaunchManifest.self, from: data)
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

        sendKeyEvent(app, key: "d", modifierFlags: [.command])
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                guard data["lastSplitDirection"] == "right" else { return false }
                guard let paneCountAfterSplit = Int(data["paneCountAfterSplit"] ?? "") else { return false }
                return paneCountAfterSplit >= 2
            },
            "Expected Cmd+D to create a split before opening the browser. data=\(String(describing: loadData()))"
        )

        sendKeyEvent(app, key: "l", modifierFlags: [.command])

        let omnibar = app.textFields["BrowserOmnibarTextField"].firstMatch
        XCTAssertTrue(omnibar.waitForExistence(timeout: 8.0), "Expected browser omnibar after Cmd+L")

        sendKeyEvent(app, key: "a", modifierFlags: [.command])
        sendKeyEvent(app, key: XCUIKeyboardKey.delete.rawValue)
        sendText(app, text: "example.com")
        sendKeyEvent(app, key: XCUIKeyboardKey.return.rawValue)

        XCTAssertTrue(
            waitForOmnibarToContainExampleDomain(omnibar, timeout: 8.0),
            "Expected browser navigation to example domain before opening find. value=\(String(describing: omnibar.value))"
        )

        sendKeyEvent(app, key: "f", modifierFlags: [.command])

        let findField = app.textFields["BrowserFindSearchTextField"].firstMatch
        XCTAssertTrue(findField.waitForExistence(timeout: 6.0), "Expected browser find field after Cmd+F")

        let omnibarValueBeforeFindTyping = (omnibar.value as? String) ?? ""
        sendText(app, text: "needle")

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

    func testBrowserFindFieldKeepsFocusAfterNewWorkspaceRoundTrip() {
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

        let findField = app.textFields["BrowserFindSearchTextField"].firstMatch
        XCTAssertTrue(findField.waitForExistence(timeout: 6.0), "Expected browser find field after Cmd+F")

        app.typeText("seed")
        XCTAssertTrue(
            waitForCondition(timeout: 4.0) {
                ((findField.value as? String) ?? "") == "seed"
            },
            "Expected browser find field to capture initial typing. value=\(String(describing: findField.value))"
        )

        openCommandPaletteForNewWorkspace(app, windowId: originalWorkspace.windowId)
        XCTAssertTrue(
            selectWorkspace(originalWorkspace.workspaceId),
            "Expected to return to the original workspace by identity"
        )

        let restoredFindField = app.textFields["BrowserFindSearchTextField"].firstMatch
        XCTAssertTrue(restoredFindField.waitForExistence(timeout: 6.0), "Expected browser find field after returning to workspace 1")
        XCTAssertTrue(
            waitForCondition(timeout: 4.0) {
                ((restoredFindField.value as? String) ?? "") == "seed"
            },
            "Expected existing browser find query to persist after returning. value=\(String(describing: restoredFindField.value))"
        )

        app.typeText("x")
        XCTAssertTrue(
            waitForCondition(timeout: 4.0) {
                ((restoredFindField.value as? String) ?? "") == "seedx"
            },
            "Expected typing after returning from a new workspace to stay in the browser find field. " +
                "findValue=\(String(describing: restoredFindField.value)) omnibarValue=\(String(describing: omnibar.value))"
        )
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

    private var zoomRoundTripPageURL: String {
        "data:text/html,%3Ctitle%3EIssue%201144%3C/title%3E%3Cbody%20style%3D%22margin:0;background:%231d1f24;color:white;font-family:system-ui;height:2200px%22%3E%3Cmain%20style%3D%22padding:32px%22%3E%3Ch1%3EIssue%201144%20Regression%20Page%3C/h1%3E%3Cp%3EZoom%20should%20not%20leave%20stale%20split%20chrome%20above%20the%20browser%20omnibar.%3C/p%3E%3C/main%3E%3C/body%3E"
    }

    private func launchAndEnsureForeground(_ app: XCUIApplication, timeout: TimeInterval = 12.0) {
        if isPreLaunched {
            // App was pre-launched from the CI shell. Don't call launch() or
            // activate() — both block ~60s on headless CI runners. The test
            // uses CGEventPostToPid for keyboard input and XCUIApplication
            // element queries (which work on background apps via accessibility).
            return
        }
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

    // MARK: - CGEvent keyboard input for headless CI

    // Maps single-character key strings to macOS virtual key codes.
    private static let keyCodeMap: [String: CGKeyCode] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04,
        "g": 0x05, "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09,
        "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F,
        "y": 0x10, "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14,
        "4": 0x15, "6": 0x16, "5": 0x17, "9": 0x19, "7": 0x1A,
        "8": 0x1C, "0": 0x1D, "o": 0x1F, "u": 0x20, "i": 0x22,
        "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28, "n": 0x2D,
        "m": 0x2E, ".": 0x2F, "/": 0x2C, ":": 0x29,
    ]

    private func sendKeyEvent(_ app: XCUIApplication, key: String, modifierFlags: XCUIElement.KeyModifierFlags = []) {
        if isPreLaunched && prelaunchPID > 0 {
            postCGKeyEvent(key: key, modifierFlags: modifierFlags)
        } else {
            app.typeKey(key, modifierFlags: modifierFlags)
        }
    }

    private func sendText(_ app: XCUIApplication, text: String) {
        if isPreLaunched && prelaunchPID > 0 {
            postCGText(text)
        } else {
            app.typeText(text)
        }
    }

    private func postCGKeyEvent(key: String, modifierFlags: XCUIElement.KeyModifierFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        var flags: CGEventFlags = []
        if modifierFlags.contains(.command) { flags.insert(.maskCommand) }
        if modifierFlags.contains(.control) { flags.insert(.maskControl) }
        if modifierFlags.contains(.option) { flags.insert(.maskAlternate) }
        if modifierFlags.contains(.shift) { flags.insert(.maskShift) }

        let keyCode: CGKeyCode
        if key == XCUIKeyboardKey.delete.rawValue {
            keyCode = 0x33
        } else if key == XCUIKeyboardKey.return.rawValue {
            keyCode = 0x24
        } else if let code = Self.keyCodeMap[key.lowercased()] {
            keyCode = code
        } else {
            // Unknown key — post as unicode character
            postCGText(key)
            return
        }

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.postToPid(prelaunchPID)
        usleep(10_000)
        keyUp.postToPid(prelaunchPID)
        usleep(10_000)
    }

    private func postCGText(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for char in text {
            let chars = Array(String(char).utf16)
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { continue }
            keyDown.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
            keyUp.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
            keyDown.postToPid(prelaunchPID)
            usleep(5_000)
            keyUp.postToPid(prelaunchPID)
            usleep(5_000)
        }
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
