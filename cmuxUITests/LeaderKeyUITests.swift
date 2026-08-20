import XCTest

final class LeaderKeyUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launchTerminalApp(tag: String, dataPath: String? = nil) -> XCUIApplication {
        let app = XCUIApplication.cmuxTestApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments += ["-leaderKey.enabled", "YES", "-leaderKey.timeout", "2.0"]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = tag
        if let dataPath {
            app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
            app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
            app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_LAYOUT"] = "two_pane_terminal"
        }
        app.launch()
        XCTAssertTrue(app.waitForExistence(timeout: 8), "Expected cmux UI-test application")
        return app
    }

    private func recordedValue(_ key: String, at path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }
        return object[key]
    }

    private func waitForRecordedValue(_ key: String, equals value: String, at path: String, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if recordedValue(key, at: path) == value { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    func testCtrlBCreatesSurfaceInFocusedTerminal() {
        let app = launchTerminalApp(tag: "ui-leader-key")
        let terminalViews = app.textViews
        XCTAssertTrue(terminalViews.firstMatch.waitForExistence(timeout: 8), "Expected a real terminal first responder")
        let before = terminalViews.count
        terminalViews.firstMatch.click()
        app.typeKey("b", modifierFlags: [.control]); app.typeKey("c")
        let deadline = Date(timeIntervalSinceNow: 8)
        while terminalViews.count < before + 1, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertEqual(terminalViews.count, before + 1, "Ctrl-B C should create exactly one terminal surface")
    }

    func testCtrlBZTogglesFocusedPaneZoom() {
        let path = "/tmp/cmux-ui-leader-zoom-[1;2D\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: path)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let app = launchTerminalApp(tag: "ui-leader-zoom", dataPath: path)
        let terminal = app.textViews.firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 8), "Expected a real terminal first responder")
        terminal.click()
        app.typeKey("b", modifierFlags: [.control]); app.typeKey("z")
        XCTAssertTrue(waitForRecordedValue("splitZoomedAfterToggle", equals: "true", at: path), "Ctrl-B Z should record a zoomed split")
        app.typeKey("b", modifierFlags: [.control]); app.typeKey("z")
        XCTAssertTrue(waitForRecordedValue("splitZoomedAfterToggle", equals: "false", at: path), "A second Ctrl-B Z should record the same split unzoomed")
    }
}
