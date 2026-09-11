import XCTest

final class SettingsComputersBehaviorUITests: SettingsUITestCase {
    func testComputersSectionShowsIndependentDiscoveryAndAccessControls() {
        let app = makeLaunchedApp()
        let window = openSettings(app)
        defer { closeSettings(app, window) }

        let before = XCTAttachment(screenshot: window.screenshot())
        before.name = "Settings before opening Computers"
        before.lifetime = .keepAlways
        add(before)

        navigate(window, to: "Computers")

        let options = window.descendants(matching: .any)["SettingsComputersOptions"].firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        XCTAssertTrue(window.buttons["SettingsComputersRefresh"].exists)
        XCTAssertFalse(window.textFields["SettingsComputersPairingInput"].exists)

        let after = XCTAttachment(screenshot: window.screenshot())
        after.name = "Computers list with compact options"
        after.lifetime = .keepAlways
        add(after)

        options.click()
        XCTAssertTrue(app.descendants(matching: .any)["SettingsComputersEnabled"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["SettingsComputersDiscoveryToggle"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["SettingsComputersIncomingAccessToggle"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }
}
