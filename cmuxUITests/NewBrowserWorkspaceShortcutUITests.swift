import XCTest
import Foundation

/// End-to-end coverage for the "New Browser Workspace" action
/// (https://github.com/manaflow-ai/cmux/issues/5918): Option+Cmd+N creates a
/// workspace whose initial surface is a browser pane in its default new-tab
/// state with the address bar focused, so a URL can be typed immediately.
final class NewBrowserWorkspaceShortcutUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testOptionCmdNOpensBrowserWorkspaceWithAddressBarFocused() {
        let app = XCUIApplication()
        launchAndEnsureForeground(app)

        // The fresh launch starts with a terminal workspace; no omnibar exists yet.
        let omnibar = app.textFields["BrowserOmnibarTextField"].firstMatch
        XCTAssertFalse(
            omnibar.exists,
            "Expected no browser omnibar before creating the browser workspace"
        )

        app.typeKey("n", modifierFlags: [.command, .option])

        XCTAssertTrue(
            omnibar.waitForExistence(timeout: 8.0),
            "Expected the new workspace's initial surface to be a browser pane with an omnibar"
        )

        // The address bar must already own keyboard focus: typing without
        // clicking anything should land in the omnibar.
        XCTAssertTrue(
            waitForOmnibarTypedText(app: app, omnibar: omnibar, text: "example.com", timeout: 8.0),
            "Expected typed text to land in the focused address bar. value=\(String(describing: omnibar.value))"
        )
    }

    /// Launches the app, tolerating the headless-CI case where activation
    /// fails and the app continues in `.runningBackground` — keyboard and
    /// element APIs still work through the accessibility framework there.
    /// Mirrors `BrowserPaneNavigationKeybindUITests.launchAndEnsureForeground`.
    private func launchAndEnsureForeground(_ app: XCUIApplication) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: options) {
            app.launch()
        }

        if app.state == .runningForeground || app.state == .runningBackground {
            return
        }

        XCTFail("App failed to start. state=\(app.state.rawValue)")
    }

    /// Types into whatever currently has keyboard focus and waits for the text
    /// to show up in the omnibar. Retries the keystrokes because portal-mounted
    /// browser chrome can finish focus routing a beat after the omnibar element
    /// appears; each retry first re-checks the omnibar so already-landed text
    /// is never typed twice.
    private func waitForOmnibarTypedText(
        app: XCUIApplication,
        omnibar: XCUIElement,
        text: String,
        timeout: TimeInterval
    ) -> Bool {
        func omnibarContainsText() -> Bool {
            (omnibar.value as? String)?.contains(text) == true
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if omnibarContainsText() {
                return true
            }
            app.typeText(text)
            let valueDeadline = Date().addingTimeInterval(2.0)
            while Date() < valueDeadline {
                if omnibarContainsText() {
                    return true
                }
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
            }
        }
        return omnibarContainsText()
    }
}
