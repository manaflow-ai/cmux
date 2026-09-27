import XCTest

extension UpdatePillUITests {
    func testAttemptUpdateShowsStatusPillInMinimalMode() {
        let systemSettings = XCUIApplication(bundleIdentifier: "com.apple.systempreferences")
        systemSettings.terminate()
        let app = XCUIApplication.cmuxTestApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        // Command-line defaults make the minimal presentation active before the
        // first window mounts, matching the user's persistent setting.
        app.launchArguments += ["-workspacePresentationMode", "minimal"]
        launchAndActivate(app)
        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: app, timeout: 6.0))

        app.typeKey("p", modifierFlags: [.command, .shift])
        app.typeText("Attempt Update")
        app.typeKey(.return, modifierFlags: [])

        let upToDatePill = pillButton(app: app, expectedLabel: "No Updates Available")
        XCTAssertTrue(
            upToDatePill.waitForExistence(timeout: 10.0),
            "Attempt Update should briefly surface its result in minimal mode"
        )
        assertVisibleSize(upToDatePill)
    }

}
