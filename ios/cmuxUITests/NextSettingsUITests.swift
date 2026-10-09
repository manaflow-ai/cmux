import XCTest

/// Settings (c11-settings.md, c16-platform.md): every page opens from the
/// Settings tab on the mock device registry.
@MainActor
final class NextSettingsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launchSettings(extra: [String: String] = [:]) -> XCUIApplication {
        let app = NextUITest.launchShell(tab: "settings", extra: extra)
        NextUITest.assertTabRoot(app, "settings")
        return app
    }

    private func open(_ row: String, expect: String, in app: XCUIApplication,
                      file: StaticString = #filePath, line: UInt = #line) {
        NextUITest.tap(app, row, scroll: true, file: file, line: line)
        XCTAssertTrue(NextUITest.element(app, expect).waitForExistence(timeout: 10),
                      "\(row) did not show \(expect)", file: file, line: line)
    }

    func testAccountAndVersion() {
        let app = launchSettings()
        XCTAssertTrue(NextUITest.element(app, "shell.settings.profile").waitForExistence(timeout: 10))
        XCTAssertTrue(NextUITest.scrollTo(NextUITest.element(app, "shell.settings.version"), in: app), "no version row")
    }

    func testDeviceDetail() {
        let app = launchSettings()
        open("shell.settings.device.dev-phone", expect: "shell.settings.deviceName", in: app)
    }

    func testTerminalPage() {
        let app = launchSettings()
        open("shell.settings.terminal", expect: "shell.settings.terminal.theme", in: app)
        XCTAssertTrue(NextUITest.element(app, "shell.settings.terminal.fontSize").exists)
    }

    func testNotificationsPage() {
        let app = launchSettings()
        NextUITest.tap(app, "shell.settings.notifications", scroll: true)
        XCTAssertTrue(NextUITest.element(app, prefix: "shell.settings.notify.").waitForExistence(timeout: 10))
    }

    func testPrivacyPage() {
        let app = launchSettings()
        open("shell.settings.privacy", expect: "shell.settings.privacy.crashReports", in: app)
    }

    func testWhatsNewPage() {
        let app = launchSettings()
        NextUITest.tap(app, "shell.settings.whatsNew", scroll: true)
        XCTAssertTrue(app.navigationBars["What's New"].waitForExistence(timeout: 10))
    }

    func testDeveloperSources() {
        let app = launchSettings()
        open("shell.settings.developer", expect: "shell.dev.source.feed", in: app)
        XCTAssertTrue(NextUITest.scrollTo(NextUITest.element(app, "shell.dev.mockOffline"), in: app))
    }

    /// App Review demo mode (`CMUX_IOS_DEMO=1`) adds the Demo page.
    func testDemoModeAddsDemoPage() {
        let app = launchSettings(extra: ["CMUX_IOS_DEMO": "1"])
        XCTAssertTrue(NextUITest.scrollTo(NextUITest.element(app, "shell.settings.demo"), in: app), "no Demo row in demo mode")
    }

    /// Replay Welcome Tour presents onboarding over the shell.
    func testReplayTour() {
        let app = launchSettings()
        open("shell.settings.replayTour", expect: "onboarding.progress", in: app)
    }
}
