import XCTest

/// Behavioral coverage for the staged Iroh connection check in Settings.
final class SettingsNetworkingBehaviorUITests: SettingsUITestCase {
    func testConnectionCheckPublishesAStagedResult() {
        let app = makeLaunchedApp()
        let window = openSettings(app)
        defer { closeSettings(app, window) }

        navigate(window, to: "Networking")
        let runButton = requireElement(
            candidates: [
                window.buttons["SettingsIrohRunConnectionCheck"],
                window.descendants(matching: .any)["SettingsIrohRunConnectionCheck"],
            ],
            timeout: 5,
            description: "Iroh connection check button"
        )
        // The check reads signed policy, diagnostics, and live Iroh path hints.
        // It does not dial configured relay URLs from this UI test.
        runButton.click()

        XCTAssertTrue(
            poll(timeout: 12) {
                window.staticTexts["Encrypted Transport"].exists
                    && window.staticTexts["Relay Policy"].exists
                    && window.staticTexts["Relay Reachability"].exists
            },
            "Running the check should publish transport, relay policy, and relay reachability stages"
        )
    }
}
