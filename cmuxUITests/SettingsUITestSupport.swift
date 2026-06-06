import XCTest

/// Shared base class for the Settings behavioral UI tests.
///
/// Every `Settings<Section>BehaviorUITests` subclass uses these helpers
/// to launch the app, open the Settings window, navigate sidebar
/// sections, and poll for conditions. The goal of the subclasses is
/// behavioral: change a setting, then drive the surface it affects and
/// assert the *effect* actually happened — not merely that the control
/// flipped.
class SettingsUITestCase: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Launch arguments forcing English + transient state so element
    /// labels are stable across machines.
    var settingsLaunchArguments: [String] {
        [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-ApplePersistenceIgnoreState", "YES",
            "-NSQuitAlwaysKeepsWindows", "NO",
            "-menuBarOnly", "false",
        ]
    }

    /// Sidebar section titles in top-to-bottom order. Must match
    /// `SettingsSectionID.title` default values.
    static let sectionTitles = [
        "Account", "App", "Terminal", "TextBox (Beta)", "Sidebar", "Beta Features", "Automation",
        "Browser", "Global Hotkey", "Keyboard Shortcuts", "Workspace Colors",
        "cmux.json", "Reset",
    ]

    // MARK: - Launch / window

    func makeLaunchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += settingsLaunchArguments
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        launchAndActivate(app)
        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: app, timeout: 8.0), "main window did not appear")
        return app
    }

    /// Opens the Settings window via ⌘, and returns it.
    @discardableResult
    func openSettings(_ app: XCUIApplication) -> XCUIElement {
        app.typeKey(",", modifierFlags: .command)
        let window = app.windows["Settings"]
        XCTAssertTrue(poll(timeout: 6.0) { window.exists }, "Settings window did not open")
        return window
    }

    func closeSettings(_ app: XCUIApplication, _ window: XCUIElement) {
        window.typeKey("w", modifierFlags: .command)
        _ = poll(timeout: 3.0) { !window.exists }
    }

    /// Clicks the sidebar row for `title`, scrolling the detail to that
    /// section. Tolerates the row appearing as a cell or a static text.
    func navigate(_ window: XCUIElement, to title: String) {
        let cell = window.cells.containing(.staticText, identifier: title).firstMatch
        let text = window.staticTexts[title]
        let target = requireElement(candidates: [cell, text], timeout: 4.0, description: "sidebar row \(title)")
        target.click()
        _ = poll(timeout: 1.0) { true }
    }

    // MARK: - Polling / element resolution

    func poll(timeout: TimeInterval, interval: TimeInterval = 0.05, _ condition: () -> Bool) -> Bool {
        let start = ProcessInfo.processInfo.systemUptime
        while true {
            if condition() { return true }
            if (ProcessInfo.processInfo.systemUptime - start) >= timeout { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(interval))
        }
    }

    func waitForWindowCount(atLeast count: Int, app: XCUIApplication, timeout: TimeInterval) -> Bool {
        poll(timeout: timeout) { app.windows.count >= count }
    }

    @discardableResult
    func requireElement(candidates: [XCUIElement], timeout: TimeInterval, description: String) -> XCUIElement {
        var match: XCUIElement?
        let found = poll(timeout: timeout) {
            for c in candidates where c.exists { match = c; return true }
            return false
        }
        XCTAssertTrue(found, "Expected \(description) to exist")
        return match ?? candidates[0]
    }

    /// Resolves a toggle by accessibility id across the control kinds a
    /// SwiftUI `Toggle(.switch)` can surface as in XCUITest.
    func toggle(_ root: XCUIElement, id: String, timeout: TimeInterval = 4.0) -> XCUIElement {
        requireElement(
            candidates: [root.switches[id], root.checkBoxes[id], root.descendants(matching: .any)[id]],
            timeout: timeout,
            description: "toggle \(id)"
        )
    }

    /// Deletes UserDefaults keys from the debug suite so a test starts
    /// from the known default. Pass the raw `userDefaultsKey`s.
    func resetDefaults(_ keys: [String], suite: String = "com.cmuxterm.app.debug") {
        for key in keys {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            process.arguments = ["delete", suite, key]
            try? process.run()
            process.waitUntilExit()
        }
    }

    // MARK: - Launch implementation

    func launchAndActivate(_ app: XCUIApplication, activateTimeout: TimeInterval = 2.0) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("Headless CI may launch the app without foreground activation", options: options) {
            app.launch()
        }
        XCTAssertTrue(
            poll(timeout: 10.0) { app.state == .runningForeground || app.state == .runningBackground },
            "App failed to launch. state=\(app.state.rawValue)"
        )
        if app.state != .runningForeground {
            _ = poll(timeout: activateTimeout) {
                guard app.state != .runningForeground else { return true }
                app.activate()
                return app.state == .runningForeground
            }
            app.activate()
        }
        XCTAssertTrue(
            poll(timeout: 6.0) { app.state == .runningForeground },
            "App did not become foreground. state=\(app.state.rawValue)"
        )
    }
}
