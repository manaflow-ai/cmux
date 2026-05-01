import XCTest

final class AuthPersistenceUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testAuthPersistsAcrossRelaunch() {
        let app = XCUIApplication()
        configureAutoAuth(app)
        app.launch()

        ensureSignedIn(app: app)
        assertNoRestoreFlash(app: app)
        waitForSignedInHome(app: app)

        app.terminate()

        let relaunch = XCUIApplication()
        configureAutoAuth(relaunch)
        relaunch.launch()

        assertNoSignInFlash(app: relaunch)
        assertNoRestoreFlash(app: relaunch)
        waitForSignedInHome(app: relaunch)

        let emailField = relaunch.textFields["Email"]
        XCTAssertFalse(emailField.exists, "Sign-in screen should not be visible after relaunch")
    }

    func testSignedOutLaunchShowsSignInWithoutRestoreFlash() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "0"
        app.launchEnvironment["CMUX_UITEST_CLEAR_AUTH"] = "1"
        app.launch()

        assertNoRestoreFlash(app: app)
        let emailField = app.textFields["Email"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 2), "Sign-in screen should appear immediately when signed out")
    }

    private func ensureSignedIn(app: XCUIApplication) {
        let emailField = app.textFields["Email"]
        if emailField.waitForExistence(timeout: 2) {
            XCTFail("Sign-in screen visible. Ensure the auth fixture launch environment is enabled.")
        }
    }

    private func configureAutoAuth(_ app: XCUIApplication) {
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "0"
        app.launchEnvironment["CMUX_UITEST_AUTH_FIXTURE"] = "1"
        app.launchEnvironment["CMUX_UITEST_AUTH_USER_ID"] = "auth-persistence-user"
        app.launchEnvironment["CMUX_UITEST_AUTH_EMAIL"] = "auth-persistence@cmux.local"
        app.launchEnvironment["CMUX_UITEST_AUTH_NAME"] = "Auth Persistence"
    }

    private func waitForSignedInHome(app: XCUIApplication) {
        let workspacesNavBar = app.navigationBars["Workspaces"]
        XCTAssertTrue(workspacesNavBar.waitForExistence(timeout: 10), "Expected signed-in launch to reach the terminal home")

        let findServersButton = app.buttons["terminal.server.find"]
        XCTAssertTrue(findServersButton.waitForExistence(timeout: 4), "Expected machine and workspace controls to be visible")
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
