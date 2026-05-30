import XCTest

final class CloseWindowConfirmDialogUITests: XCTestCase {
    private let launchTag = "ui-tests-close-window-confirm"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testCmdCtrlWShowsCloseWindowConfirmationText() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_TAG"] = launchTag
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for close-window confirmation test. state=\(app.state.rawValue)"
        )

        app.typeKey("w", modifierFlags: [.command, .control])

        XCTAssertTrue(
            waitForCloseWindowAlert(app: app, timeout: 5.0),
            "Expected Cmd+Ctrl+W to show the close window confirmation alert"
        )

        clickCancelOnCloseWindowAlert(app: app)

        XCTAssertFalse(
            isCloseWindowAlertPresent(app: app),
            "Expected close window confirmation alert to dismiss after clicking Cancel"
        )
        XCTAssertTrue(app.windows.firstMatch.exists, "Expected the window to remain open after cancelling close")
    }

    func testReturnConfirmsCloseWindowDialog() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_TAG"] = launchTag
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for close-window confirmation test. state=\(app.state.rawValue)"
        )

        app.typeKey("w", modifierFlags: [.command, .control])

        XCTAssertTrue(
            waitForCloseWindowAlert(app: app, timeout: 5.0),
            "Expected Cmd+Ctrl+W to show the close window confirmation alert"
        )

        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(
            waitForCloseWindowAlertToDismiss(app: app, timeout: 5.0),
            "Expected Return to dismiss the close window confirmation alert"
        )
        XCTAssertTrue(
            waitForMainWindowToClose(app: app, timeout: 5.0),
            "Expected Return to confirm window close"
        )
    }

    private func isCloseWindowAlertPresent(app: XCUIApplication) -> Bool {
        if closeWindowDialog(app: app).exists { return true }
        if closeWindowAlert(app: app).exists { return true }
        return app.staticTexts["Close window?"].exists
    }

    private func waitForCloseWindowAlert(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                self.isCloseWindowAlertPresent(app: app)
            },
            object: NSObject()
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForCloseWindowAlertToDismiss(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                !self.isCloseWindowAlertPresent(app: app)
            },
            object: NSObject()
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForMainWindowToClose(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                !app.windows.firstMatch.exists
            },
            object: NSObject()
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func clickCancelOnCloseWindowAlert(app: XCUIApplication) {
        let dialog = closeWindowDialog(app: app)
        if dialog.exists {
            dialog.buttons["Cancel"].firstMatch.click()
            return
        }
        let alert = closeWindowAlert(app: app)
        if alert.exists {
            alert.buttons["Cancel"].firstMatch.click()
            return
        }
        let anyDialog = app.dialogs.firstMatch
        if anyDialog.exists, anyDialog.buttons["Cancel"].exists {
            anyDialog.buttons["Cancel"].firstMatch.click()
        }
    }

    private func closeWindowDialog(app: XCUIApplication) -> XCUIElement {
        app.dialogs.containing(.staticText, identifier: "Close window?").firstMatch
    }

    private func closeWindowAlert(app: XCUIApplication) -> XCUIElement {
        app.alerts.containing(.staticText, identifier: "Close window?").firstMatch
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
}
