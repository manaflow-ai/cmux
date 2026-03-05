import XCTest

final class AppLaunchSmokeUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testAppLaunchesWithMainWindow() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launch()
        app.activate()

        XCTAssertTrue(
            waitForWindowCount(app: app, atLeast: 1, timeout: 10.0),
            "App should open at least one window on launch"
        )
    }

    func testAppLaunchesWithSidebar() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launch()
        app.activate()

        XCTAssertTrue(
            waitForWindowCount(app: app, atLeast: 1, timeout: 10.0),
            "App should open at least one window on launch"
        )

        // The sidebar outline (workspace list) should be present
        let sidebar = app.outlines.firstMatch
        XCTAssertTrue(
            sidebar.waitForExistence(timeout: 6.0),
            "Sidebar outline should exist after launch"
        )
    }

    private func waitForWindowCount(app: XCUIApplication, atLeast count: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.windows.count >= count { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return app.windows.count >= count
    }
}
