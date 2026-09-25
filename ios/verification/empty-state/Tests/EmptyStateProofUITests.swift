import XCTest

final class EmptyStateProofUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testEmptyStateButtons() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        defer { app.terminate() }
        let retry = app.buttons["MobileWorkspaceEmptyRetry"]
        let docs = app.buttons["MobileWorkspaceEmptySetupGuide"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        XCTAssertTrue(docs.exists)
        capture("01-empty-state", app: app)
        let frames = XCTAttachment(string: "Retry: \(retry.frame)\nSee Docs: \(docs.frame)\nScreen: \(app.frame)\n")
        frames.name = "button-frames"
        frames.lifetime = .keepAlways
        add(frames)

        for button in [retry, docs] {
            XCTAssertGreaterThan(button.frame.width, button.frame.height, "Action must not stretch into a vertical capsule")
            XCTAssertLessThanOrEqual(button.frame.height, 64, "Default-size action must remain compact")
            XCTAssertTrue(button.isHittable)
        }
        XCTAssertTrue(retry.staticTexts["Retry"].isHittable, "Retry text must be visible")
        XCTAssertTrue(docs.staticTexts["See Docs"].isHittable, "See Docs text must be visible")

        for count in 1...2 {
            retry.tap()
            let expected = NSPredicate(format: "label == %@", String(count))
            expectation(for: expected, evaluatedWith: app.staticTexts["ProofRefreshCount"])
            waitForExpectations(timeout: 5)
            XCTAssertTrue(retry.isEnabled)
            XCTAssertTrue(docs.isHittable)
            capture("0\(count + 1)-after-retry", app: app)
        }
        docs.tap()
        let sheet = app.descendants(matching: .any)["MobileDocsSafariView"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        XCTAssertEqual(sheet.value as? String, "https://cmux.com/docs/ios#setup")
        capture("04-docs-sheet", app: app)
    }
}
