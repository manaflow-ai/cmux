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
    // Shared setup intentionally lives here so each concrete Settings UI test
    // class uses the same launch and window-readiness contract.
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
        "Account", "App", "Themes", "Terminal", "TextBox", "Sidebar", "Beta Features", "Automation",
        "Browser", "Global Hotkey", "Keyboard Shortcuts", "Workspace Colors",
        "cmux.json", "Reset",
    ]

    // MARK: - Launch / window

    func makeLaunchedApp(additionalArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication.cmuxTestApplication()
        app.launchArguments += settingsLaunchArguments + additionalArguments
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        launchAndActivate(app)
        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: app, timeout: 8.0), "main window did not appear")
        return app
    }

    /// The Settings window, by its identifier (`SettingsWindowPresenter.windowIdentifier`)
    /// rather than its localized title.
    static let settingsWindowIdentifier = "cmux.settings"

    /// Opens the Settings window via ⌘, and returns it. Settings mounts its
    /// sections progressively, so the first open can take a few seconds on CI.
    @discardableResult
    func openSettings(_ app: XCUIApplication) -> XCUIElement {
        app.typeKey(",", modifierFlags: .command)
        let window = app.windows[Self.settingsWindowIdentifier]
        XCTAssertTrue(poll(timeout: 10.0) { window.exists }, "Settings window did not open")
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
        var resolved: XCUIElement?
        let found = poll(timeout: timeout) {
            let candidates = [
                root.switches[id],
                root.checkBoxes[id],
            ]
            for candidate in candidates where candidate.exists {
                resolved = candidate
                return true
            }

            // The identifier can land on an element that is neither a switch
            // nor a checkbox. Use it when it reports a value; otherwise it is
            // a container, so prefer the switch or checkbox inside it.
            let row = root.descendants(matching: .any).matching(identifier: id).firstMatch
            guard row.exists else { return false }
            if !Self.valueText(of: row).isEmpty {
                resolved = row
                return true
            }
            for candidate in [row.switches.firstMatch, row.checkBoxes.firstMatch]
                where candidate.exists {
                resolved = candidate
                return true
            }
            resolved = row
            return true
        }
        XCTAssertTrue(found, "Expected toggle \(id) to exist")
        return resolved ?? root.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Reads a toggle's on state from its accessibility value, falling back
    /// to `isSelected` only for a control that reports no value.
    func isOn(_ control: XCUIElement) -> Bool {
        let value = Self.valueText(of: control)
        if value.isEmpty {
            return control.isSelected
        }
        return value == "1" || value == "true" || value == "on"
    }

    /// A control's accessibility value as trimmed lowercase text, or "" when
    /// it reports none.
    static func valueText(of control: XCUIElement) -> String {
        control.value.map { String(describing: $0) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
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
