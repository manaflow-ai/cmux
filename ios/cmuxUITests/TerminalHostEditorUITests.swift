import XCTest

final class TerminalHostEditorUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testSetupFixtureSavesConfiguredHost() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UITEST_TERMINAL_SETUP_FIXTURE"] = "1"
        app.launchEnvironment["CMUX_UITEST_TERMINAL_SETUP_SAVE_ONLY"] = "1"
        app.launch()

        let serverButton = app.buttons["terminal.server.cmux-setup"]
        XCTAssertTrue(serverButton.waitForExistence(timeout: 6), "Expected setup fixture server pin")
        serverButton.tap()

        let hostnameField = app.textFields["terminal.hostEditor.hostname"]
        XCTAssertTrue(hostnameField.waitForExistence(timeout: 4), "Expected hostname field")
        hostnameField.tap()
        hostnameField.typeText("cmux-macmini")

        let usernameField = app.textFields["terminal.hostEditor.username"]
        XCTAssertTrue(usernameField.waitForExistence(timeout: 2), "Expected username field")
        usernameField.tap()
        usernameField.typeText("cmux")

        let passwordField = app.secureTextFields["terminal.hostEditor.password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 2), "Expected password field")
        passwordField.tap()
        passwordField.typeText("fixture")

        let saveButton = app.buttons["terminal.hostEditor.save"]
        XCTAssertTrue(saveButton.isEnabled, "Expected host editor save button")
        saveButton.tap()

        XCTAssertTrue(waitForDisappearance(of: app.otherElements["terminal.hostEditor"], timeout: 6), "Expected host editor to dismiss after save")

        let configuredServerButton = app.buttons["terminal.server.cmux-setup"]
        XCTAssertTrue(configuredServerButton.waitForExistence(timeout: 6), "Expected saved host to remain in the server list")
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return !element.exists
    }
}
