import XCTest

private func settingsWindowPollUntil(
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

final class SettingsWindowUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testSettingsSearchFindsBrowserCategory() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SHOW_SETTINGS"] = "1"
        launchAndActivate(app)

        let searchField = requireElement(
            candidates: [
                app.textFields["SettingsSearchField"],
                app.searchFields["SettingsSearchField"],
            ],
            timeout: 8.0,
            description: "settings search field"
        )
        searchField.click()
        searchField.typeText("browser")

        let browserCategoryButton = app.buttons["SettingsCategoryButton-browser"]
        XCTAssertTrue(browserCategoryButton.waitForExistence(timeout: 4.0))
        XCTAssertFalse(app.buttons["SettingsCategoryButton-general"].exists)

        browserCategoryButton.click()

        XCTAssertTrue(
            app.buttons["SettingsBrowserHTTPAllowlistSaveButton"].waitForExistence(timeout: 6.0),
            "Expected browser settings pane to become visible after selecting Browser category"
        )
    }

    private func requireElement(
        candidates: [XCUIElement],
        timeout: TimeInterval,
        description: String
    ) -> XCUIElement {
        guard let element = firstExistingElement(candidates: candidates, timeout: timeout) else {
            XCTFail("Expected \(description) to exist")
            return candidates[0]
        }
        return element
    }

    private func firstExistingElement(
        candidates: [XCUIElement],
        timeout: TimeInterval
    ) -> XCUIElement? {
        var match: XCUIElement?
        let found = settingsWindowPollUntil(timeout: timeout) {
            for candidate in candidates where candidate.exists {
                match = candidate
                return true
            }
            return false
        }
        return found ? match : nil
    }

    private func launchAndActivate(_ app: XCUIApplication, activateTimeout: TimeInterval = 2.0) {
        app.launch()
        let activated = settingsWindowPollUntil(timeout: activateTimeout) {
            guard app.state != .runningForeground else {
                return true
            }
            app.activate()
            return app.state == .runningForeground
        }
        if !activated {
            app.activate()
        }
        XCTAssertTrue(
            settingsWindowPollUntil(timeout: 2.0) { app.state == .runningForeground },
            "App did not reach runningForeground before UI interactions"
        )
    }
}
