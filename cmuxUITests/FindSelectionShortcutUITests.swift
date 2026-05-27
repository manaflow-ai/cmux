import XCTest
import Foundation

final class FindSelectionShortcutUITests: XCTestCase {
    private var dataPath = ""
    private var socketPath = ""
    private var launchTag = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        dataPath = "/tmp/cmux-ui-test-find-selection-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: dataPath)
        socketPath = "/tmp/cmux-ui-test-socket-\(UUID().uuidString).sock"
        try? FileManager.default.removeItem(atPath: socketPath)
        launchTag = "ui-tests-find-selection-\(UUID().uuidString.prefix(8))"

        let cleanup = XCUIApplication()
        cleanup.terminate()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    func testRepeatedCmdFPreservesOpenTerminalAndBrowserFindCaretAndSelection() {
        let app = configuredApp()
        launchAndEnsureForeground(app)

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10.0), "Expected main window")

        app.typeKey("d", modifierFlags: [.command])
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                guard data["lastSplitDirection"] == "right" else { return false }
                guard let paneCountAfterSplit = Int(data["paneCountAfterSplit"] ?? "") else { return false }
                return paneCountAfterSplit >= 2
            },
            "Expected Cmd+D split before opening browser. data=\(String(describing: loadData()))"
        )
        openBrowserInRightPane(app)
        assertFindRefocusPreservesSelection(app, pane: .terminal, initial: "abc", replacement: "x", expected: "abx")
        assertFindRefocusPreservesSelection(app, pane: .browser, initial: "def", replacement: "y", expected: "dey")
        assertFindRefocusPreservesCaret(app, pane: .terminal, initial: "abcd", insertion: "z", expected: "abzcd")
        assertFindRefocusPreservesCaret(app, pane: .browser, initial: "wxyz", insertion: "q", expected: "wxqyz")
    }

    func testEscapeClosesTerminalAndBrowserFindAfterQuery() {
        let app = configuredApp()
        launchAndEnsureForeground(app)

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10.0), "Expected main window")

        app.typeKey("d", modifierFlags: [.command])
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                guard data["lastSplitDirection"] == "right" else { return false }
                guard let paneCountAfterSplit = Int(data["paneCountAfterSplit"] ?? "") else { return false }
                return paneCountAfterSplit >= 2
            },
            "Expected Cmd+D split before opening browser. data=\(String(describing: loadData()))"
        )
        openBrowserInRightPane(app)
        enterFindThenEscape(app, pane: .terminal, query: "terminal")
        enterFindThenEscape(app, pane: .browser, query: "browser")
        assertFindRecoversAndCanReplace(app, pane: .terminal, query: "terminal", replacement: "t")
        assertFindRecoversAndCanReplace(app, pane: .browser, query: "browser", replacement: "b")
    }

    func testFindFieldsKeepArrowKeyEditingWhileFocused() {
        let app = configuredApp()
        launchAndEnsureForeground(app)

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10.0), "Expected main window")

        app.typeKey("d", modifierFlags: [.command])
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                guard data["lastSplitDirection"] == "right" else { return false }
                guard let paneCountAfterSplit = Int(data["paneCountAfterSplit"] ?? "") else { return false }
                return paneCountAfterSplit >= 2
            },
            "Expected Cmd+D split before opening browser. data=\(String(describing: loadData()))"
        )
        openBrowserInRightPane(app)
        assertFindArrowEditing(app, pane: .terminal)
        assertFindArrowEditing(app, pane: .browser)
    }

    func testFindCaretPositionSurvivesCmdOptionPaneNavigation() {
        let app = configuredApp()
        launchAndEnsureForeground(app)

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10.0), "Expected main window")

        app.typeKey("d", modifierFlags: [.command])
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                guard data["lastSplitDirection"] == "right" else { return false }
                guard let paneCountAfterSplit = Int(data["paneCountAfterSplit"] ?? "") else { return false }
                return paneCountAfterSplit >= 2
            },
            "Expected Cmd+D split before opening browser. data=\(String(describing: loadData()))"
        )
        openBrowserInRightPane(app)
        assertFindCaretSurvivesCmdOptionNavigation(app, pane: .terminal)
        assertFindCaretSurvivesCmdOptionNavigation(app, pane: .browser)
    }

    func testBrowserFindUpDownArrowsNavigateMatchesWhileFocused() {
        let app = configuredApp()
        launchAndEnsureForeground(app)

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10.0), "Expected main window")

        app.typeKey("d", modifierFlags: [.command])
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                guard data["lastSplitDirection"] == "right" else { return false }
                guard let paneCountAfterSplit = Int(data["paneCountAfterSplit"] ?? "") else { return false }
                return paneCountAfterSplit >= 2
            },
            "Expected Cmd+D split before opening browser. data=\(String(describing: loadData()))"
        )
        openBrowserInRightPane(app, url: makeBrowserFindMatchesURL()) { omnibar in
            self.waitForCondition(timeout: 8.0) {
                ((omnibar.value as? String) ?? "").contains("data:text/html")
            }
        }

        focusPane(.browser, app: app)
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { $0["focusedPanelKind"] == "browser" },
            "Expected browser focus before opening find. data=\(String(describing: loadData()))"
        )
        app.typeKey("f", modifierFlags: [.command])
        let findField = app.textFields[Pane.browser.findFieldId].firstMatch
        XCTAssertTrue(
            findField.waitForExistence(timeout: 6.0),
            "Expected browser find field after Cmd+F. data=\(String(describing: loadData()))"
        )
        replaceFindText(app, with: "alpha")
        XCTAssertTrue(
            waitForDataMatch(timeout: 8.0) { data in
                guard let total = Int(data["browserFindTotal"] ?? "") else { return false }
                return data["browserFindNeedle"] == "alpha" &&
                    data["browserFindSelected"] == "1" &&
                    total >= 2
            },
            "Expected browser find to select the first match. data=\(String(describing: loadData()))"
        )

        app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { $0["browserFindSelected"] == "2" },
            "Expected Down arrow in browser find to select the next match. data=\(String(describing: loadData()))"
        )

        app.typeKey(XCUIKeyboardKey.upArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { $0["browserFindSelected"] == "1" },
            "Expected Up arrow in browser find to select the previous match. data=\(String(describing: loadData()))"
        )
    }

    private enum Pane {
        case terminal
        case browser

        var opposite: Pane { self == .terminal ? .browser : .terminal }
        var focusKey: String { self == .terminal ? "terminal" : "browser" }
        var needleKey: String { self == .terminal ? "terminalFindNeedle" : "browserFindNeedle" }
        var visibleKey: String { self == .terminal ? "terminalFindVisible" : "browserFindVisible" }
        var findFieldId: String { self == .terminal ? "TerminalFindSearchTextField" : "BrowserFindSearchTextField" }
        var findFieldOwnerType: String { self == .terminal ? "SearchNativeTextField" : "BrowserSearchNativeTextField" }
        var replacementMessage: String { self == .terminal ? "terminal find text" : "browser find text" }
        var arrowKey: String {
            self == .terminal ? XCUIKeyboardKey.leftArrow.rawValue : XCUIKeyboardKey.rightArrow.rawValue
        }
    }

    private func openBrowserInRightPane(
        _ app: XCUIApplication,
        url: String = "example.com",
        waitForNavigation: ((XCUIElement) -> Bool)? = nil
    ) {
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [.command, .option])
        app.typeKey("l", modifierFlags: [.command, .shift])
        let omnibar = app.textFields["BrowserOmnibarTextField"].firstMatch
        XCTAssertTrue(omnibar.waitForExistence(timeout: 8.0), "Expected browser omnibar")
        app.typeKey("a", modifierFlags: [.command])
        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        app.typeText(url)
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        if let waitForNavigation {
            XCTAssertTrue(waitForNavigation(omnibar), "Expected browser navigation")
        } else {
            XCTAssertTrue(waitForOmnibarToContainExampleDomain(omnibar, timeout: 8.0), "Expected browser navigation")
        }
    }

    private func assertFindRefocusPreservesSelection(
        _ app: XCUIApplication,
        pane: Pane,
        initial: String,
        replacement: String,
        expected: String
    ) {
        focusPane(pane, app: app)
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { $0["focusedPanelKind"] == pane.focusKey },
            "Expected \(pane.focusKey) focus. data=\(String(describing: loadData()))"
        )
        app.typeKey("f", modifierFlags: [.command])
        let findField = app.textFields[pane.findFieldId].firstMatch
        XCTAssertTrue(
            findField.waitForExistence(timeout: 6.0),
            "Expected \(pane.replacementMessage) field after Cmd+F. data=\(String(describing: loadData()))"
        )
        replaceFindText(app, with: initial)
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [.shift])
        focusPane(pane.opposite, app: app)
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                data["focusedPanelKind"] == pane.opposite.focusKey && data[pane.needleKey] == initial
            },
            "Expected initial \(pane.replacementMessage) before refocus. data=\(String(describing: loadData()))"
        )
        focusPane(pane, app: app)
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { $0["focusedPanelKind"] == pane.focusKey },
            "Expected \(pane.focusKey) focus before repeated Cmd+F. data=\(String(describing: loadData()))"
        )
        app.typeKey("f", modifierFlags: [.command])
        app.typeText(replacement)
        focusPane(pane.opposite, app: app)
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                data["focusedPanelKind"] == pane.opposite.focusKey && data[pane.needleKey] == expected
            },
            "Expected repeated Cmd+F to preserve \(pane.replacementMessage) selection. data=\(String(describing: loadData()))"
        )
    }

    private func assertFindRefocusPreservesCaret(
        _ app: XCUIApplication,
        pane: Pane,
        initial: String,
        insertion: String,
        expected: String
    ) {
        focusPane(pane, app: app)
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { $0["focusedPanelKind"] == pane.focusKey },
            "Expected \(pane.focusKey) focus. data=\(String(describing: loadData()))"
        )
        app.typeKey("f", modifierFlags: [.command])
        let findField = app.textFields[pane.findFieldId].firstMatch
        XCTAssertTrue(
            findField.waitForExistence(timeout: 6.0),
            "Expected \(pane.replacementMessage) field after Cmd+F. data=\(String(describing: loadData()))"
        )
        replaceFindText(app, with: initial)
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
        focusPane(pane.opposite, app: app)
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                data["focusedPanelKind"] == pane.opposite.focusKey && data[pane.needleKey] == initial
            },
            "Expected initial \(pane.replacementMessage) before caret refocus. data=\(String(describing: loadData()))"
        )
        focusPane(pane, app: app)
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { $0["focusedPanelKind"] == pane.focusKey },
            "Expected \(pane.focusKey) focus before repeated Cmd+F. data=\(String(describing: loadData()))"
        )
        app.typeKey("f", modifierFlags: [.command])
        app.typeText(insertion)
        focusPane(pane.opposite, app: app)
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                data["focusedPanelKind"] == pane.opposite.focusKey && data[pane.needleKey] == expected
            },
            "Expected repeated Cmd+F to preserve \(pane.replacementMessage) caret. data=\(String(describing: loadData()))"
        )
    }

    private func enterFindThenEscape(_ app: XCUIApplication, pane: Pane, query: String) {
        focusPane(pane, app: app)
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { $0["focusedPanelKind"] == pane.focusKey },
            "Expected \(pane.focusKey) focus before opening find. data=\(String(describing: loadData()))"
        )
        app.typeKey("f", modifierFlags: [.command])
        let findField = app.textFields[pane.findFieldId].firstMatch
        XCTAssertTrue(
            findField.waitForExistence(timeout: 6.0),
            "Expected \(pane.replacementMessage) field after Cmd+F. data=\(String(describing: loadData()))"
        )
        app.typeText(query)
        focusPane(pane.opposite, app: app)
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                data["focusedPanelKind"] == pane.opposite.focusKey &&
                    data[pane.visibleKey] == "true" &&
                    data[pane.needleKey] == query
            },
            "Expected \(pane.replacementMessage) before Escape. data=\(String(describing: loadData()))"
        )
        focusPane(pane, app: app)
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { $0["focusedPanelKind"] == pane.focusKey },
            "Expected \(pane.focusKey) focus before Escape. data=\(String(describing: loadData()))"
        )
        app.typeKey("f", modifierFlags: [.command])
        let restoredFindField = app.textFields[pane.findFieldId].firstMatch
        XCTAssertTrue(
            restoredFindField.waitForExistence(timeout: 6.0),
            "Expected \(pane.replacementMessage) field before Escape. data=\(String(describing: loadData()))"
        )
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                data["focusedPanelKind"] == pane.focusKey &&
                    data[pane.visibleKey] == "false" &&
                    data[pane.needleKey] == ""
            },
            "Expected Escape to close \(pane.replacementMessage). data=\(String(describing: loadData()))"
        )
    }

    private func assertFindRecoversAndCanReplace(
        _ app: XCUIApplication,
        pane: Pane,
        query: String,
        replacement: String
    ) {
        focusPane(pane, app: app)
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { $0["focusedPanelKind"] == pane.focusKey },
            "Expected \(pane.focusKey) focus before recovering find. data=\(String(describing: loadData()))"
        )
        app.typeKey("f", modifierFlags: [.command])
        let findField = app.textFields[pane.findFieldId].firstMatch
        XCTAssertTrue(
            findField.waitForExistence(timeout: 6.0),
            "Expected \(pane.replacementMessage) field after recovery. data=\(String(describing: loadData()))"
        )
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                data["focusedPanelKind"] == pane.focusKey &&
                    data[pane.visibleKey] == "true" &&
                    data[pane.needleKey] == query
            },
            "Expected Cmd+F to recover \(pane.replacementMessage). data=\(String(describing: loadData()))"
        )
        app.typeText(replacement)
        focusPane(pane.opposite, app: app)
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                data["focusedPanelKind"] == pane.opposite.focusKey &&
                    data[pane.needleKey] == replacement
            },
            "Expected recovered \(pane.replacementMessage) to be selected before replacement. data=\(String(describing: loadData()))"
        )
        focusPane(pane, app: app)
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { $0["focusedPanelKind"] == pane.focusKey },
            "Expected \(pane.focusKey) focus before closing recovered find. data=\(String(describing: loadData()))"
        )
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { $0[pane.visibleKey] == "false" && $0[pane.needleKey] == "" },
            "Expected Escape to close recovered \(pane.replacementMessage). data=\(String(describing: loadData()))"
        )
    }

    private func assertFindArrowEditing(_ app: XCUIApplication, pane: Pane) {
        focusPane(pane, app: app)
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { $0["focusedPanelKind"] == pane.focusKey },
            "Expected \(pane.focusKey) focus before arrow editing. data=\(String(describing: loadData()))"
        )
        app.typeKey("f", modifierFlags: [.command])
        let findField = app.textFields[pane.findFieldId].firstMatch
        XCTAssertTrue(
            findField.waitForExistence(timeout: 6.0),
            "Expected \(pane.replacementMessage) field after Cmd+F. data=\(String(describing: loadData()))"
        )
        replaceFindText(app, with: "abcd")
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [.command])
        app.typeText(">")
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [.command])
        app.typeText("<")
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
        app.typeText("!")
        focusPane(pane.opposite, app: app)
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                return data["focusedPanelKind"] == pane.opposite.focusKey &&
                    data[pane.needleKey] == ">abcd!<"
            },
            "Expected arrow keys to edit \(pane.replacementMessage) while focused. data=\(String(describing: loadData()))"
        )
    }

    private func assertFindCaretSurvivesCmdOptionNavigation(_ app: XCUIApplication, pane: Pane) {
        focusPane(pane, app: app)
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { $0["focusedPanelKind"] == pane.focusKey },
            "Expected \(pane.focusKey) focus before caret navigation. data=\(String(describing: loadData()))"
        )
        app.typeKey("f", modifierFlags: [.command])
        let findField = app.textFields[pane.findFieldId].firstMatch
        XCTAssertTrue(
            findField.waitForExistence(timeout: 6.0),
            "Expected \(pane.replacementMessage) field after Cmd+F. data=\(String(describing: loadData()))"
        )
        replaceFindText(app, with: "abcd")
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                data["focusedPanelKind"] == pane.focusKey &&
                    data[pane.needleKey] == "abcd" &&
                    data["fieldEditorOwnerType"] == pane.findFieldOwnerType &&
                    data["firstResponderSelectedRange"] == "{2, 0}"
            },
            "Expected \(pane.replacementMessage) caret at index 2 before Cmd+Option navigation. data=\(String(describing: loadData()))"
        )

        focusPane(pane.opposite, app: app)
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                data["focusedPanelKind"] == pane.opposite.focusKey &&
                    data[pane.needleKey] == "abcd"
            },
            "Expected Cmd+Option arrow to navigate away without changing \(pane.replacementMessage). data=\(String(describing: loadData()))"
        )
        focusPane(pane, app: app)
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { $0["focusedPanelKind"] == pane.focusKey },
            "Expected Cmd+Option arrow to navigate back to \(pane.focusKey). data=\(String(describing: loadData()))"
        )
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                data["focusedPanelKind"] == pane.focusKey &&
                    data[pane.needleKey] == "abcd" &&
                    data["fieldEditorOwnerType"] == pane.findFieldOwnerType &&
                    data["firstResponderSelectedRange"] == "{2, 0}"
            },
            "Expected Cmd+Option pane navigation to restore \(pane.replacementMessage) focus with caret at index 2. data=\(String(describing: loadData()))"
        )

        app.typeText("z")
        focusPane(pane.opposite, app: app)
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                data["focusedPanelKind"] == pane.opposite.focusKey &&
                    data[pane.needleKey] == "abzcd"
            },
            "Expected insertion after Cmd+Option navigation to use restored \(pane.replacementMessage) caret. data=\(String(describing: loadData()))"
        )
    }

    private func focusPane(_ pane: Pane, app: XCUIApplication) {
        app.typeKey(pane.arrowKey, modifierFlags: [.command, .option])
    }

    private func replaceFindText(_ app: XCUIApplication, with text: String) {
        app.typeKey("a", modifierFlags: [.command])
        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        app.typeText(text)
    }

    private func waitForOmnibarToContainExampleDomain(_ omnibar: XCUIElement, timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            let value = (omnibar.value as? String) ?? ""
            return value.contains("example.com") || value.contains("example.org")
        }
    }

    private func makeBrowserFindMatchesURL() -> String {
        let html = "<!doctype html><meta charset=utf-8><body><p>alpha</p><p>alpha</p><p>alpha</p></body>"
        let encoded = html.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? html
        return "data:text/html;charset=utf-8,\(encoded)"
    }

    private func configuredApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_TAG"] = launchTag
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_RECORD_ONLY"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
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
            _ = app.wait(for: .runningForeground, timeout: 6.0)
        }
        XCTAssertTrue(
            app.state == .runningForeground || app.state == .runningBackground,
            "Expected app to start. state=\(app.state.rawValue)"
        )
        if app.state == .runningBackground {
            XCTAssertTrue(
                app.windows.firstMatch.waitForExistence(timeout: 6.0),
                "Expected background-launched app to expose a window"
            )
            return
        }
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 6.0),
            "Expected app to launch in foreground. state=\(app.state.rawValue)"
        )
    }

    private func waitForDataMatch(timeout: TimeInterval, predicate: @escaping ([String: String]) -> Bool) -> Bool {
        waitForCondition(timeout: timeout) {
            guard let data = self.loadData() else { return false }
            return predicate(data)
        }
    }

    private func loadData() -> [String: String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: dataPath)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
    }

    private func waitForCondition(timeout: TimeInterval, predicate: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in predicate() },
            object: nil
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

}
