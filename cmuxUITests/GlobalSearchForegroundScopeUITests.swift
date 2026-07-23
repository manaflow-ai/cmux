import XCTest

final class GlobalSearchForegroundScopeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()

        if app.state != .runningForeground {
            app.activate()
        }

        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 10.0),
            "Expected cmux to be foreground after launch. state=\(app.state.rawValue)"
        )
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10.0), "Expected cmux main window")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    func testGlobalSearchShortcutIsForegroundScoped() {
        let globalSearchField = app.textFields["GlobalSearchSearchField"].firstMatch
        XCTAssertFalse(globalSearchField.exists, "Global Search should start closed")

        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        for transition in 1...2 {
            finder.activate()
            XCTAssertTrue(
                finder.wait(for: .runningForeground, timeout: 8.0),
                "Expected Finder to be foreground for transition \(transition). state=\(finder.state.rawValue)"
            )
            XCTAssertTrue(
                waitForAppToLeaveForeground(app, timeout: 8.0),
                "Expected cmux to be backgrounded for transition \(transition). state=\(app.state.rawValue)"
            )

            finder.typeKey("f", modifierFlags: [.command, .option])

            let finderSearchField = finder.searchFields.firstMatch
            XCTAssertTrue(
                waitForKeyboardFocus(finderSearchField, timeout: 8.0),
                "Expected Finder to receive Cmd-Option-F and focus its search field on transition \(transition)"
            )
            XCTAssertEqual(
                finder.state,
                .runningForeground,
                "Finder should remain foreground after Cmd-Option-F on transition \(transition)"
            )
            XCTAssertNotEqual(
                app.state,
                .runningForeground,
                "cmux must remain backgrounded after Finder receives Cmd-Option-F on transition \(transition)"
            )
            XCTAssertFalse(
                globalSearchField.exists,
                "Background Cmd-Option-F must not open cmux Global Search on transition \(transition)"
            )
            attachScreenshot(named: "background-transition-\(transition)")

            app.activate()
            XCTAssertTrue(
                app.wait(for: .runningForeground, timeout: 8.0),
                "Expected cmux to return to foreground after transition \(transition). state=\(app.state.rawValue)"
            )
            XCTAssertTrue(
                waitForNonExistence(globalSearchField, timeout: 2.0),
                "Background Cmd-Option-F must not trigger Global Search later on transition \(transition)"
            )
        }

        app.typeKey("f", modifierFlags: [.command, .option])
        XCTAssertTrue(
            globalSearchField.waitForExistence(timeout: 8.0),
            "Foreground Cmd-Option-F should open cmux Global Search"
        )
        attachScreenshot(named: "foreground-global-search-open")

        app.typeKey("f", modifierFlags: [.command, .option])
        XCTAssertTrue(
            waitForNonExistence(globalSearchField, timeout: 8.0),
            "A second foreground Cmd-Option-F should close cmux Global Search"
        )
        attachScreenshot(named: "foreground-global-search-closed")
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

    private func waitForNonExistence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        waitForPredicate(NSPredicate(format: "exists == false"), object: element, timeout: timeout)
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
