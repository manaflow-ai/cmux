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

        XCTAssertTrue(window.descendants(matching: .any)["SettingsComputersEnabled"].waitForExistence(timeout: 5))
        XCTAssertTrue(window.descendants(matching: .any)["SettingsComputersDiscoveryToggle"].exists)
        XCTAssertTrue(window.descendants(matching: .any)["SettingsComputersIncomingAccessToggle"].exists)
        XCTAssertTrue(window.buttons["SettingsComputersRefresh"].exists)
        XCTAssertFalse(window.textFields["SettingsComputersPairingInput"].exists)

        let after = XCTAttachment(screenshot: window.screenshot())
        after.name = "Computers discovery and access controls"
        after.lifetime = .keepAlways
        add(after)
    }
}
