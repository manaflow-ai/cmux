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
    private var interruptionMonitor: NSObjectProtocol?

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        interruptionMonitor = addUIInterruptionMonitor(withDescription: "Notification Center") { dialog in
            Self.dismissInterruptingDialog(dialog)
        }
    }

    override func tearDown() {
        if let interruptionMonitor {
            removeUIInterruptionMonitor(interruptionMonitor)
        }
        interruptionMonitor = nil
        super.tearDown()
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
        XCTAssertTrue(clickElementHandlingInterruptions(
            closeButton,
            app: app,
            successCondition: { self.waitForPageButtonCount(1, app: app, timeout: 1.0) }
        ))

        XCTAssertTrue(waitForPageButtonCount(1, app: app, timeout: 8.0))
        XCTAssertTrue(waitForActivePageToken(secondPageToken, app: app, timeout: 6.0))
    }

    private func configuredApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = launchTag
        app.launchEnvironment["CMUX_UI_TEST_SKIP_CONFIRM_CLOSE_PAGE"] = "1"
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

    private func clickElementHandlingInterruptions(
        _ element: XCUIElement,
        app: XCUIApplication,
        attempts: Int = 2,
        successCondition: () -> Bool
    ) -> Bool {
        for attempt in 0..<attempts {
            dismissNotificationCenterIfPresent()
            if app.state != .runningForeground {
                app.activate()
                _ = app.wait(for: .runningForeground, timeout: 4.0)
            }
            guard element.exists else { return false }
            element.click()
            if successCondition() {
                return true
            }
            let dismissedInterruption = dismissNotificationCenterIfPresent()
            if successCondition() {
                return true
            }
            guard dismissedInterruption, attempt + 1 < attempts else { continue }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return successCondition()
    }

    @discardableResult
    private func dismissNotificationCenterIfPresent() -> Bool {
        let notificationCenter = XCUIApplication(bundleIdentifier: "com.apple.UserNotificationCenter")
        let dialog = notificationCenter.dialogs.firstMatch
        if dialog.exists || dialog.waitForExistence(timeout: 0.2) {
            return Self.dismissInterruptingDialog(dialog)
        }
        let sheet = notificationCenter.sheets.firstMatch
        if sheet.exists || sheet.waitForExistence(timeout: 0.2) {
            return Self.dismissInterruptingDialog(sheet)
        }
        return false
    }

    private static func dismissInterruptingDialog(_ dialog: XCUIElement) -> Bool {
        let preferredButtonIDs = [
            "Close",
            "Dismiss",
            "Clear",
            "Later",
            "Not Now",
            "OK",
            "Cancel",
            "action-button-3",
            "action-button-2",
            "action-button-1",
            "action-button-0",
        ]
        for buttonID in preferredButtonIDs {
            let button = dialog.buttons[buttonID]
            if button.exists {
                button.click()
                return true
            }
        }
        let buttons = dialog.descendants(matching: .button).allElementsBoundByIndex
        if let fallback = buttons.reversed().first(where: { $0.exists && $0.isHittable }) {
            fallback.click()
            return true
        }
        if let fallback = buttons.first(where: { $0.exists }) {
            fallback.click()
            return true
        }
        return false
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
