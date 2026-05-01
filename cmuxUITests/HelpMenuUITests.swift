import XCTest

private func helpMenuPollUntil(
    timeout: TimeInterval,
    pollInterval: TimeInterval = 0.05,
    condition: () -> Bool
) -> Bool {
    let start = ProcessInfo.processInfo.systemUptime
    while true {
        if condition() {
            return true
        }
        if (ProcessInfo.processInfo.systemUptime - start) >= timeout {
            return false
        }
        RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
    }
}

private func helpMenuResetMenuBarOnlyDefault() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    process.arguments = ["write", "com.cmuxterm.app.debug", "menuBarOnly", "-bool", "false"]
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return
    }
}

private let helpMenuMainWindowLaunchArguments = [
    "-AppleLanguages", "(en)",
    "-AppleLocale", "en_US",
    "-ApplePersistenceIgnoreState", "YES",
    "-NSQuitAlwaysKeepsWindows", "NO",
    "-menuBarOnly", "false",
]

final class HelpMenuUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testSidebarHelpMenuOpensKeyboardShortcutsSection() {
        let app = XCUIApplication()
        helpMenuResetMenuBarOnlyDefault()
        addTeardownBlock {
            app.terminate()
            helpMenuResetMenuBarOnlyDefault()
        }
        app.launchArguments += helpMenuMainWindowLaunchArguments
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        launchAndActivate(app)
        closeKeyboardShortcutsWindowIfVisible(in: app)

        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: app, timeout: 6.0))

        let helpButton = requireElement(
            candidates: helpButtonCandidates(in: app),
            timeout: 6.0,
            description: "sidebar help button"
        )
        helpButton.click()

        let keyboardShortcutsItem = requireElement(
            candidates: helpMenuItemCandidates(in: app, identifier: "SidebarHelpMenuOptionKeyboardShortcuts", title: "Keyboard Shortcuts"),
            timeout: 3.0,
            description: "Keyboard Shortcuts help menu item"
        )
        keyboardShortcutsItem.click()

        XCTAssertTrue(app.staticTexts["ShortcutRecordingHint"].waitForExistence(timeout: 6.0))
        closeKeyboardShortcutsWindowIfVisible(in: app)
    }

    func testMainHelpMenuShowsCmuxResourcesAndOpensKeyboardShortcuts() {
        let app = XCUIApplication()
        helpMenuResetMenuBarOnlyDefault()
        addTeardownBlock {
            app.terminate()
            helpMenuResetMenuBarOnlyDefault()
        }
        app.launchArguments += helpMenuMainWindowLaunchArguments
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        launchAndActivate(app)

        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: app, timeout: 6.0))

        let helpMenu = requireElement(
            candidates: [
                app.menuBars.menuBarItems["Help"],
                app.menuBars.menuItems["Help"],
            ],
            timeout: 4.0,
            description: "main Help menu"
        )
        helpMenu.click()

        XCTAssertTrue(app.menuItems["Getting Started"].waitForExistence(timeout: 2.0))
        XCTAssertTrue(app.menuItems["Concepts"].waitForExistence(timeout: 2.0))
        XCTAssertTrue(app.menuItems["Configuration"].waitForExistence(timeout: 2.0))
        XCTAssertTrue(app.menuItems["Custom Commands"].waitForExistence(timeout: 2.0))
        XCTAssertTrue(app.menuItems["Dock"].waitForExistence(timeout: 2.0))
        XCTAssertTrue(app.menuItems["Keyboard Shortcuts"].waitForExistence(timeout: 2.0))
        XCTAssertTrue(app.menuItems["API Reference"].waitForExistence(timeout: 2.0))
        XCTAssertTrue(app.menuItems["Browser Automation"].waitForExistence(timeout: 2.0))
        XCTAssertTrue(app.menuItems["Notifications"].waitForExistence(timeout: 2.0))
        XCTAssertTrue(app.menuItems["SSH"].waitForExistence(timeout: 2.0))
        XCTAssertTrue(app.menuItems["Skills"].waitForExistence(timeout: 2.0))
        XCTAssertTrue(app.menuItems["Agent Integrations"].waitForExistence(timeout: 2.0))
        XCTAssertTrue(app.menuItems["Changelog"].waitForExistence(timeout: 2.0))
        XCTAssertTrue(app.menuItems["Send Feedback"].waitForExistence(timeout: 2.0))
        XCTAssertFalse(app.menuItems["Codex Integration"].exists)

        let keyboardShortcutsItem = requireElement(
            candidates: [
                app.menuItems["Keyboard Shortcuts Settings…"],
                app.buttons["Keyboard Shortcuts Settings…"],
            ],
            timeout: 2.0,
            description: "Keyboard Shortcuts Settings Help menu item"
        )
        keyboardShortcutsItem.click()

        XCTAssertTrue(app.staticTexts["ShortcutRecordingHint"].waitForExistence(timeout: 6.0))
    }

    private func waitForWindowCount(atLeast count: Int, app: XCUIApplication, timeout: TimeInterval) -> Bool {
        helpMenuPollUntil(timeout: timeout) {
            app.windows.count >= count
        }
    }

    private func helpButtonCandidates(in app: XCUIApplication) -> [XCUIElement] {
        let sidebar = app.otherElements["Sidebar"]
        return [
            app.buttons["SidebarHelpMenuButton"],
            app.buttons["Help"],
            sidebar.buttons["SidebarHelpMenuButton"],
            sidebar.buttons["Help"],
        ]
    }

    private func helpMenuItemCandidates(
        in app: XCUIApplication,
        identifier: String,
        title: String
    ) -> [XCUIElement] {
        [
            app.buttons[identifier],
            app.buttons[title],
        ]
    }

    private func requireElement(
        candidates: [XCUIElement],
        timeout: TimeInterval,
        description: String
    ) -> XCUIElement {
        var match: XCUIElement?
        let found = helpMenuPollUntil(timeout: timeout) {
            for candidate in candidates where candidate.exists {
                match = candidate
                return true
            }
            return false
        }
        XCTAssertTrue(found, "Expected \(description) to exist")
        return match ?? candidates[0]
    }

    private func closeKeyboardShortcutsWindowIfVisible(in app: XCUIApplication) {
        let shortcutHint = app.staticTexts["ShortcutRecordingHint"]
        guard shortcutHint.waitForExistence(timeout: 1.0) else { return }
        app.typeKey("w", modifierFlags: [.command])
        _ = helpMenuPollUntil(timeout: 3.0) {
            !shortcutHint.exists
        }
    }

    private func launchAndActivate(_ app: XCUIApplication, activateTimeout: TimeInterval = 2.0) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("Headless CI may launch the app without foreground activation", options: options) {
            app.launch()
        }

        XCTAssertTrue(
            helpMenuPollUntil(timeout: 10.0) {
                app.state == .runningForeground || app.state == .runningBackground
            },
            "App failed to launch. state=\(app.state.rawValue)"
        )

        if app.state != .runningForeground {
            let activated = helpMenuPollUntil(timeout: activateTimeout) {
                guard app.state != .runningForeground else {
                    return true
                }
                app.activate()
                return app.state == .runningForeground
            }
            if !activated {
                app.activate()
            }
        }

        XCTAssertTrue(
            helpMenuPollUntil(timeout: 6.0) {
                app.state == .runningForeground
            },
            "App did not become foreground before menu interactions. state=\(app.state.rawValue)"
        )
    }
}
