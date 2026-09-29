import XCTest

/// Exercises the shared preference actions from Settings and the visible sidebar controls.
final class DeviceDiscoverabilityUITests: SettingsUITestCase {
    private let incomingKey = "devices.incomingAccess.enabled"
    private let discoveryKey = "devices.discovery.enabled"
    override func setUp() {
        super.setUp()
        resetDefaults([incomingKey, discoveryKey])
    }

    override func tearDown() {
        resetDefaults([incomingKey, discoveryKey])
        super.tearDown()
    }

    func testSettingsConfirmsOnlyIncomingEnableAndPersistsBothChoices() {
        let app = launchDevicesApp()
        defer { app.terminate() }
        let window = openSettings(app)
        navigate(window, to: "Devices")
        let incoming = toggle(window, id: "SettingsComputersIncomingAccessToggle")
        let discovery = toggle(window, id: "SettingsComputersDiscoveryToggle")
        XCTAssertEqual(incoming.label, "Make this Mac discoverable")
        XCTAssertEqual(discovery.label, "Discover other Macs")

        incoming.click()
        assertConfirmation(app)
        capture(app, "discoverability-confirmation")
        app.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertFalse(isOn(incoming))

        incoming.click()
        assertConfirmation(app)
        app.sheets.buttons["Make Discoverable"].firstMatch.click()
        XCTAssertTrue(poll(timeout: 5) { self.isOn(incoming) })
        XCTAssertEqual(incoming.label, "Hide this Mac from My Devices")
        XCTAssertFalse(isOn(discovery))
        incoming.click()
        XCTAssertTrue(poll(timeout: 5) { !self.isOn(incoming) })
        XCTAssertFalse(app.sheets.firstMatch.exists)
        XCTAssertEqual(incoming.label, "Make this Mac discoverable")

        discovery.click()
        XCTAssertTrue(poll(timeout: 5) { self.isOn(discovery) })
        XCTAssertEqual(discovery.label, "Stop discovering other Macs")
        XCTAssertFalse(app.sheets.firstMatch.exists)
        closeSettings(app, window)
        let reopened = openSettings(app)
        navigate(reopened, to: "Devices")
        XCTAssertTrue(isOn(toggle(reopened, id: "SettingsComputersDiscoveryToggle")))
        XCTAssertFalse(isOn(toggle(reopened, id: "SettingsComputersIncomingAccessToggle")))
    }

    func testSidebarKeepsBothActionsAtRestAndAgreesWithSettings() {
        let app = launchDevicesApp()
        defer { app.terminate() }
        let mode = app.buttons["RightSidebarModeButton.machines"]
        XCTAssertTrue(mode.waitForExistence(timeout: 10))
        mode.click()
        let tree = app.descendants(matching: .any).matching(identifier: "CloudMachinesTree").firstMatch
        XCTAssertTrue(tree.waitForExistence(timeout: 10))
        let incoming = tree.buttons["DevicesEnableIncomingAccess"]
        let discovery = tree.buttons["DevicesEnableDiscovery"]
        XCTAssertTrue(incoming.waitForExistence(timeout: 5))
        XCTAssertTrue(discovery.waitForExistence(timeout: 5))
        XCTAssertTrue(incoming.isHittable && discovery.isHittable)
        XCTAssertEqual(incoming.label, "Make this Mac discoverable")
        XCTAssertEqual(discovery.label, "Discover other Macs")
        capture(app, "devices-controls-off-at-rest")

        incoming.click()
        assertConfirmation(app)
        // Escape is the native dialog's Cancel action.
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
        incoming.click()
        assertConfirmation(app)
        app.sheets.buttons["Make Discoverable"].firstMatch.click()
        XCTAssertTrue(poll(timeout: 5) { incoming.label == "Hide this Mac from My Devices" })
        discovery.click()
        XCTAssertTrue(poll(timeout: 5) { discovery.label == "Stop discovering other Macs" })
        XCTAssertFalse(app.sheets.firstMatch.exists)
        XCTAssertTrue(incoming.isHittable && discovery.isHittable)
        capture(app, "devices-controls-on-at-rest")

        let settings = openSettings(app)
        navigate(settings, to: "Devices")
        XCTAssertTrue(isOn(toggle(settings, id: "SettingsComputersIncomingAccessToggle")))
        XCTAssertTrue(isOn(toggle(settings, id: "SettingsComputersDiscoveryToggle")))
        closeSettings(app, settings)
        incoming.click()
        XCTAssertTrue(poll(timeout: 5) { incoming.label == "Make this Mac discoverable" })
        XCTAssertFalse(app.sheets.firstMatch.exists)
        discovery.click()
        XCTAssertTrue(poll(timeout: 5) { discovery.label == "Discover other Macs" })
        XCTAssertFalse(app.sheets.firstMatch.exists)
        XCTAssertTrue(incoming.isHittable && discovery.isHittable)
    }

    private func assertConfirmation(_ app: XCUIApplication) {
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.sheets.count, 1)
        XCTAssertTrue(app.sheets.staticTexts["Make this Mac discoverable?"].exists)
        XCTAssertTrue(app.sheets.staticTexts[
            "Other Macs signed in to your cmux account may discover this Mac and connect to its workspaces. Do you want to continue?"
        ].exists)
    }

    private func launchDevicesApp() -> XCUIApplication {
        let app = XCUIApplication.cmuxTestApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UITEST_AUTH_FIXTURE"] = "1"
        app.launchEnvironment["CMUX_UITEST_AUTH_USER_ID"] = "discoverability-fixture"
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_SHOW_RIGHT_SIDEBAR"] = "1"
        app.launchArguments += settingsLaunchArguments + [
            "-cmux.flags.override.cloud-machines-enabled-release", "<true/>",
            "-cloud.beta.machines.enabled", "<true/>",
            "-fileExplorer.isVisible", "YES",
            "-workspacePresentationMode", "standard",
            "-rightSidebar.mode", "files",
        ]
        app.launch()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 12))
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
