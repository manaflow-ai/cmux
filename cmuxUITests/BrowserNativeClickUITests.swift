import AppKit
import XCTest

/// The socket only sets up panes. Coordinate clicks enter through native
/// AppKit routing; the fixture rejects untrusted DOM-generated events.
final class BrowserNativeClickUITests: BrowserFixtureSocketTestCase {
    func testNativeClicksSurviveReopenAndOverlayDismissal() throws {
        let app = try launchApp()
        app.activate()
        XCTAssertEqual(app.state, .runningForeground)
        let pasteboard = NSPasteboard(name: .drag)
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }

        for cycle in 0..<3 {
            let surfaceID = try openFixture("native-click")
            let window = app.windows.firstMatch
            let button = window.buttons["Native click target"].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 10))

            button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            XCTAssertTrue(window.staticTexts["Trusted clicks: 1"].firstMatch.waitForExistence(timeout: 5))

            app.typeKey("l", modifierFlags: [.command])
            let omnibar = app.textFields["BrowserOmnibarTextField"].firstMatch
            XCTAssertTrue(omnibar.waitForExistence(timeout: 5))
            omnibar.typeText("example")
            let suggestions = app.descendants(matching: .any)["BrowserOmnibarSuggestions"].firstMatch
            XCTAssertTrue(suggestions.waitForExistence(timeout: 5))
            app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
            app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
            let dismissed = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in !suggestions.exists }, object: nil
            )
            XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)

            // A finished Finder drag leaves its pasteboard payload behind.
            XCTAssertTrue(pasteboard.writeObjects([URL(fileURLWithPath: #filePath) as NSURL]))
            button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            XCTAssertTrue(window.staticTexts["Trusted clicks: 2"].firstMatch.waitForExistence(timeout: 5))
            let link = window.links["Native navigation target"].firstMatch
            XCTAssertTrue(link.waitForExistence(timeout: 5))
            link.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            XCTAssertTrue(window.staticTexts["Native navigation complete"].firstMatch.waitForExistence(timeout: 5))
            let attachment = XCTAttachment(screenshot: window.screenshot())
            attachment.name = "native-click-cycle-\(cycle)"
            attachment.lifetime = .keepAlways
            add(attachment)
            try socketResult(method: "surface.close", params: ["surface_id": surfaceID])
            pasteboard.clearContents()
        }
    }
}
