import XCTest

final class MobileChatHomeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testChatSurfaceNavigationAndProviderPicker() {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "CMUX_UITEST_CHAT_PREVIEW": "1",
            "CMUX_UITEST_SUPPRESS_WHATS_NEW": "1",
        ]
        app.launch()
        defer { app.terminate() }

        let newChat = app.buttons["MobileChatNewChat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["MobileChatSession-preview-codex"].exists)
        XCTAssertTrue(app.buttons["MobileChatSession-preview-claude"].exists)
        XCTAssertTrue(app.buttons["MobileChatSession-preview-opencode"].exists)

        let chats = XCTAttachment(screenshot: app.screenshot())
        chats.name = "chat-home"
        chats.lifetime = .keepAlways
        add(chats)

        app.buttons["MobileChatSession-preview-codex"].tap()
        let back = app.buttons["MobileChatBackToChats"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["MobileChatComposer"].exists)
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "existing shell entry point")
        ).firstMatch.exists)

        let conversation = XCTAttachment(screenshot: app.screenshot())
        conversation.name = "chat-conversation"
        conversation.lifetime = .keepAlways
        add(conversation)

        back.tap()
        XCTAssertTrue(newChat.waitForExistence(timeout: 5))
        newChat.tap()

        XCTAssertTrue(app.staticTexts["What are you working on?"].waitForExistence(timeout: 5))
        for provider in ["Codex", "Claude", "OpenCode"] {
            XCTAssertTrue(app.buttons["MobileChatProvider-\(provider)"].exists, provider)
        }

        let providers = XCTAttachment(screenshot: app.screenshot())
        providers.name = "chat-new-provider-picker"
        providers.lifetime = .keepAlways
        add(providers)
    }
}
