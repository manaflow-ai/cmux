import XCTest

private extension XCTestCase {
    func waitForCondition(timeout: TimeInterval, predicate: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in predicate() },
            object: nil
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}

final class CommandPaletteShortcutSelectionUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testCommandPaletteCommandShiftHorizontalArrowsSelectSearchText() {
        let app = launchPlain()

        app.typeKey("p", modifierFlags: [.command, .shift])
        let searchField = app.textFields["CommandPaletteSearchField"].firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 6.0), "Expected command palette search field")

        searchField.click()
        searchField.typeText("abcdef")
        XCTAssertTrue(
            waitForCondition(timeout: 3.0) {
                ((searchField.value as? String) ?? "") == "abcdef"
            },
            "Expected command palette query to be editable before selection shortcut. value=\(String(describing: searchField.value))"
        )

        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [.command, .shift])
        app.typeText("L")
        XCTAssertTrue(
            waitForCondition(timeout: 3.0) {
                ((searchField.value as? String) ?? "") == "L"
            },
            "Expected Cmd+Shift+Left to select the full query before replacement. value=\(String(describing: searchField.value))"
        )

        app.typeKey("a", modifierFlags: [.command])
        app.typeText("abcdef")
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [.command])
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [.command, .shift])
        app.typeText("R")
        XCTAssertTrue(
            waitForCondition(timeout: 3.0) {
                ((searchField.value as? String) ?? "") == "R"
            },
            "Expected Cmd+Shift+Right to select the full query before replacement. value=\(String(describing: searchField.value))"
        )
    }

    private func launchPlain() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        launchAndEnsureForeground(app)
        return app
    }

    private func launchAndEnsureForeground(_ app: XCUIApplication) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: options) {
            app.launch()
        }

        if app.state == .runningForeground { return }
        if app.state == .runningBackground {
            app.activate()
        }
        XCTAssertTrue(
            waitForCondition(timeout: 6.0) {
                app.state == .runningForeground
            },
            "Expected app to be foreground before sending keyboard input. state=\(app.state.rawValue)"
        )
    }
}
