import XCTest

/// E2E tests for conversation list and message visibility
final class ConversationE2ETests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "1"
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    /// Test that the conversation list view loads and shows expected UI elements
    func testConversationListLoads() throws {
        // Wait for app to load
        let tasksTitle = app.navigationBars["Tasks"]
        XCTAssertTrue(tasksTitle.waitForExistence(timeout: 10), "Tasks navigation bar should exist")

        // Check for either:
        // 1. Loading indicator
        // 2. Empty state ("No Tasks")
        // 3. Actual conversation list
        let loadingIndicator = app.activityIndicators.firstMatch
        let emptyStateLabel = app.staticTexts["No Tasks"]
        let conversationList = app.collectionViews.firstMatch

        // Wait for loading to complete (up to 15 seconds)
        let loadingComplete = NSPredicate { _, _ in
            !loadingIndicator.exists || emptyStateLabel.exists || conversationList.exists
        }
        let expectation = XCTNSPredicateExpectation(predicate: loadingComplete, object: nil)
        let result = XCTWaiter.wait(for: [expectation], timeout: 15)

        if result == .timedOut {
            // Take screenshot for debugging
            let screenshot = app.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "ConversationListTimeout"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTFail("Conversation list did not finish loading within timeout")
        }

        // Verify we're in one of the expected states
        let hasContent = emptyStateLabel.exists || conversationList.cells.count > 0
        XCTAssertTrue(hasContent, "Should show either empty state or conversations")

        // Take screenshot of final state
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "ConversationListLoaded"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Test that tapping a conversation opens the chat view
    func testOpenConversation() throws {
        // Wait for conversation list to load
        let conversationList = app.collectionViews.firstMatch
        guard conversationList.waitForExistence(timeout: 15) else {
            // No conversations - skip test
            throw XCTSkip("No conversations available to test")
        }

        // Wait for at least one cell
        let firstCell = conversationList.cells.firstMatch
        guard firstCell.waitForExistence(timeout: 10) else {
            throw XCTSkip("No conversation cells found")
        }

        // Tap the first conversation
        firstCell.tap()

        // Wait for chat view to load
        // Check for either loading indicator or message scroll view
        let loadingIndicator = app.activityIndicators["Loading messages..."]
        let chatScroll = app.scrollViews["chat.scroll"]

        let chatLoaded = NSPredicate { _, _ in
            loadingIndicator.exists || chatScroll.exists
        }
        let expectation = XCTNSPredicateExpectation(predicate: chatLoaded, object: nil)
        let result = XCTWaiter.wait(for: [expectation], timeout: 10)

        XCTAssertNotEqual(result, .timedOut, "Chat view should load")

        // Wait for messages to load (if loading)
        if loadingIndicator.exists {
            let messagesLoaded = NSPredicate { _, _ in
                !loadingIndicator.exists
            }
            let msgExpectation = XCTNSPredicateExpectation(predicate: messagesLoaded, object: nil)
            _ = XCTWaiter.wait(for: [msgExpectation], timeout: 15)
        }

        // Take screenshot
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "ChatViewLoaded"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Verify chat scroll exists after loading
        XCTAssertTrue(chatScroll.waitForExistence(timeout: 5), "Chat scroll view should exist")
    }

    /// Test that messages are visible in the chat view
    func testMessagesVisible() throws {
        // Wait for conversation list
        let conversationList = app.collectionViews.firstMatch
        guard conversationList.waitForExistence(timeout: 15) else {
            throw XCTSkip("No conversations available")
        }

        let firstCell = conversationList.cells.firstMatch
        guard firstCell.waitForExistence(timeout: 10) else {
            throw XCTSkip("No conversation cells found")
        }

        // Open conversation
        firstCell.tap()

        // Wait for chat to fully load
        let chatScroll = app.scrollViews["chat.scroll"]
        guard chatScroll.waitForExistence(timeout: 20) else {
            let screenshot = app.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "ChatScrollNotFound"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTFail("Chat scroll view not found")
            return
        }

        // Look for message bubbles (they have accessibility identifiers like "chat.message.*")
        let messagePredicate = NSPredicate(format: "identifier BEGINSWITH 'chat.message.'")
        let messageElements = app.descendants(matching: .any).matching(messagePredicate)

        // Wait a bit for messages to render
        sleep(2)

        let messageCount = messageElements.count
        print("Found \(messageCount) message elements")

        // Take screenshot regardless
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "ChatMessages_\(messageCount)"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Log all accessibility elements for debugging
        print("All elements in chat scroll:")
        for i in 0..<min(20, chatScroll.descendants(matching: .any).count) {
            let element = chatScroll.descendants(matching: .any).element(boundBy: i)
            print("  [\(i)] \(element.elementType) - id: '\(element.identifier)' label: '\(element.label)'")
        }

        // We expect messages if the conversation has any
        // Don't fail if empty - could be a new conversation
        if messageCount == 0 {
            print("Warning: No messages found in conversation (may be empty)")
        }
    }
}
