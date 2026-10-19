import XCTest

/// Behavioral coverage for the staged Iroh connection check in Settings.
final class SettingsNetworkingBehaviorUITests: SettingsUITestCase {
    func testNeverUseRelaysCanBeEnabledAndDisabled() {
        let app = makeLaunchedApp()
        let window = openSettings(app)
        defer { closeSettings(app, window) }

        navigate(window, to: "Networking")
        let toggle = requireElement(
            candidates: [
                window.switches["SettingsIrohNeverUseRelays"],
                window.descendants(matching: .any)["SettingsIrohNeverUseRelays"],
            ],
            timeout: 5,
            description: "Never Use Relays toggle"
        )

        if toggle.value as? String != "0" {
            toggle.click()
            XCTAssertTrue(poll(timeout: 5) { toggle.value as? String == "0" })
        }

        toggle.click()
        XCTAssertTrue(
            poll(timeout: 5) { toggle.value as? String == "1" },
            "Never Use Relays should persist the direct-only path preference"
        )

        toggle.click()
        XCTAssertTrue(
            poll(timeout: 5) { toggle.value as? String == "0" },
            "Disabling Never Use Relays should restore Automatic"
        )
    }

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
                    && window.descendants(matching: .any)["SettingsIrohConnectionCheckPath"].exists
                    && window.descendants(matching: .any)["SettingsIrohShareConnectionReport"].exists
            },
            "Running the check should publish its route, staged result, and safe support report"
        )
    }
}
