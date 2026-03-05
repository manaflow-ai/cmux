import XCTest
import Foundation

final class BrowserFindFocusPersistenceUITests: XCTestCase {
    private enum PaneFocusRoute {
        case cmdOptionArrows
        case cmdCtrlLetters
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testCmdOptionPaneSwitchPreservesFindFieldFocus() {
        runFindFocusPersistenceScenario(route: .cmdOptionArrows)
    }

    func testCmdCtrlPaneSwitchPreservesFindFieldFocus() {
        runFindFocusPersistenceScenario(route: .cmdCtrlLetters)
    }

    private func runFindFocusPersistenceScenario(route: PaneFocusRoute) {
        let app = XCUIApplication()
        if route == .cmdCtrlLetters {
            app.launchEnvironment["CMUX_UI_TEST_FOCUS_SHORTCUTS"] = "1"
        }

        launchAndEnsureForeground(app)

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10.0), "Expected main window to exist")

        // Repro setup: split, open browser split, navigate to example.com.
        app.typeKey("d", modifierFlags: [.command])
        focusRightPane(app, route: route)

        app.typeKey("l", modifierFlags: [.command, .shift])
        let omnibar = app.textFields["BrowserOmnibarTextField"].firstMatch
        XCTAssertTrue(omnibar.waitForExistence(timeout: 8.0), "Expected browser omnibar after Cmd+Shift+L")

        app.typeKey("a", modifierFlags: [.command])
        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        app.typeText("example.com")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

        XCTAssertTrue(
            waitForOmnibarToContainExampleDomain(omnibar, timeout: 8.0),
            "Expected browser navigation to example domain before running find flow. value=\(String(describing: omnibar.value))"
        )

        // Left terminal: Cmd+F then type "la".
        focusLeftPane(app, route: route)
        app.typeKey("f", modifierFlags: [.command])

        let terminalFindField = app.textFields["TerminalFindSearchTextField"].firstMatch
        XCTAssertTrue(terminalFindField.waitForExistence(timeout: 6.0), "Expected terminal find field")

        app.typeText("la")
        XCTAssertTrue(
            waitForTextFieldValue(terminalFindField, equals: "la", timeout: 4.0),
            "Expected terminal find query to be 'la'. value=\(String(describing: terminalFindField.value))"
        )

        // Right browser: Cmd+F then type "am".
        focusRightPane(app, route: route)
        app.typeKey("f", modifierFlags: [.command])

        let browserFindField = app.textFields["BrowserFindSearchTextField"].firstMatch
        XCTAssertTrue(browserFindField.waitForExistence(timeout: 6.0), "Expected browser find field")

        app.typeText("am")
        XCTAssertTrue(
            waitForTextFieldValue(browserFindField, equals: "am", timeout: 4.0),
            "Expected browser find query to be 'am'. value=\(String(describing: browserFindField.value))"
        )

        // Left terminal: typing should keep going into terminal find field.
        focusLeftPane(app, route: route)
        app.typeText("foo")
        XCTAssertTrue(
            waitForTextFieldValue(terminalFindField, equals: "lafoo", timeout: 4.0),
            "Expected terminal find field to stay focused and become 'lafoo'. value=\(String(describing: terminalFindField.value))"
        )

        // Right browser: typing should keep going into browser find field.
        focusRightPane(app, route: route)
        app.typeText("do")
        XCTAssertTrue(
            waitForTextFieldValue(browserFindField, equals: "amdo", timeout: 4.0),
            "Expected browser find field to stay focused and become 'amdo'. value=\(String(describing: browserFindField.value))"
        )
    }

    private func focusLeftPane(_ app: XCUIApplication, route: PaneFocusRoute) {
        switch route {
        case .cmdOptionArrows:
            app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [.command, .option])
        case .cmdCtrlLetters:
            app.typeKey("h", modifierFlags: [.command, .control])
        }
    }

    private func focusRightPane(_ app: XCUIApplication, route: PaneFocusRoute) {
        switch route {
        case .cmdOptionArrows:
            app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [.command, .option])
        case .cmdCtrlLetters:
            app.typeKey("l", modifierFlags: [.command, .control])
        }
    }

    private func waitForOmnibarToContainExampleDomain(_ omnibar: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let value = (omnibar.value as? String) ?? ""
            if value.contains("example.com") || value.contains("example.org") {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let value = (omnibar.value as? String) ?? ""
        return value.contains("example.com") || value.contains("example.org")
    }

    private func waitForTextFieldValue(_ field: XCUIElement, equals expected: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (field.value as? String) == expected {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return (field.value as? String) == expected
    }

    private func launchAndEnsureForeground(_ app: XCUIApplication, timeout: TimeInterval = 12.0) {
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: timeout),
            "Expected app to launch in foreground. state=\(app.state.rawValue)"
        )
    }

    private func ensureForegroundAfterLaunch(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        if app.wait(for: .runningForeground, timeout: timeout) {
            return true
        }
        if app.state == .runningBackground {
            app.activate()
            return app.wait(for: .runningForeground, timeout: 6.0)
        }
        return false
    }
}
