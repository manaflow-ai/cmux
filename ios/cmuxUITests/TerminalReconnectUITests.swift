import XCTest

final class TerminalReconnectUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testDirectDaemonReconnectRecovers() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UITEST_TERMINAL_DIRECT_FIXTURE"] = "1"
        app.launchEnvironment["CMUX_UITEST_TERMINAL_RECONNECT_DELAY"] = "0.2"
        app.launch()

        let serverButton = app.buttons["terminal.server.cmux-macmini"]
        XCTAssertTrue(serverButton.waitForExistence(timeout: 6))
        serverButton.tap()

        XCTAssertTrue(app.navigationBars["Mac mini"].waitForExistence(timeout: 4))

        XCTAssertTrue(
            app.staticTexts["reconnected"].waitForExistence(timeout: 12),
            "Expected terminal transport notice after daemon reconnect"
        )
    }
}
