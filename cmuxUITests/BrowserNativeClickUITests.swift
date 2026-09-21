import AppKit
import XCTest

/// Uses the macOS pointer path; JavaScript or browser socket clicks cannot
/// satisfy the trusted mouse-down/up assertions in this fixture.
final class BrowserNativeClickUITests: XCTestCase {
    func testNativeClicksSurviveOverlayDismissalAndStaleFileDrag() throws {
        continueAfterFailure = false
        let app = XCUIApplication.cmuxTestApplication()
        let launchTag = "native-click-\(UUID().uuidString.prefix(8))"
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CMUX_TAG"] = launchTag
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_DISABLE_REMOTE_SUGGESTIONS"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_BROWSER_URL"] = Self.fixtureURL.absoluteString
        app.launch()
        addTeardownBlock { app.terminate() }

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        let hostReady = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in self.browserHost(in: window) != nil },
            object: nil
        )
        let hostWaitResult = XCTWaiter.wait(for: [hostReady], timeout: 30)
        XCTAssertEqual(
            hostWaitResult,
            .completed,
            "Timed out waiting for the browser host to mount in the native click fixture"
        )
        let host = try XCTUnwrap(browserHost(in: window))
        let webView = host.elementType == .webView
            ? host
            : host.descendants(matching: .webView).firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 15), "Browser WebView must mount in the native click fixture")
        let button = webView.buttons["Native click target"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 15), "Native click fixture must finish loading")

        click(button)
        XCTAssertTrue(
            webView.staticTexts["Trusted clicks: 1"].firstMatch.waitForExistence(timeout: 5),
            "The first native click must reach the page"
        )

        app.typeKey("l", modifierFlags: [.command])
        let omnibar = app.textFields["BrowserOmnibarTextField"].firstMatch
        XCTAssertTrue(omnibar.waitForExistence(timeout: 5))
        omnibar.typeText("example")
        let suggestions = app.descendants(matching: .any)
            .matching(identifier: "BrowserOmnibarSuggestions")
            .firstMatch
        XCTAssertTrue(suggestions.waitForExistence(timeout: 5), "Omnibar suggestions must appear before dismissal")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(
                    predicate: NSPredicate { _, _ in !suggestions.exists },
                    object: nil
                )],
                timeout: 5
            ),
            .completed,
            "Omnibar suggestions must disappear before testing page clicks"
        )
        // Escape clears the address-bar query and releases focus; the chrome
        // header intentionally remains visible. The next native click is the
        // behavior-level proof that the dismissed overlay no longer captures
        // the page.

        let dragPasteboard = NSPasteboard(name: .drag)
        dragPasteboard.clearContents()
        defer { dragPasteboard.clearContents() }
        XCTAssertTrue(dragPasteboard.writeObjects([Self.fixtureURL as NSURL]))

        click(button)
        XCTAssertTrue(
            webView.staticTexts["Trusted clicks: 2"].firstMatch.waitForExistence(timeout: 5),
            "A stale Finder payload must not capture the native mouse release"
        )

        let link = webView.links["Native navigation target"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        click(link)
        XCTAssertTrue(
            webView.staticTexts["Native navigation complete"].firstMatch.waitForExistence(timeout: 5),
            "A native click must activate a WebKit link"
        )
    }

    private func click(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    private func browserHost(in window: XCUIElement) -> XCUIElement? {
        let windowFrame = window.frame
        return window.children(matching: .any).allElementsBoundByIndex.first(where: {
            let frame = $0.frame
            return frame.minX > windowFrame.midX && frame.height > windowFrame.height / 2
        })
    }

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("BrowserFixtures/native-click.html")
    }
}
