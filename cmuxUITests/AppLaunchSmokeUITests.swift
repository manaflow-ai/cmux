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

    func testAppWindowHasNonZeroSize() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launch()
        app.activate()

        XCTAssertTrue(
            waitForWindowCount(app: app, atLeast: 1, timeout: 10.0),
            "App should open at least one window on launch"
        )

        let window = app.windows.firstMatch
        XCTAssertTrue(window.frame.width > 100, "Window should have reasonable width")
        XCTAssertTrue(window.frame.height > 100, "Window should have reasonable height")
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
