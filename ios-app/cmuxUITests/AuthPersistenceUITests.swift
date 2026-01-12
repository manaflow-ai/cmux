import XCTest

final class AuthPersistenceUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testAuthPersistsAcrossRelaunch() {
        let app = XCUIApplication()
        app.launch()

        ensureSignedIn(app: app)
        assertNoRestoreFlash(app: app)
        waitForConversationList(app: app)

        app.terminate()

        let relaunch = XCUIApplication()
        relaunch.launch()

        assertNoSignInFlash(app: relaunch)
        assertNoRestoreFlash(app: relaunch)
        waitForConversationList(app: relaunch)

        let emailField = relaunch.textFields["Email"]
        XCTAssertFalse(emailField.exists, "Sign-in screen should not be visible after relaunch")
    }

    func testSignedOutLaunchShowsSignInWithoutRestoreFlash() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UITEST_CLEAR_AUTH"] = "1"
        app.launch()

        assertNoRestoreFlash(app: app)
        let emailField = app.textFields["Email"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 2), "Sign-in screen should appear immediately when signed out")
    }

    private func ensureSignedIn(app: XCUIApplication) {
        let emailField = app.textFields["Email"]
        guard emailField.waitForExistence(timeout: 2) else { return }
        emailField.tap()
        emailField.typeText("42")
        let continueButton = app.buttons["Continue"]
        if continueButton.exists {
            continueButton.tap()
        }
    }

    private func waitForConversationList(app: XCUIApplication) {
        let navBar = app.navigationBars["Tasks"]
        if navBar.waitForExistence(timeout: 10) {
            return
        }
        let list = app.tables.element(boundBy: 0)
        _ = list.waitForExistence(timeout: 6)
    }

    private func assertNoSignInFlash(app: XCUIApplication, duration: TimeInterval = 2.5) {
        let emailField = app.textFields["Email"]
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            XCTAssertFalse(emailField.exists, "Sign-in screen flashed during session restore")
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    private func assertNoRestoreFlash(app: XCUIApplication, duration: TimeInterval = 2.5) {
        let restoring = app.otherElements["auth.restoring"]
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            XCTAssertFalse(restoring.exists, "Restoring session view flashed on launch")
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }
}
