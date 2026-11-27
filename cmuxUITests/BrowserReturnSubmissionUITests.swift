import XCTest

/// Native keys must traverse the app/window routing before reaching WebKit.
/// Socket browser.press bypasses that routing and cannot cover this regression.
final class BrowserReturnSubmissionUITests: BrowserFixtureSocketTestCase {
    func testReturnSubmitsFormAndCommandReturnReachesPage() throws {
        let app = try launchApp()
        let surfaceID = try openFixture("return-submit")
        let field = app.webViews.textFields["Account name"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.click()
        app.typeText("browser-regression")
        XCTAssertEqual(try evalString("document.activeElement.id", surfaceID: surfaceID), "account")
        XCTAssertEqual(try evalString("document.getElementById('account').value", surfaceID: surfaceID), "browser-regression")

        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(app.webViews.staticTexts["Submissions: 1"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.webViews.staticTexts["Trusted Return: 1"].firstMatch.waitForExistence(timeout: 5))

        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [.command])
        XCTAssertTrue(app.webViews.staticTexts["Trusted Command Return: 1"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(try evalString("document.activeElement.id", surfaceID: surfaceID), "account")
    }
}
