import XCTest

private func sidebarHelpPollUntil(
    timeout: TimeInterval,
    pollInterval: TimeInterval = 0.05,
    condition: () -> Bool
) -> Bool {
    let start = ProcessInfo.processInfo.systemUptime
    while true {
        if condition() {
            return true
        }
        if (ProcessInfo.processInfo.systemUptime - start) >= timeout {
            return false
        }
        RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
    }
}

final class SidebarHelpMenuUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testHelpMenuOpensKeyboardShortcutsSection() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        launchAndActivate(app)

        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: app, timeout: 6.0))

        let helpButton = app.buttons["SidebarHelpMenuButton"]
        XCTAssertTrue(helpButton.waitForExistence(timeout: 6.0))
        helpButton.click()

        let keyboardShortcutsItem = app.buttons["SidebarHelpMenuOptionKeyboardShortcuts"]
        XCTAssertTrue(keyboardShortcutsItem.waitForExistence(timeout: 3.0))
        keyboardShortcutsItem.click()

        XCTAssertTrue(app.staticTexts["Click a shortcut value to record a new shortcut."].waitForExistence(timeout: 6.0))
    }

    func testHelpMenuCheckForUpdatesTriggersSidebarUpdatePill() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_FEED_URL"] = "https://cmux.test/appcast.xml"
        app.launchEnvironment["CMUX_UI_TEST_FEED_MODE"] = "available"
        app.launchEnvironment["CMUX_UI_TEST_UPDATE_VERSION"] = "9.9.9"
        app.launchEnvironment["CMUX_UI_TEST_AUTO_ALLOW_PERMISSION"] = "1"
        launchAndActivate(app)

        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: app, timeout: 6.0))

        let helpButton = app.buttons["SidebarHelpMenuButton"]
        XCTAssertTrue(helpButton.waitForExistence(timeout: 6.0))
        helpButton.click()

        let checkForUpdatesItem = app.buttons["SidebarHelpMenuOptionCheckForUpdates"]
        XCTAssertTrue(checkForUpdatesItem.waitForExistence(timeout: 3.0))
        checkForUpdatesItem.click()

        let updatePill = app.buttons["Update Available: 9.9.9"]
        XCTAssertTrue(updatePill.waitForExistence(timeout: 6.0))
    }

    private func waitForWindowCount(atLeast count: Int, app: XCUIApplication, timeout: TimeInterval) -> Bool {
        sidebarHelpPollUntil(timeout: timeout) {
            app.windows.count >= count
        }
    }

    private func launchAndActivate(_ app: XCUIApplication, activateTimeout: TimeInterval = 2.0) {
        app.launch()
        let activated = sidebarHelpPollUntil(timeout: activateTimeout) {
            guard app.state != .runningForeground else {
                return true
            }
            app.activate()
            return app.state == .runningForeground
        }
        if !activated {
            app.activate()
        }
    }
}
