import XCTest

final class CloseWindowConfirmDialogUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testCmdCtrlWShowsCloseWindowConfirmationText() {
        let app = XCUIApplication()
        app.launch()
        app.activate()

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

    private func isCloseWindowAlertPresent(app: XCUIApplication) -> Bool {
        if closeWindowDialog(app: app).exists { return true }
        if closeWindowAlert(app: app).exists { return true }
        return app.staticTexts["Close window?"].exists
    }

    private func waitForCloseWindowAlert(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isCloseWindowAlertPresent(app: app) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return isCloseWindowAlertPresent(app: app)
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
}
