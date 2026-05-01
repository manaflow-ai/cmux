import XCTest

final class ShortThreadLayoutUITests: XCTestCase {
    private let maxGapTolerance: CGFloat = 60
    private let topGapTolerance: CGFloat = 200

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testShortThreadSticksToTopWithoutLargeGaps() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_DEBUG_AUTOFOCUS"] = "0"
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "1"
        app.launch()

        ensureSignedIn(app: app)
        waitForConversationList(app: app)
        ensureConversationVisible(app: app, name: "Alex Rivera")
        openConversation(app: app, name: "Alex Rivera")

        let scroll = locateScrollView(app: app)
        XCTAssertTrue(scroll.waitForExistence(timeout: 6))

        waitForMessages(app: app)
        let initialMessages = orderedVisibleMessages(app: app, in: scroll)
        XCTAssertGreaterThanOrEqual(initialMessages.count, 2)

        assertNoLargeGaps(messages: initialMessages)
        assertTopAnchored(messages: initialMessages, scroll: scroll)

        scroll.swipeDown()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))

        let postDragMessages = orderedVisibleMessages(app: app, in: scroll)
        XCTAssertGreaterThanOrEqual(postDragMessages.count, 2)
        assertNoLargeGaps(messages: postDragMessages)
        assertTopAnchored(messages: postDragMessages, scroll: scroll)
    }

    private func openConversation(app: XCUIApplication, name: String) {
        let conversation = app.staticTexts[name]
        XCTAssertTrue(conversation.waitForExistence(timeout: 6))
        conversation.tap()
    }

    private func waitForMessages(app: XCUIApplication) {
        let scroll = app.scrollViews["chat.scroll"]
        _ = scroll.waitForExistence(timeout: 8)
        let first = messageQuery(app: app).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 6))
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    }

    private func ensureConversationVisible(app: XCUIApplication, name: String) {
        let list = app.tables.element(boundBy: 0)
        let conversation = app.staticTexts[name]
        let maxSwipes = 6
        var attempt = 0
        while attempt < maxSwipes && !conversation.exists {
            if list.exists {
                list.swipeUp()
            } else {
                app.swipeUp()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            attempt += 1
        }
    }

    private func ensureSignedIn(app: XCUIApplication) {
        let emailField = app.textFields["Email"]
        if emailField.waitForExistence(timeout: 2) {
            XCTFail("Sign-in screen visible. Ensure CMUX_UITEST_MOCK_DATA or auto-auth is configured.")
        }
    }

    private func waitForConversationList(app: XCUIApplication) {
        let navBar = app.navigationBars["Tasks"]
        if navBar.waitForExistence(timeout: 10) {
            return
        }
        // Fallback: allow the list to appear without a visible title.
        let list = app.tables.element(boundBy: 0)
        _ = list.waitForExistence(timeout: 6)
    }

    private func orderedVisibleMessages(app: XCUIApplication, in scroll: XCUIElement) -> [XCUIElement] {
        let messages = messageQuery(app: app).allElementsBoundByIndex
        let scrollFrame = scroll.frame
        let visible = messages.filter { element in
            element.exists && !element.frame.isEmpty && element.frame.intersects(scrollFrame)
        }
        return visible.sorted { $0.frame.minY < $1.frame.minY }
    }

    private func assertNoLargeGaps(messages: [XCUIElement]) {
        guard messages.count >= 2 else {
            XCTFail("Expected at least 2 message bubbles")
            return
        }
        for index in 1..<messages.count {
            let previous = messages[index - 1].frame
            let current = messages[index].frame
            let gap = current.minY - previous.maxY
            XCTAssertLessThanOrEqual(
                gap,
                maxGapTolerance,
                "Large gap between messages at index \(index - 1) and \(index): \(gap)"
            )
        }
    }

    private func assertTopAnchored(messages: [XCUIElement], scroll: XCUIElement) {
        guard let first = messages.first else {
            XCTFail("Expected at least 1 message bubble")
            return
        }
        let topGap = first.frame.minY - scroll.frame.minY
        XCTAssertLessThanOrEqual(
            topGap,
            topGapTolerance,
            "Top message is too far from top: \(topGap)"
        )
    }

    private func locateScrollView(app: XCUIApplication) -> XCUIElement {
        let scroll = app.scrollViews["chat.scroll"]
        if scroll.exists {
            return scroll
        }
        return app.otherElements["chat.scroll"]
    }

    private func messageQuery(app: XCUIApplication) -> XCUIElementQuery {
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", "chat.message.")
        let scroll = app.scrollViews["chat.scroll"]
        if scroll.exists {
            return scroll.descendants(matching: .any).matching(predicate)
        }
        return app.descendants(matching: .any).matching(predicate)
    }
}
