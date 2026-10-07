import XCTest

/// Task composer (c8-composer.md) on the mock sink: Send stays disabled
/// for an empty prompt, then dispatches and shows the outcome.
@MainActor
final class NextComposerUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testSendOnMock() {
        let app = NextUITest.launchShell(tab: "compose")
        NextUITest.assertTabRoot(app, "compose")
        let send = NextUITest.element(app, "composer.send")
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        XCTAssertFalse(send.isEnabled, "Send is enabled with an empty prompt")
        XCTAssertTrue(NextUITest.element(app, "composer.target").exists, "no target pill")

        let prompt = NextUITest.element(app, "composer.prompt")
        XCTAssertTrue(NextUITest.waitHittable(prompt))
        prompt.tap()
        prompt.typeText("d3 dogfood: run the FeatureKit tests")
        XCTAssertTrue(NextUITest.wait(send, "enabled == true"),
                      "Send stays disabled: \(NextUITest.element(app, "composer.blocker").label)")
        send.tap()
        XCTAssertTrue(NextUITest.element(app, "composer.outcome").waitForExistence(timeout: 15), "no outcome after Send")
    }

    /// The floating compose button over Feed opens the composer.
    func testFloatingButtonOpensComposer() {
        let app = NextUITest.launchShell(tab: "feed")
        NextUITest.tap(app, "composer.floating")
        XCTAssertTrue(NextUITest.element(app, "composer.prompt").waitForExistence(timeout: 10))
    }
}
