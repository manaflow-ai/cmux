import XCTest

func sidebarHelpPollUntil(
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

final class SidebarHelpMenuUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testHelpMenuCheckForUpdatesTriggersSidebarUpdatePill() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_FEED_URL"] = "https://cmux.test/appcast.xml"
        app.launchEnvironment["CMUX_UI_TEST_FEED_MODE"] = "available"
        app.launchEnvironment["CMUX_UI_TEST_UPDATE_VERSION"] = "9.9.9"
        app.launchEnvironment["CMUX_UI_TEST_AUTO_ALLOW_PERMISSION"] = "1"
        launchAndActivate(app)

        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: app, timeout: 6.0))

        let helpButton = requireElement(
            candidates: helpButtonCandidates(in: app),
            timeout: 6.0,
            description: "sidebar help button"
        )
        helpButton.click()

        let checkForUpdatesItem = requireElement(
            candidates: helpMenuItemCandidates(in: app, identifier: "SidebarHelpMenuOptionCheckForUpdates", title: "Check for Updates"),
            timeout: 3.0,
            description: "Check for Updates help menu item"
        )
        checkForUpdatesItem.click()

        let updatePill = app.buttons["UpdatePill"]
        XCTAssertTrue(updatePill.waitForExistence(timeout: 6.0))
        XCTAssertEqual(updatePill.label, "Update Available: 9.9.9")
    }

    func testHelpMenuSendFeedbackOpensComposerSheet() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        launchAndActivate(app)

        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: app, timeout: 6.0))

        let helpButton = requireElement(
            candidates: helpButtonCandidates(in: app),
            timeout: 6.0,
            description: "sidebar help button"
        )
        helpButton.click()

        let sendFeedbackItem = requireElement(
            candidates: helpMenuItemCandidates(in: app, identifier: "SidebarHelpMenuOptionSendFeedback", title: "Send Feedback"),
            timeout: 3.0,
            description: "Send Feedback help menu item"
        )
        sendFeedbackItem.click()

        XCTAssertTrue(app.staticTexts["Send Feedback"].waitForExistence(timeout: 3.0))
        XCTAssertTrue(
            firstExistingElement(
                candidates: [
                    app.textFields["SidebarFeedbackEmailField"],
                    app.textFields["Your Email"],
                ],
                timeout: 2.0
            ) != nil
        )
        XCTAssertTrue(
            firstExistingElement(
                candidates: [
                    app.buttons["SidebarFeedbackAttachButton"],
                    app.buttons["Attach Images"],
                ],
                timeout: 2.0
            ) != nil
        )
        XCTAssertTrue(
            firstExistingElement(
                candidates: [
                    app.buttons["SidebarFeedbackSendButton"],
                    app.buttons["Send"],
                ],
                timeout: 2.0
            ) != nil
        )
        XCTAssertTrue(
            app.staticTexts[
                "A human will read this! You can also reach us at founders@manaflow.com."
            ].waitForExistence(timeout: 2.0)
        )

        let messageEditor = requireElement(
            candidates: [
                app.textViews["SidebarFeedbackMessageEditor"],
                app.scrollViews["SidebarFeedbackMessageEditor"],
                app.otherElements["SidebarFeedbackMessageEditor"],
                app.textViews["Message"],
            ],
            timeout: 2.0,
            description: "feedback message editor"
        )
        messageEditor.click()
        app.typeText("hello")
        XCTAssertTrue(app.staticTexts["5/4000"].waitForExistence(timeout: 2.0))
    }

    private func waitForWindowCount(atLeast count: Int, app: XCUIApplication, timeout: TimeInterval) -> Bool {
        sidebarHelpPollUntil(timeout: timeout) {
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

    private func firstExistingElement(
        candidates: [XCUIElement],
        timeout: TimeInterval
    ) -> XCUIElement? {
        var match: XCUIElement?
        let found = sidebarHelpPollUntil(timeout: timeout) {
            for candidate in candidates where candidate.exists {
                match = candidate
                return true
            }
            return false
        }
        return found ? match : nil
    }

    private func requireElement(
        candidates: [XCUIElement],
        timeout: TimeInterval,
        description: String
    ) -> XCUIElement {
        guard let element = firstExistingElement(candidates: candidates, timeout: timeout) else {
            XCTFail("Expected \(description) to exist")
            return candidates[0]
        }
        return element
    }

    private func launchAndActivate(_ app: XCUIApplication, activateTimeout: TimeInterval = 2.0) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("Headless CI may launch the app without foreground activation", options: options) {
            app.launch()
        }

        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 10.0) {
                app.state == .runningForeground || app.state == .runningBackground
            },
            "App failed to launch. state=\(app.state.rawValue)"
        )

        if app.state != .runningForeground {
            let activated = sidebarHelpPollUntil(timeout: activateTimeout) {
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
            sidebarHelpPollUntil(timeout: 6.0) {
                app.state == .runningForeground
            },
            "App did not become foreground before interactions. state=\(app.state.rawValue)"
        )
    }
}

final class CommandPaletteAllSurfacesUITests: XCTestCase {
    var socketPath = ""
    let debugDefaultsDomain = "com.cmuxterm.app.debug"
    let hiddenSurfaceToken = "cmux-command-palette-hidden-surface"
    let visibleSurfaceToken = "cmux-command-palette-visible-surface"
    let noMatchWorkspaceQuery = "cmux-command-palette-no-match"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        socketPath = "/tmp/cmux-ui-test-command-palette-\(UUID().uuidString).sock"
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: socketPath)
        super.tearDown()
    }

}
