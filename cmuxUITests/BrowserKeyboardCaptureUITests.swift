import XCTest
import Foundation

final class BrowserKeyboardCaptureUITests: XCTestCase {
    private var gotoSplitPath = ""
    private var keyequivPath = ""
    private var socketPath = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        gotoSplitPath = "/tmp/cmux-ui-test-goto-split-\(UUID().uuidString).json"
        keyequivPath = "/tmp/cmux-ui-test-keyequiv-\(UUID().uuidString).json"
        socketPath = "/tmp/cmux-ui-test-socket-\(UUID().uuidString).sock"

        try? FileManager.default.removeItem(atPath: gotoSplitPath)
        try? FileManager.default.removeItem(atPath: keyequivPath)
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    func testCmdShiftPRoutesToPageWhenKeyboardCaptured() {
        let app = launchWithBrowserSetup()

        enterKeyboardCaptureMode(app)
        let baselineKeydownCount = pageKeydownCount()
        let baselinePaletteRequests = Int(loadKeyequiv()["commandPaletteCommandsRequests"] ?? "") ?? 0

        app.typeKey("p", modifierFlags: [.command, .shift])

        XCTAssertTrue(
            waitForDataMatch(timeout: 5.0) { data in
                let count = Int(data["browserKeyboardCapturePageKeydownCount"] ?? "") ?? 0
                return count >= baselineKeydownCount + 1 &&
                    (data["browserKeyboardCapturePageLastKey"] ?? "").lowercased() == "p" &&
                    data["browserKeyboardCapturePageLastMeta"] == "true" &&
                    data["browserKeyboardCapturePageLastShift"] == "true"
            },
            "Expected Cmd+Shift+P to reach the page while keyboard capture is active. data=\(String(describing: loadData()))"
        )

        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(
            Int(loadKeyequiv()["commandPaletteCommandsRequests"] ?? "") ?? 0,
            baselinePaletteRequests,
            "Expected Cmd+Shift+P to bypass cmux command palette while keyboard capture is active. keyequiv=\(loadKeyequiv())"
        )
    }

