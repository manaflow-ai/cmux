import XCTest

/// Exploration helpers: dump the Messages accessibility tree at key states.
final class Explore: XCTestCase {
    func testDump() throws {
        let app = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")
        app.activate()
        sleep(2)
        print("=== LIST ===\n" + app.debugDescription)
        app.cells.firstMatch.tap()
        sleep(2)
        print("=== CONVO ===\n" + app.debugDescription)
    }

    func testSendProbe() throws {
        let app = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")
        app.activate()
        sleep(1)
        if !app.textFields["messageBodyField"].exists { app.cells.firstMatch.tap(); sleep(1) }
        let field = app.textFields["messageBodyField"]
        field.tap()
        sleep(1)
        field.typeText("Hello there")
        sleep(1)
        print("=== TYPED ===\n" + app.debugDescription)
        let send = app.buttons["sendButton"]
        if send.exists { send.tap() } else { field.typeText("\n") }
        sleep(4)
        print("=== SENT ===\n" + app.debugDescription)
    }
}
