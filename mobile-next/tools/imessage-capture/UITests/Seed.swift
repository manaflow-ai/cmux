import XCTest

/// The iOS simulator's Messages app ships two demo conversations,
/// "+1 (888) 555-1212" (John Appleseed, "JA") and "+1 (555) 564-8583" (Kate Bell, "KB"),
/// that loop back into each other: a message sent in one appears as a received
/// message in the other. New recipients never resolve ("Searching"), so these two
/// chats are the only ones that can carry real sent/received bubbles.
enum Chat {
    static let a = "+1 (888) 555-1212"   // our primary point of view
    static let b = "+1 (555) 564-8583"   // loopback peer
}

final class Seed: XCTestCase {
    func open(_ app: XCUIApplication, _ chat: String) {
        SMS.goToList(app)
        app.staticTexts[chat].firstMatch.tap()
        SMS.pause(1.0)
    }

    func testSeedConversation() throws {
        let app = SMS.app
        app.activate()
        SMS.pause(1)
        let script: [(String, String)] = [
            (Chat.a, "Hey! Are we still on for dinner tonight?"),
            (Chat.b, "Yes! 7pm works for me"),
            (Chat.b, "Where should we go?"),
            (Chat.a, "I was thinking we could try that new Thai place on 5th street, the one with the really long line every weekend. I heard the curry is amazing."),
            (Chat.a, "🍜🍜"),
            (Chat.b, "Perfect, I'm in 👍"),
            (Chat.b, "https://www.apple.com"),
            (Chat.a, "Ha, not that link 😅"),
            (Chat.a, "See you at 7"),
        ]
        var current = ""
        for (chat, text) in script {
            if chat != current { open(app, chat); current = chat }
            SMS.send(app, text)
        }
        SMS.goToList(app)
    }
}
