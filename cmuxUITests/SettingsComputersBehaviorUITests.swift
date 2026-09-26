import XCTest

/// Devices is its own Settings section under Remote & Devices, right after
/// Mobile (https://github.com/manaflow-ai/cmux/issues/14771). It carries the
/// My Devices switches and the account's Macs, and a switch flipped there
/// persists. My Devices runs only while Cloud Machines is on, so the switches
/// are disabled, with the reason shown, while it is off. (Refresh is not
/// asserted there: the signed-out test app disables it regardless.)
final class SettingsComputersBehaviorUITests: SettingsUITestCase {
    private let discoveryKey = "devices.discovery.enabled"
    private let discoveryToggleID = "SettingsComputersDiscoveryToggle"
    private let incomingAccessToggleID = "SettingsComputersIncomingAccessToggle"
    private let cloudFlagKey = "cmux.flags.override.cloud-machines-enabled-release"
    private var savedCloudFlag: Any?

    override func setUp() {
        super.setUp()
        // Fresh installs leave discovery off; start every run from that default.
        resetDefaults([discoveryKey])
        // The flag reader accepts only a typed Boolean override; a launch
        // argument such as YES is a string and does not force the flag on.
        let defaults = UserDefaults(suiteName: "com.cmuxterm.app.debug")
        savedCloudFlag = defaults?.object(forKey: cloudFlagKey)
        defaults?.set(true, forKey: cloudFlagKey)
        defaults?.synchronize()
    }

    override func tearDown() {
        let defaults = UserDefaults(suiteName: "com.cmuxterm.app.debug")
        defaults?.set(savedCloudFlag, forKey: cloudFlagKey)
        defaults?.synchronize()
        resetDefaults([discoveryKey])
        super.tearDown()
    }

    func testDevicesSectionShowsDiscoveryAndAccessControls() {
        let app = makeLaunchedApp(additionalArguments: ["-cloud.beta.machines.enabled", "YES"])
        var window = openSettings(app)

        let before = XCTAttachment(screenshot: window.screenshot())
        before.name = "Settings before opening Devices"
        before.lifetime = .keepAlways
        add(before)

        let mobileRow = sidebarRow(window, "Mobile")
        let devicesRow = sidebarRow(window, "Devices")
        XCTAssertGreaterThan(devicesRow.frame.minY, mobileRow.frame.minY, "Devices should follow Mobile in the sidebar")

        navigate(window, to: "Devices")
        let discovery = toggle(window, id: discoveryToggleID)
        XCTAssertTrue(toggle(window, id: incomingAccessToggleID).exists)
        XCTAssertTrue(window.descendants(matching: .any)["SettingsComputersHeading"].exists)
        XCTAssertTrue(window.buttons["SettingsComputersRefresh"].exists)
        XCTAssertTrue(poll(timeout: 4) { discovery.isHittable }, "navigating to Devices should scroll its switches into view")

        let after = XCTAttachment(screenshot: window.screenshot())
        after.name = "Devices section with discovery and access switches"
        after.lifetime = .keepAlways
        add(after)

        XCTAssertTrue(poll(timeout: 4) { discovery.isEnabled }, "Discover other Macs should be switchable while Cloud Machines is on")
        XCTAssertTrue(poll(timeout: 4) { !self.isToggleOn(discovery) }, "Discover other Macs should start off")
        discovery.click()
        XCTAssertTrue(poll(timeout: 4) { self.isToggleOn(discovery) }, "Discover other Macs should read on after a click")

        // The switch writes the shared My Devices preference, so a fresh
        // Settings window reads the new value back.
        closeSettings(app, window)
        window = openSettings(app)
        defer { closeSettings(app, window) }
        navigate(window, to: "Devices")
        let reopened = toggle(window, id: discoveryToggleID)
        XCTAssertTrue(poll(timeout: 4) { self.isToggleOn(reopened) }, "Discover other Macs should stay on after reopening Settings")
    }

    func testDevicesSwitchesAreDisabledWhileCloudMachinesIsOff() {
        let app = makeLaunchedApp(additionalArguments: ["-cloud.beta.machines.enabled", "NO"])
        let window = openSettings(app)
        defer { closeSettings(app, window) }

        navigate(window, to: "Devices")
        let discovery = toggle(window, id: discoveryToggleID)
        let incomingAccess = toggle(window, id: incomingAccessToggleID)
        // Match the note's own wording: "Beta Features" alone also matches
        // the sidebar row and would pass without the note.
        let reason = window.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", "Turn on Cloud Machines", "Turn on Cloud Machines"))
            .firstMatch
        XCTAssertTrue(reason.waitForExistence(timeout: 4), "Devices should say to turn on Cloud Machines in Beta Features")

        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = "Devices section while Cloud Machines is off"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        XCTAssertTrue(poll(timeout: 4) { !discovery.isEnabled }, "Discover other Macs should be disabled while Cloud Machines is off")
        XCTAssertTrue(poll(timeout: 4) { !incomingAccess.isEnabled }, "Make this Mac discoverable should be disabled while Cloud Machines is off")
    }

    private func sidebarRow(_ window: XCUIElement, _ title: String) -> XCUIElement {
        requireElement(
            candidates: [window.cells.containing(.staticText, identifier: title).firstMatch, window.staticTexts[title]],
            timeout: 5,
            description: "\(title) sidebar row"
        )
    }

    /// Reads a SwiftUI `Toggle`'s state across the control kinds it can
    /// surface as in XCUITest.
    private func isToggleOn(_ element: XCUIElement) -> Bool {
        if let value = element.value as? String { return value == "1" }
        if let value = element.value as? Bool { return value }
        return element.isSelected
    }
}