    func testEscapeTwiceExitsAndRestoresCmuxShortcuts() {
        let app = launchWithBrowserSetup()

        enterKeyboardCaptureMode(app)
        let baselineKeydownCount = pageKeydownCount()

        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])

        XCTAssertTrue(
            waitForKeyequivMatch(timeout: 5.0) { data in
                data["browserKeyboardCaptureActive"] == "1" &&
                    data["browserKeyboardCaptureExitArmed"] == "1"
            },
            "Expected first Esc to arm keyboard-capture exit. keyequiv=\(loadKeyequiv())"
        )

        XCTAssertTrue(
            waitForDataMatch(timeout: 5.0) { data in
                let count = Int(data["browserKeyboardCapturePageKeydownCount"] ?? "") ?? 0
                return count >= baselineKeydownCount + 1 &&
                    (data["browserKeyboardCapturePageLastKey"] ?? "") == "Escape"
            },
            "Expected first Esc to still reach the page while capture stays active. data=\(String(describing: loadData()))"
        )

        let afterFirstEscapeCount = pageKeydownCount()
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])

        XCTAssertTrue(
            waitForKeyequivMatch(timeout: 5.0) { data in
                data["browserKeyboardCaptureActive"] == "0" &&
                    data["browserKeyboardCaptureExitArmed"] != "1"
            },
            "Expected second Esc to release keyboard capture. keyequiv=\(loadKeyequiv())"
        )

        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(
            pageKeydownCount(),
            afterFirstEscapeCount,
            "Expected second Esc to be consumed by cmux instead of the page"
        )

        let baselinePaletteRequests = Int(loadKeyequiv()["commandPaletteCommandsRequests"] ?? "") ?? 0
        app.typeKey("p", modifierFlags: [.command, .shift])
        XCTAssertTrue(
            waitForKeyequivMatch(timeout: 5.0) { data in
                let requests = Int(data["commandPaletteCommandsRequests"] ?? "") ?? 0
                return requests >= baselinePaletteRequests + 1
            },
            "Expected Cmd+Shift+P to route back to cmux command palette after exiting capture mode. keyequiv=\(loadKeyequiv())"
        )
    }

    func testPaneNavigationShortcutDoesNotMoveFocusWhenKeyboardCaptured() {
        let app = launchWithBrowserSetup(enableFocusShortcuts: true)

        guard let setup = loadData() else {
            XCTFail("Missing goto_split setup data")
            return
        }
        guard let expectedBrowserPaneId = setup["browserPaneId"], !expectedBrowserPaneId.isEmpty else {
            XCTFail("Missing browserPaneId in goto_split setup data")
            return
        }

        enterKeyboardCaptureMode(app)
        let baselineKeydownCount = pageKeydownCount()

        app.typeKey("h", modifierFlags: [.command, .control])

        XCTAssertTrue(
            waitForDataMatch(timeout: 5.0) { data in
                let count = Int(data["browserKeyboardCapturePageKeydownCount"] ?? "") ?? 0
                return count >= baselineKeydownCount + 1 &&
                    (data["browserKeyboardCapturePageLastKey"] ?? "").lowercased() == "h" &&
                    data["browserKeyboardCapturePageLastMeta"] == "true" &&
                    data["browserKeyboardCapturePageLastControl"] == "true"
            },
            "Expected Cmd+Ctrl+H to stay in the page while capture is active. data=\(String(describing: loadData()))"
        )

        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let snapshot = loadData() ?? [:]
        XCTAssertEqual(
            snapshot["focusedPaneId"],
            expectedBrowserPaneId,
            "Expected browser pane focus to remain unchanged while capture is active. data=\(snapshot)"
        )
        XCTAssertNotEqual(
            snapshot["lastMoveDirection"],
            "left",
            "Expected pane-navigation shortcut to be suppressed while capture is active. data=\(snapshot)"
        )
    }

    func testBracketWorkspaceAndSurfaceShortcutsRouteToPageWhenKeyboardCaptured() {
        let app = launchWithBrowserSetup()

        guard let setup = loadData() else {
            XCTFail("Missing goto_split setup data")
            return
        }
        guard let expectedBrowserPaneId = setup["browserPaneId"], !expectedBrowserPaneId.isEmpty else {
            XCTFail("Missing browserPaneId in goto_split setup data")
            return
        }

        enterKeyboardCaptureMode(app)

        for probe in bracketShortcutProbes() {
            let baselineKeydownCount = pageKeydownCount()
            app.typeKey(probe.key, modifierFlags: probe.modifiers)

            XCTAssertTrue(
                waitForDataMatch(timeout: 5.0) { data in
                    let count = Int(data["browserKeyboardCapturePageKeydownCount"] ?? "") ?? 0
                    return count >= baselineKeydownCount + 1 &&
                        data["browserKeyboardCapturePageLastMeta"] == "true" &&
                        data["browserKeyboardCapturePageLastShift"] == (probe.expectShift ? "true" : "false") &&
                        data["browserKeyboardCapturePageLastControl"] == (probe.expectControl ? "true" : "false")
                },
                "Expected \(probe.name) to reach the page while keyboard capture is active. data=\(String(describing: loadData()))"
            )

            let snapshot = loadData() ?? [:]
            XCTAssertEqual(
                snapshot["focusedPaneId"],
                expectedBrowserPaneId,
                "Expected browser pane focus to remain unchanged for \(probe.name). data=\(snapshot)"
            )
        }
    }

    private func launchWithBrowserSetup(enableFocusShortcuts: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = gotoSplitPath
        app.launchEnvironment["CMUX_UI_TEST_KEYEQUIV_PATH"] = keyequivPath
        app.launchEnvironment["CMUX_UI_TEST_BROWSER_KEY_CAPTURE_SETUP"] = "1"
        if enableFocusShortcuts {
            app.launchEnvironment["CMUX_UI_TEST_FOCUS_SHORTCUTS"] = "1"
        }
        app.launch()

        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch in foreground. state=\(app.state.rawValue)"
        )

        XCTAssertTrue(
            waitForData(
                keys: [
                    "browserPanelId",
                    "browserPaneId",
                    "terminalPaneId",
                    "webViewFocused",
                    "browserKeyboardCapturePageTrackerInstalled"
                ],
                timeout: 12.0
            ),
            "Expected browser setup and page key tracker to be written"
        )

        guard let setup = loadData() else {
            XCTFail("Missing goto_split setup data")
            return app
        }

        XCTAssertEqual(setup["webViewFocused"], "true", "Expected WKWebView to be first responder for this test")
        XCTAssertEqual(
            setup["browserKeyboardCapturePageTrackerInstalled"],
            "true",
            "Expected page keyboard tracker to be installed"
        )

        return app
    }

    private func enterKeyboardCaptureMode(_ app: XCUIApplication) {
        let button = app.buttons["BrowserKeyboardCaptureButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 5.0), "Expected keyboard capture button to exist")
        button.click()

        XCTAssertTrue(
            waitForKeyequivMatch(timeout: 5.0) { data in
                data["browserKeyboardCaptureActive"] == "1" &&
                    data["browserKeyboardCaptureExitArmed"] != "1"
            },
            "Expected keyboard capture mode to become active. keyequiv=\(loadKeyequiv())"
        )
    }

    private func pageKeydownCount() -> Int {
        Int(loadData()?["browserKeyboardCapturePageKeydownCount"] ?? "") ?? 0
    }

    private struct BracketShortcutProbe {
        let name: String
        let key: String
        let modifiers: XCUIElement.KeyModifierFlags
        let expectShift: Bool
        let expectControl: Bool
    }

    private func bracketShortcutProbes() -> [BracketShortcutProbe] {
        [
            BracketShortcutProbe(
                name: "Cmd+Shift+[",
                key: "[",
                modifiers: [.command, .shift],
                expectShift: true,
                expectControl: false
            ),
            BracketShortcutProbe(
                name: "Cmd+Shift+]",
                key: "]",
                modifiers: [.command, .shift],
                expectShift: true,
                expectControl: false
            ),
            BracketShortcutProbe(
                name: "Cmd+Ctrl+[",
                key: "[",
                modifiers: [.command, .control],
                expectShift: false,
                expectControl: true
            ),
            BracketShortcutProbe(
                name: "Cmd+Ctrl+]",
                key: "]",
                modifiers: [.command, .control],
                expectShift: false,
                expectControl: true
            )
        ]
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

    private func waitForKeyequivMatch(timeout: TimeInterval, predicate: ([String: String]) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let data = loadKeyequiv()
            if predicate(data) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return predicate(loadKeyequiv())
    }

    private func loadData() -> [String: String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: gotoSplitPath)) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
    }

    private func loadKeyequiv() -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: keyequivPath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }
}
