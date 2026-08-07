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
        runButton.click()

        let transportStage = window.staticTexts["Encrypted Transport"]
        XCTAssertTrue(
            poll(timeout: 12) { transportStage.exists },
            "Running the check should publish its encrypted-transport stage"
        )
        XCTAssertTrue(
            window.staticTexts["Relay Policy"].exists,
            "The result should distinguish relay policy from transport readiness"
        )
        XCTAssertTrue(
            window.staticTexts["Relay Reachability"].exists,
            "The result should distinguish network relay reachability"
        )
    }
}
