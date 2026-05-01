import XCTest

final class ChatFix1MainMockUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testOpenFix1MainMockMessages() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "1"
        app.launchEnvironment["CMUX_UITEST_CHAT_VIEW"] = "1"
        app.launchEnvironment["CMUX_UITEST_PROVIDER_ID"] = "claude"
        app.launch()

        let chatScroll = app.scrollViews["chat.scroll"]
        XCTAssertTrue(
            chatScroll.waitForExistence(timeout: 12),
            "Expected chat scroll view after opening Fix 1 main mock messages"
        )

        let inputPill = app.otherElements["chat.inputPill"]
        XCTAssertTrue(
            inputPill.waitForExistence(timeout: 12),
            "Expected input pill after opening Fix 1 main mock messages"
        )
        let messagePredicate = NSPredicate(format: "identifier BEGINSWITH %@", "chat.message.")
        let firstMessage = app.descendants(matching: .any).matching(messagePredicate).firstMatch
        XCTAssertTrue(
            firstMessage.waitForExistence(timeout: 12),
            "Expected at least one message bubble after opening Fix 1 main mock messages"
        )
        let inputBaseline = captureInputPillBaseline(
            app: app,
            pill: inputPill,
            context: "fix1 main mock"
        )
        assertInputPillVisibleAndNotBelowBaseline(
            app: app,
            pill: inputPill,
            baseline: inputBaseline,
            context: "fix1 main mock"
        )
    }
}
