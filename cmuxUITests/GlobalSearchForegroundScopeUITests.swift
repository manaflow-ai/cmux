import XCTest

final class GlobalSearchForegroundScopeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        // Headless CI can launch cmux but fail XCTest's foreground activation handshake.
        // Keep running long enough to exercise the background-only behavior under test.
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO", "-menuBarOnly", "false"]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"

        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("XCUITest cannot foreground cmux on headless CI runners", options: options) {
            app.launch()
        }
        continueAfterFailure = false

        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 1.0)
                || app.wait(for: .runningBackground, timeout: 10.0),
            "Expected cmux to launch. state=\(app.state.rawValue)"
        )
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    func testBackgroundGlobalSearchShortcutIsDeliveredToFinder() {
        defer { attachScreenshot(named: "background-shortcut-delivered-to-finder") }

        let globalSearchField = app.textFields["GlobalSearchSearchField"].firstMatch
        XCTAssertFalse(globalSearchField.exists, "Global Search should start closed")

        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        XCTAssertTrue(
            finder.wait(for: .runningForeground, timeout: 8.0),
            "Expected Finder to be foreground. state=\(finder.state.rawValue)"
        )
        XCTAssertTrue(
            waitForAppToLeaveForeground(app, timeout: 8.0),
            "Expected cmux to be backgrounded. state=\(app.state.rawValue)"
        )

        finder.typeKey("f", modifierFlags: [.command, .option])

        let finderSearchField = finder.searchFields.firstMatch
        XCTAssertTrue(
            waitForKeyboardFocus(finderSearchField, timeout: 8.0),
            "Expected Finder to receive Cmd-Option-F and focus its search field"
        )
        XCTAssertEqual(finder.state, .runningForeground, "Finder should remain foreground after Cmd-Option-F")
        XCTAssertNotEqual(
            app.state,
            .runningForeground,
            "cmux must remain backgrounded after Finder receives Cmd-Option-F"
        )
        XCTAssertFalse(globalSearchField.exists, "Background Cmd-Option-F must not open cmux Global Search")
    }

    private func waitForAppToLeaveForeground(_ application: XCUIApplication, timeout: TimeInterval) -> Bool {
        waitForPredicate(
            NSPredicate(format: "state != %d", XCUIApplication.State.runningForeground.rawValue),
            object: application,
            timeout: timeout
        )
    }

    private func waitForKeyboardFocus(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        waitForPredicate(
            NSPredicate(format: "exists == true AND hasKeyboardFocus == true"),
            object: element,
            timeout: timeout
        )
    }

    private func waitForPredicate(_ predicate: NSPredicate, object: Any, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: object)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
