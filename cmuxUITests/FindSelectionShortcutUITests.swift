import XCTest
import Foundation

final class FindSelectionShortcutUITests: XCTestCase {
    private var dataPath = ""
    private var socketPath = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        dataPath = "/tmp/cmux-ui-test-find-selection-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: dataPath)
        socketPath = "/tmp/cmux-ui-test-socket-\(UUID().uuidString).sock"
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    func testRepeatedCmdFPreservesOpenTerminalAndBrowserFindCaretAndSelection() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_RECORD_ONLY"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
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
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_RECORD_ONLY"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
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

    private enum Pane {
        case terminal
        case browser

        var opposite: Pane { self == .terminal ? .browser : .terminal }
        var focusKey: String { self == .terminal ? "terminal" : "browser" }
        var needleKey: String { self == .terminal ? "terminalFindNeedle" : "browserFindNeedle" }
        var visibleKey: String { self == .terminal ? "terminalFindVisible" : "browserFindVisible" }
        var findFieldId: String { self == .terminal ? "TerminalFindSearchTextField" : "BrowserFindSearchTextField" }
        var replacementMessage: String { self == .terminal ? "terminal find text" : "browser find text" }
        var arrowKey: String {
            self == .terminal ? XCUIKeyboardKey.leftArrow.rawValue : XCUIKeyboardKey.rightArrow.rawValue
        }
    }

    private func openBrowserInRightPane(_ app: XCUIApplication) {
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [.command, .option])
        app.typeKey("l", modifierFlags: [.command, .shift])
        let omnibar = app.textFields["BrowserOmnibarTextField"].firstMatch
        XCTAssertTrue(omnibar.waitForExistence(timeout: 8.0), "Expected browser omnibar")
        app.typeKey("a", modifierFlags: [.command])
        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        app.typeText("example.com")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(waitForOmnibarToContainExampleDomain(omnibar, timeout: 8.0), "Expected browser navigation")
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

    private func launchAndEnsureForeground(_ app: XCUIApplication) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: options) {
            app.launch()
        }

        if app.state == .runningForeground || app.state == .runningBackground { return }
        XCTFail("App failed to start. state=\(app.state.rawValue)")
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
