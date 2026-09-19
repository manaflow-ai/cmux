import XCTest

final class SidebarFontFamilySettingsUITests: SettingsUITestCase {
    private var testApp: XCUIApplication?
    private var isolatedHome: URL?

    override func tearDown() {
        testApp?.terminate()
        if let isolatedHome { try? FileManager.default.removeItem(at: isolatedHome) }
        super.tearDown()
    }

    func testFamilyPersistsAfterLeavingFieldWithoutReturn() throws {
        let app = try launchIsolatedApp()
        let window = openSettings(app)
        let field = familyField(in: window)
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Menlo")
        XCTAssertEqual(field.value as? String, "Menlo")
        let search = requireElement(
            candidates: [window.searchFields.firstMatch, window.textFields["Search"]],
            timeout: 5,
            description: "Settings search field"
        )
        search.click()

        assertPersistedFamily("Menlo", afterRelaunching: app)
    }

    func testFamilyPersistsWhenSettingsCloseWithoutReturn() throws {
        let app = try launchIsolatedApp()
        let window = openSettings(app)
        let field = familyField(in: window)
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Courier New")
        XCTAssertEqual(field.value as? String, "Courier New")
        closeSettings(app, window)

        assertPersistedFamily("Courier New", afterRelaunching: app)
    }

    private func launchIsolatedApp() throws -> XCUIApplication {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarFontFamily-\(UUID().uuidString)", isDirectory: true)
        let config = home.appendingPathComponent(".config/cmux", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: config.appendingPathComponent("cmux.json"))
        isolatedHome = home

        let app = XCUIApplication.cmuxTestApplication()
        testApp = app
        app.launchArguments += settingsLaunchArguments
        app.launchArguments += ["-confirmQuit", "never", "-warnBeforeQuitShortcut", "NO"]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["HOME"] = home.path
        app.launchEnvironment["CFFIXED_USER_HOME"] = home.path
        app.launchEnvironment["XDG_CONFIG_HOME"] = home.appendingPathComponent(".config").path
        launchAndActivate(app)
        return app
    }

    private func familyField(in window: XCUIElement) -> XCUIElement {
        navigate(window, to: "Sidebar")
        let field = window.textFields["SettingsSidebarFontFamilyField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(poll(timeout: 5) { field.isHittable })
        return field
    }

    private func assertPersistedFamily(_ expected: String, afterRelaunching app: XCUIApplication) {
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "Quit did not terminate the app")
        launchAndActivate(app)
        let field = familyField(in: openSettings(app))
        XCTAssertTrue(
            poll(timeout: 5) { field.value as? String == expected },
            "Expected persisted family \(expected), got \(String(describing: field.value))"
        )
    }
}
