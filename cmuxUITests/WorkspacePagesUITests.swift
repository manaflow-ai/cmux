import XCTest

private func workspacePagesPollUntil(
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

final class WorkspacePagesUITests: XCTestCase {
    private let launchTag = "ui-tests-workspace-pages"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testTitlebarPageStripCreateSelectCloseAndHintFlow() {
        let app = configuredApp()
        app.launch()

        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for workspace pages UI test. state=\(app.state.rawValue)"
        )
        XCTAssertTrue(waitForPageButtonCount(1, app: app, timeout: 8.0))

        guard let firstPageToken = activePageToken(in: app) else {
            XCTFail("Expected initial active titlebar page button")
            return
        }

        XCTAssertTrue(waitForElementExists(app.staticTexts["titlebarPageHint.1"], timeout: 6.0))

        app.typeKey("n", modifierFlags: [.command, .option])

        XCTAssertTrue(waitForPageButtonCount(2, app: app, timeout: 8.0))
        guard let secondPageToken = activePageToken(in: app) else {
            XCTFail("Expected created page to become active")
            return
        }
        XCTAssertNotEqual(secondPageToken, firstPageToken)
        XCTAssertTrue(waitForElementExists(app.staticTexts["titlebarPageHint.2"], timeout: 6.0))

        let firstPageButton = app.buttons["titlebarPageButton.\(firstPageToken)"]
        XCTAssertTrue(waitForElementExists(firstPageButton, timeout: 6.0))
        firstPageButton.click()

        XCTAssertTrue(waitForActivePageToken(firstPageToken, app: app, timeout: 6.0))

        let closeButton = app.buttons["titlebarPageCloseButton.\(firstPageToken)"]
        XCTAssertTrue(waitForElementExists(closeButton, timeout: 6.0))
        closeButton.click()

        XCTAssertTrue(waitForPageButtonCount(1, app: app, timeout: 8.0))
        XCTAssertTrue(waitForActivePageToken(secondPageToken, app: app, timeout: 6.0))
    }

    private func configuredApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = launchTag
        app.launchArguments += ["-shortcutHintAlwaysShow", "YES"]
        app.launchArguments += ["-shortcutHintTitlebarXOffset", "4"]
        app.launchArguments += ["-shortcutHintTitlebarYOffset", "0"]
        return app
    }

    private func ensureForegroundAfterLaunch(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        if app.wait(for: .runningForeground, timeout: timeout) {
            return true
        }
        if app.state == .runningBackground {
            app.activate()
            return app.wait(for: .runningForeground, timeout: 6.0)
        }
        return false
    }

    private func waitForPageButtonCount(_ count: Int, app: XCUIApplication, timeout: TimeInterval) -> Bool {
        workspacePagesPollUntil(timeout: timeout) {
            pageButtons(in: app).count == count
        }
    }

    private func waitForActivePageToken(_ token: String, app: XCUIApplication, timeout: TimeInterval) -> Bool {
        workspacePagesPollUntil(timeout: timeout) {
            activePageToken(in: app) == token
        }
    }

    private func waitForElementVisible(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        workspacePagesPollUntil(timeout: timeout) {
            guard element.exists else { return false }
            let frame = element.frame
            return frame.width > 1 && frame.height > 1
        }
    }

    private func waitForElementExists(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        workspacePagesPollUntil(timeout: timeout) {
            element.exists
        }
    }

    private func activePageToken(in app: XCUIApplication) -> String? {
        let query = activePageButtons(in: app)
        guard query.count == 1 else { return nil }
        return pageToken(from: query.element(boundBy: 0).identifier)
    }

    private func pageButtons(in app: XCUIApplication) -> XCUIElementQuery {
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", "titlebarPageButton.")
        return app.descendants(matching: .button).matching(predicate)
    }

    private func activePageButtons(in app: XCUIApplication) -> XCUIElementQuery {
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", "titlebarPageButton.active.")
        return app.descendants(matching: .button).matching(predicate)
    }

    private func pageToken(from identifier: String) -> String? {
        if identifier.hasPrefix("titlebarPageButton.active.") {
            return String(identifier.dropFirst("titlebarPageButton.active.".count))
        }
        if identifier.hasPrefix("titlebarPageButton.") {
            return String(identifier.dropFirst("titlebarPageButton.".count))
        }
        return nil
    }
}
