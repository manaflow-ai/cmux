import XCTest

final class TerminalHomeUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testDirectFixtureOpensTerminalWorkspaceDetail() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UITEST_TERMINAL_DIRECT_FIXTURE"] = "1"
        app.launch()

        let serverButton = app.buttons["terminal.server.cmux-macmini"]
        XCTAssertTrue(serverButton.waitForExistence(timeout: 6), "Expected direct fixture server pin")
        serverButton.tap()

        XCTAssertTrue(app.navigationBars["Mac mini"].waitForExistence(timeout: 4), "Expected workspace title")
        XCTAssertTrue(app.otherElements["terminal.workspace.detail"].waitForExistence(timeout: 4), "Expected terminal workspace detail")
    }

    func testDiscoveredFixtureOpensWorkspaceInsteadOfHostEditor() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UITEST_TERMINAL_DISCOVERED_FIXTURE"] = "1"
        app.launch()

        let serverButton = app.buttons["terminal.server.machine-macmini-live"]
        XCTAssertTrue(serverButton.waitForExistence(timeout: 6), "Expected discovered machine server pin")
        serverButton.tap()

        XCTAssertFalse(
            app.otherElements["terminal.hostEditor"].waitForExistence(timeout: 1),
            "Expected discovered machine tap to skip the host editor"
        )
        XCTAssertTrue(app.navigationBars["Mac mini"].waitForExistence(timeout: 4), "Expected workspace title")
        XCTAssertTrue(app.otherElements["terminal.workspace.detail"].waitForExistence(timeout: 4), "Expected terminal workspace detail")
    }
}
