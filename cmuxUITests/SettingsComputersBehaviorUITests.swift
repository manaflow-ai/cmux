import XCTest

final class SettingsComputersBehaviorUITests: SettingsUITestCase {
    func testComputersSectionShowsPairingPreconditions() {
        let app = makeLaunchedApp()
        let window = openSettings(app)
        defer { closeSettings(app, window) }

        let before = XCTAttachment(screenshot: window.screenshot())
        before.name = "Settings before opening Computers"
        before.lifetime = .keepAlways
        add(before)

        navigate(window, to: "Computers")

        XCTAssertTrue(window.textFields["SettingsComputersPairingInput"].waitForExistence(timeout: 5))
        XCTAssertTrue(window.buttons["SettingsComputersPair"].exists)
        XCTAssertFalse(window.buttons["SettingsComputersPair"].isEnabled, "An empty pairing input must not start a pairing request")
        XCTAssertTrue(window.buttons["SettingsComputersShowPairing"].exists)

        let after = XCTAttachment(screenshot: window.screenshot())
        after.name = "Computers pairing controls"
        after.lifetime = .keepAlways
        add(after)
    }
}
