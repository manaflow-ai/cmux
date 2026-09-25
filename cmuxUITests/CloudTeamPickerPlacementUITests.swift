import XCTest

final class CloudTeamPickerPlacementUITests: XCTestCase {
    func testAccountFooterDoesNotOfferTeamPickerAndCloudHeaderDoes() {
        let app = launchSignedInApp()
        defer { app.terminate() }
        let accountButton = app.buttons["SidebarAccountMenuButton"]
        XCTAssertTrue(accountButton.waitForExistence(timeout: 10))
        accountButton.click()
        XCTAssertTrue(app.buttons["SidebarAccountSignOutButton"].waitForExistence(timeout: 5))
        capture("account-popover")
        XCTAssertFalse(
            app.buttons["SidebarAccountTeamPickerButton"].waitForExistence(timeout: 2),
            "The local account popover must not offer team switching."
        )
        XCTAssertFalse(app.buttons["SidebarAccountCreateTeamButton"].exists)

        let cloudMode = app.buttons["RightSidebarModeButton.machines"]
        XCTAssertTrue(cloudMode.waitForExistence(timeout: 10))
        cloudMode.click()
        capture("cloud-header")
        XCTAssertTrue(
            app.buttons["CloudTeamPickerButton"].waitForExistence(timeout: 10),
            "The signed-in Cloud header must offer team scope."
        )
    }

    private func launchSignedInApp() -> XCUIApplication {
        let app = XCUIApplication.cmuxTestApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UITEST_AUTH_FIXTURE"] = "1"
        app.launchEnvironment["CMUX_UITEST_AUTH_USER_ID"] = "team-picker-fixture"
        app.launchEnvironment["CMUX_UITEST_AUTH_NAME"] = "Team Picker Fixture"
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_SHOW_RIGHT_SIDEBAR"] = "1"
        app.launchArguments += [
            "-workspacePresentationMode", "minimal",
            "-cloud.beta.machines.enabled", "YES",
            "-cmux.flags.override.cloud-machines-enabled-release", "YES",
            "-cmux.flags.override.sidebar-account-button-enabled-release", "YES",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        return app
    }

    private func capture(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
