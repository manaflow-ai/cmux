import XCTest


final class FeedbackComposerShortcutUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testCmdOptionFOpensFeedbackComposer() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launch()
        app.activate()

        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 6.0) {
                app.windows.count >= 1
            }
        )

        app.typeKey("f", modifierFlags: [.command, .option])

        XCTAssertTrue(app.staticTexts["Send Feedback"].waitForExistence(timeout: 3.0))
        XCTAssertTrue(
            app.textFields["SidebarFeedbackEmailField"].waitForExistence(timeout: 2.0)
                || app.textFields["Your Email"].waitForExistence(timeout: 2.0)
        )
    }

    func testCmdOptionFWorksWithHiddenSidebar() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launch()
        app.activate()

        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 6.0) {
                app.windows.count >= 1
            }
        )

        app.typeKey("b", modifierFlags: [.command])

        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 3.0) {
                !app.buttons["SidebarHelpMenuButton"].exists && !app.buttons["Help"].exists
            }
        )

        app.typeKey("f", modifierFlags: [.command, .option])

        XCTAssertTrue(app.staticTexts["Send Feedback"].waitForExistence(timeout: 3.0))
    }

    func testCmdOptionFWorksFromSettingsWindow() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SHOW_SETTINGS"] = "1"
        app.launch()
        app.activate()

        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 6.0) {
                app.windows.count >= 2
            }
        )

        app.typeKey("f", modifierFlags: [.command, .option])

        XCTAssertTrue(app.staticTexts["Send Feedback"].waitForExistence(timeout: 3.0))
        XCTAssertTrue(
            app.textFields["SidebarFeedbackEmailField"].waitForExistence(timeout: 2.0)
                || app.textFields["Your Email"].waitForExistence(timeout: 2.0)
        )
    }
}

