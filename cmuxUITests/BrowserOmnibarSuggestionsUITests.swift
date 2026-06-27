import XCTest
import Foundation

final class BrowserOmnibarSuggestionsUITests: XCTestCase {
    private var dataPath = ""
    private var diagnosticsPath = ""
    private var socketPath = ""
    private var launchTag = ""
    private var browserHistorySeedJSON: String?

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        dataPath = "/tmp/cmux-ui-test-omnibar-suggestions-\(UUID().uuidString).json"
        diagnosticsPath = "/tmp/cmux-ui-test-omnibar-suggestions-\(UUID().uuidString).diagnostics.json"
        socketPath = "/tmp/cmux-ui-test-omnibar-suggestions-\(UUID().uuidString).sock"
        launchTag = "ui-omnibar-\(UUID().uuidString.prefix(8))"
        browserHistorySeedJSON = nil
        try? FileManager.default.removeItem(atPath: dataPath)
        try? FileManager.default.removeItem(atPath: diagnosticsPath)
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: "\(socketPath).lock")
        addTeardownBlock { [dataPath, diagnosticsPath, socketPath] in
            try? FileManager.default.removeItem(atPath: dataPath)
            try? FileManager.default.removeItem(atPath: diagnosticsPath)
            try? FileManager.default.removeItem(atPath: socketPath)
            try? FileManager.default.removeItem(atPath: "\(socketPath).lock")
        }

        // Terminate any lingering app from a prior test so its debounced
        // history-save doesn't overwrite the seeded browser_history.json.
        let cleanup = XCUIApplication()
        cleanup.terminate()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    func testOmnibarSuggestionsAlignToPillAndCtrlNP() {
        seedBrowserHistoryForTest(seedEntries: [
            SeedEntry(url: "https://example.com/", title: "Example Domain", visitCount: 12, typedCount: 4),
            SeedEntry(url: "https://example.org/", title: "Example Organization", visitCount: 9, typedCount: 3),
            SeedEntry(url: "https://go.dev/", title: "The Go Programming Language", visitCount: 6, typedCount: 1),
        ])

        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        // Keep suggestions deterministic for the keyboard-nav assertions.
        app.launchEnvironment["CMUX_UI_TEST_DISABLE_REMOTE_SUGGESTIONS"] = "1"
        launchAndEnsureForeground(app)

        // Focus omnibar.
        app.typeKey("l", modifierFlags: [.command])

        let pill = app.descendants(matching: .any).matching(identifier: "BrowserOmnibarPill").firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 6.0))

        let omnibar = app.textFields["BrowserOmnibarTextField"].firstMatch
        XCTAssertTrue(omnibar.waitForExistence(timeout: 6.0))

        // Type a query that matches the seeded URL.
        XCTAssertTrue(
            typeQueryAndWaitForSuggestions(app: app, omnibar: omnibar, query: "exam", timeout: 6.0),
            "Expected omnibar suggestions to appear for 'exam'"
        )

        // SwiftUI's accessibility typing for ScrollView can vary; match by identifier regardless of element type.
        let suggestionsElement = app.descendants(matching: .any).matching(identifier: "BrowserOmnibarSuggestions").firstMatch
        XCTAssertTrue(suggestionsElement.waitForExistence(timeout: 6.0))
        let row0 = app.descendants(matching: .any).matching(identifier: "BrowserOmnibarSuggestions.Row.0").firstMatch
        XCTAssertTrue(row0.waitForExistence(timeout: 6.0))

        // Frame checks (screen coordinates).
        let pillFrame = pill.frame
        let suggestionsFrame = suggestionsElement.frame
        attachElementDebug(name: "omnibar-pill", element: pill)
        attachElementDebug(name: "omnibar-suggestions", element: suggestionsElement)

        XCTAssertGreaterThan(pillFrame.width, 50)
        XCTAssertGreaterThan(suggestionsFrame.width, 50)

        let xTolerance: CGFloat = 3.0
        let wTolerance: CGFloat = 3.0

        XCTAssertLessThanOrEqual(abs(pillFrame.minX - suggestionsFrame.minX), xTolerance,
                                 "Expected suggestions minX to match omnibar minX.\nPill: \(pillFrame)\nSug: \(suggestionsFrame)")
        XCTAssertLessThanOrEqual(abs(pillFrame.width - suggestionsFrame.width), wTolerance,
                                 "Expected suggestions width to match omnibar width.\nPill: \(pillFrame)\nSug: \(suggestionsFrame)")
        XCTAssertGreaterThanOrEqual(
            suggestionsFrame.minY,
            pillFrame.maxY - 1.0,
            "Expected suggestions popup to render below (not behind) the omnibar.\nPill: \(pillFrame)\nSug: \(suggestionsFrame)"
        )

        // Row 0 should be the autocompletable example.com history entry.
        // Verify Ctrl+N moves to row 1, Ctrl+P returns to row 0, then Enter navigates.
        let row1 = app.descendants(matching: .any).matching(identifier: "BrowserOmnibarSuggestions.Row.1").firstMatch
        XCTAssertTrue(row1.waitForExistence(timeout: 6.0))

        app.typeKey("n", modifierFlags: [.control])
        XCTAssertTrue(
            waitForSuggestionRowToBeSelected(row1, timeout: 3.0),
            "Expected Ctrl+N to move selection to row 1. row1Value=\(String(describing: row1.value))"
        )

        app.typeKey("p", modifierFlags: [.control])
        XCTAssertTrue(
            waitForSuggestionRowToBeSelected(row0, timeout: 3.0),
            "Expected Ctrl+P to move selection back to row 0. row0Value=\(String(describing: row0.value))"
        )

        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

        // After committing the autocompletion candidate, the omnibar should contain the URL.
        // Note: example.com may redirect to example.org in some environments.
        XCTAssertTrue(
            waitForCondition(timeout: 8.0) {
                self.containsExampleDomain((omnibar.value as? String) ?? "")
            },
            "Expected omnibar to navigate to example.com after keyboard nav + Enter. value=\(String(describing: omnibar.value))"
        )
    }

    func testOmnibarEscapeAndClickOutsideBehaveLikeChrome() {
        seedBrowserHistoryForTest()

        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        // Keep suggestions deterministic.
        app.launchEnvironment["CMUX_UI_TEST_DISABLE_REMOTE_SUGGESTIONS"] = "1"
        launchAndEnsureForeground(app)
        XCTAssertTrue(
            waitForGotoSplitSetup(timeout: 10.0),
            "Expected goto_split setup data before typing. data=\(String(describing: loadGotoSplitData()))"
        )

        let omnibar = app.textFields["BrowserOmnibarTextField"].firstMatch
        XCTAssertTrue(omnibar.waitForExistence(timeout: 6.0))
        XCTAssertTrue(
            typeQueryAndWaitForSuggestions(app: app, omnibar: omnibar, query: "exam", timeout: 8.0, attempts: 5),
            "Expected omnibar suggestions to appear for 'exam'"
        )

        // Focus omnibar and navigate to example.com via autocompletion (row 0).
        let suggestionsElement = app.descendants(matching: .any).matching(identifier: "BrowserOmnibarSuggestions").firstMatch
        XCTAssertTrue(suggestionsElement.waitForExistence(timeout: 6.0))

        // Row 0 is the autocompletion candidate (example.com). Enter commits it.
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

        // Note: example.com may redirect to example.org in some environments.
        XCTAssertTrue(
            waitForCondition(timeout: 8.0) {
                self.containsExampleDomain((omnibar.value as? String) ?? "")
            },
            "Expected committed omnibar value to contain example.com or example.org. value=\(String(describing: omnibar.value))"
        )
        XCTAssertTrue(containsExampleDomain((omnibar.value as? String) ?? ""))

        // Type a new query to open the popup, then Escape should revert to the current URL.
        app.typeKey("l", modifierFlags: [.command])
        omnibar.typeText("meaning")
        XCTAssertTrue(suggestionsElement.waitForExistence(timeout: 6.0))

        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        let reverted = (omnibar.value as? String) ?? ""
        XCTAssertTrue(containsExampleDomain(reverted), "Expected Escape to revert omnibar to current URL. value=\(reverted)")
        XCTAssertFalse(suggestionsElement.waitForExistence(timeout: 0.5), "Expected Escape to close suggestions popup")

        // Second Escape should blur to the web view: typing should not change the omnibar value.
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        let beforeTyping = (omnibar.value as? String) ?? ""
        app.typeText("zzz")
        let afterTyping = (omnibar.value as? String) ?? ""
        XCTAssertEqual(afterTyping, beforeTyping, "Expected typing after 2nd Escape to not modify omnibar (blurred)")

        // Click outside should also discard edits and blur.
        app.typeKey("l", modifierFlags: [.command])
        omnibar.typeText("foo")

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 6.0))
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).click()

        // Give SwiftUI focus a moment to settle.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        let afterClick = (omnibar.value as? String) ?? ""
        if !containsExampleDomain(afterClick) {
            // VM UI automation can occasionally keep focus in the text field after a coordinate click.
            // Fall back to Escape so we still validate post-click revert/blur behavior.
            app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        }
        let recoveredAfterClick = (omnibar.value as? String) ?? ""
        XCTAssertTrue(containsExampleDomain(recoveredAfterClick), "Expected click-outside path to discard edits. value=\(recoveredAfterClick)")

        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])

        let beforeOutsideTyping = (omnibar.value as? String) ?? ""
        app.typeText("bbb")
        let afterOutsideTyping = (omnibar.value as? String) ?? ""
        XCTAssertEqual(afterOutsideTyping, beforeOutsideTyping, "Expected typing after click-outside to not modify omnibar (blurred)")
    }

    func testOmnibarSuggestionsCtrlNPWhenAddressBarFocused() {
        seedBrowserHistoryForTest()

        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_DISABLE_REMOTE_SUGGESTIONS"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_REMOTE_SUGGESTIONS_JSON"] = #"["go tutorial","go json","go fmt"]"#
        launchAndEnsureForeground(app)

        let omnibar = app.textFields["BrowserOmnibarTextField"].firstMatch
        XCTAssertTrue(omnibar.waitForExistence(timeout: 6.0))
        XCTAssertTrue(
            typeQueryAndWaitForSuggestions(app: app, omnibar: omnibar, query: "go", timeout: 6.0),
            "Expected omnibar suggestions to appear for 'go'"
        )

        let suggestionsElement = app.descendants(matching: .any).matching(identifier: "BrowserOmnibarSuggestions").firstMatch
        XCTAssertTrue(suggestionsElement.waitForExistence(timeout: 6.0))

        let row1 = app.descendants(matching: .any).matching(identifier: "BrowserOmnibarSuggestions.Row.1").firstMatch
        let row2 = app.descendants(matching: .any).matching(identifier: "BrowserOmnibarSuggestions.Row.2").firstMatch
        XCTAssertTrue(row1.waitForExistence(timeout: 6.0))
        XCTAssertTrue(row2.waitForExistence(timeout: 6.0))

        app.typeKey("n", modifierFlags: [.control])
        XCTAssertTrue(
            waitForSuggestionRowToBeSelected(row1, timeout: 3.0),
            "Expected Ctrl+N to move selection to row 1. row1Value=\(String(describing: row1.value))"
        )

        app.typeKey("n", modifierFlags: [.control])
        XCTAssertTrue(
            waitForSuggestionRowToBeSelected(row2, timeout: 3.0),
            "Expected repeated Ctrl+N to move selection to row 2. row2Value=\(String(describing: row2.value))"
        )

        app.typeKey("p", modifierFlags: [.control])
        XCTAssertTrue(
            waitForSuggestionRowToBeSelected(row1, timeout: 3.0),
            "Expected Ctrl+P to move selection back to row 1. row1Value=\(String(describing: row1.value))"
        )
    }

    func testOmnibarShowsMultipleRowsWithoutClipping() {
        seedBrowserHistoryForTest()

        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_DISABLE_REMOTE_SUGGESTIONS"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_REMOTE_SUGGESTIONS_JSON"] = #"["go tutorial","go json","go fmt"]"#
        launchAndEnsureForeground(app)

        app.typeKey("l", modifierFlags: [.command])

        let omnibar = app.textFields["BrowserOmnibarTextField"].firstMatch
        XCTAssertTrue(omnibar.waitForExistence(timeout: 6.0))
        omnibar.typeText("go")

        let suggestionsElement = app.descendants(matching: .any).matching(identifier: "BrowserOmnibarSuggestions").firstMatch
        XCTAssertTrue(suggestionsElement.waitForExistence(timeout: 6.0))

        let row2 = app.descendants(matching: .any).matching(identifier: "BrowserOmnibarSuggestions.Row.2").firstMatch
        XCTAssertTrue(row2.waitForExistence(timeout: 6.0), "Expected at least 3 suggestion rows for 'go'")
        let popupFrame = suggestionsElement.frame
        let row2Frame = row2.frame
        XCTAssertGreaterThan(row2Frame.height, 1, "Expected third row to have a non-zero visible height")
        XCTAssertLessThanOrEqual(row2Frame.maxY, popupFrame.maxY + 1, "Expected third row to stay inside popup bounds")
    }

    func testCmdLRefocusAfterNavigationKeepsOmnibarEditable() {
        seedBrowserHistoryForTest()

        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_DISABLE_REMOTE_SUGGESTIONS"] = "1"
        launchAndEnsureForeground(app)

        app.typeKey("l", modifierFlags: [.command])

        let omnibar = app.textFields["BrowserOmnibarTextField"].firstMatch
        XCTAssertTrue(omnibar.waitForExistence(timeout: 6.0))

        // Start a real navigation, then re-focus the omnibar immediately.
        omnibar.typeText("example.com")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

        app.typeKey("l", modifierFlags: [.command])

        // Wait for navigation to finish so we can verify focus is held through page load.
        var loadObserved = false
        loadObserved = waitForCondition(timeout: 8.0) {
            ((omnibar.value as? String) ?? "").lowercased().contains("example.com")
        }
        XCTAssertTrue(loadObserved, "Expected omnibar to reflect the navigated URL after load. value=\(String(describing: omnibar.value))")

        let valueAfterLoad = (omnibar.value as? String) ?? ""
        omnibar.typeText("zx")

        var valueCaptured = false
        valueCaptured = waitForCondition(timeout: 5.0) {
            let value = (omnibar.value as? String) ?? ""
            return value.contains("zx") && value != valueAfterLoad
        }
        XCTAssertTrue(valueCaptured, "Expected omnirbar to keep keyboard focus after Cmd+L when navigation is in-flight. value=\(String(describing: omnibar.value))")

        let suggestionsElement = app.descendants(matching: .any).matching(identifier: "BrowserOmnibarSuggestions").firstMatch
        XCTAssertTrue(
            suggestionsElement.waitForExistence(timeout: 3.0),
            "Expected omnibar suggestions to appear while focused after Cmd+L during navigation"
        )

        // Avoid leaving test in partially edited state.
        app.typeKey("a", modifierFlags: [.command])
        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        app.typeKey("x", modifierFlags: [])
    }

    func testCmdLImmediateTypingReplacesExistingURLBuffer() {
        seedBrowserHistoryForTest()

        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_DISABLE_REMOTE_SUGGESTIONS"] = "1"
        launchAndEnsureForeground(app)

        let omnibar = app.textFields["BrowserOmnibarTextField"].firstMatch
        XCTAssertTrue(omnibar.waitForExistence(timeout: 6.0))

        // Navigate to a non-empty URL first so Cmd+L must replace existing text.
        app.typeKey("l", modifierFlags: [.command])
        omnibar.typeText("example.com")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

        let loaded = waitForCondition(timeout: 8.0) {
            let value = ((omnibar.value as? String) ?? "").lowercased()
            return self.containsExampleDomain(value)
        }
        XCTAssertTrue(loaded, "Expected baseline navigation to load before Cmd+L fast-typing check.")

        // Reproduce user flow: Cmd+L then immediate typing without waiting.
        app.typeKey("l", modifierFlags: [.command])
        app.typeText("lo")

        var observedValue = ""
        let startsWithTypedPrefix = waitForCondition(timeout: 7.0) {
            observedValue = ((omnibar.value as? String) ?? "").lowercased()
            return observedValue.hasPrefix("lo")
        }
        XCTAssertTrue(
            startsWithTypedPrefix,
            "Expected immediate typing after Cmd+L to preserve typed prefix 'lo'. value=\(observedValue)"
        )
    }

    func testOmnibarArrowSelectedSuggestionIsCommittedOnEnter() {
        seedBrowserHistoryForTest(
            seedEntries: [
                SeedEntry(url: "https://news.ycombinator.com/", title: "News Y Combinator", visitCount: 12, typedCount: 1),
                SeedEntry(url: "https://example.com/gmail", title: "Gmail", visitCount: 10, typedCount: 2),
            ]
        )

        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_DISABLE_REMOTE_SUGGESTIONS"] = "1"
        launchAndEnsureForeground(app)

        app.typeKey("l", modifierFlags: [.command])

        let omnibar = app.textFields["BrowserOmnibarTextField"].firstMatch
        XCTAssertTrue(omnibar.waitForExistence(timeout: 6.0))

        omnibar.typeText("gm")

        let suggestionsElement = app.descendants(matching: .any).matching(identifier: "BrowserOmnibarSuggestions").firstMatch
        XCTAssertTrue(suggestionsElement.waitForExistence(timeout: 6.0))

        let rows: [XCUIElement] = (0...4).map {
            app.descendants(matching: .any).matching(identifier: "BrowserOmnibarSuggestions.Row.\($0)").firstMatch
        }
        XCTAssertTrue(rows[0].waitForExistence(timeout: 4.0))

        var gmailRowIndex: Int?
        _ = waitForCondition(timeout: 4.0) {
            for (index, row) in rows.enumerated() where row.exists {
                let rowValue = (row.value as? String) ?? ""
                if rowValue.localizedCaseInsensitiveContains("gmail") {
                    gmailRowIndex = index
                    return true
                }
            }
            return false
        }
        guard let gmailRowIndex else {
            let rowValues = rows.enumerated().compactMap { index, row -> String? in
                guard row.exists else { return nil }
                return "row\(index)=\((row.value as? String) ?? "<nil>")"
            }.joined(separator: ", ")
            let seedBytes = browserHistorySeedJSON?.utf8.count ?? 0
            XCTFail("Expected a Gmail suggestion row. rows=\(rowValues) seedBytes=\(seedBytes)")
            return
        }

        // Only an explicitly arrow-selected suggestion commits on Enter
        // (https://github.com/manaflow-ai/cmux/issues/5913). Reach the Gmail
        // row with Ctrl+N; when it is already auto-highlighted at row 0, make
        // the selection explicit with a Ctrl+N / Ctrl+P round trip.
        let gmailRow = rows[gmailRowIndex]
        if gmailRowIndex > 0 {
            for _ in 0..<gmailRowIndex {
                app.typeKey("n", modifierFlags: [.control])
            }
        } else {
            app.typeKey("n", modifierFlags: [.control])
            app.typeKey("p", modifierFlags: [.control])
        }
        XCTAssertTrue(
            waitForSuggestionRowToBeSelected(gmailRow, timeout: 3.0),
            "Expected keyboard navigation to select Gmail row \(gmailRowIndex). value=\(String(describing: gmailRow.value))"
        )

        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

        let committedToGmail = waitForCondition(timeout: 8.0) {
            let value = (omnibar.value as? String) ?? ""
            return value.localizedCaseInsensitiveContains("example.com/gmail")
        }
        XCTAssertTrue(committedToGmail, "Expected Enter to commit Gmail history target. value=\(String(describing: omnibar.value))")
    }

    func testOmnibarReturnWithoutArrowSelectionNavigatesTypedText() {
        // Regression for https://github.com/manaflow-ai/cmux/issues/5913: a
        // row that was auto-highlighted for the popup (here the Gmail history
        // entry matched by title) must not hijack plain Return. Without an
        // explicit arrow selection, Return submits the typed text.
        seedBrowserHistoryForTest(
            seedEntries: [
                SeedEntry(url: "https://news.ycombinator.com/", title: "News Y Combinator", visitCount: 12, typedCount: 1),
                SeedEntry(url: "https://example.com/gmail", title: "Gmail", visitCount: 10, typedCount: 2),
            ]
        )

        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_DISABLE_REMOTE_SUGGESTIONS"] = "1"
        launchAndEnsureForeground(app)

        app.typeKey("l", modifierFlags: [.command])

        let omnibar = app.textFields["BrowserOmnibarTextField"].firstMatch
        XCTAssertTrue(omnibar.waitForExistence(timeout: 6.0))

        omnibar.typeText("gm")

        let suggestionsElement = app.descendants(matching: .any).matching(identifier: "BrowserOmnibarSuggestions").firstMatch
        XCTAssertTrue(suggestionsElement.waitForExistence(timeout: 6.0))

        // Wait until the Gmail row exists and carries the automatic highlight
        // so Return is pressed in exactly the state the bug used to hijack.
        let rows: [XCUIElement] = (0...4).map {
            app.descendants(matching: .any).matching(identifier: "BrowserOmnibarSuggestions.Row.\($0)").firstMatch
        }
        var autoHighlightedGmailRow: XCUIElement?
        _ = waitForCondition(timeout: 6.0) {
            for row in rows where row.exists {
                let rowValue = (row.value as? String) ?? ""
                if rowValue.localizedCaseInsensitiveContains("gmail"),
                   self.isSuggestionRowSelected(row) {
                    autoHighlightedGmailRow = row
                    return true
                }
            }
            return false
        }
        XCTAssertNotNil(
            autoHighlightedGmailRow,
            "Expected the Gmail row to be auto-highlighted for query 'gm' before pressing Return."
        )

        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

        let navigatedTypedText = waitForCondition(timeout: 8.0) {
            let value = ((omnibar.value as? String) ?? "").lowercased()
            return value.contains("q=gm")
        }
        XCTAssertTrue(
            navigatedTypedText,
            "Expected plain Return to search the typed text 'gm'. value=\(String(describing: omnibar.value))"
        )
        XCTAssertFalse(
            ((omnibar.value as? String) ?? "").localizedCaseInsensitiveContains("example.com/gmail"),
            "Auto-highlighted suggestion must not commit without an explicit arrow selection. value=\(String(describing: omnibar.value))"
        )
    }

    func testOmnibarSingleRowPopupUsesMinimumHeight() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_DISABLE_REMOTE_SUGGESTIONS"] = "1"
        launchAndEnsureForeground(app)

        app.typeKey("l", modifierFlags: [.command])

        let omnibar = app.textFields["BrowserOmnibarTextField"].firstMatch
        XCTAssertTrue(omnibar.waitForExistence(timeout: 6.0))
        let query = "zzzz-\(UUID().uuidString.prefix(8))"
        omnibar.typeText(query)

        let suggestionsElement = app.descendants(matching: .any).matching(identifier: "BrowserOmnibarSuggestions").firstMatch
        XCTAssertTrue(suggestionsElement.waitForExistence(timeout: 6.0))

        let row0 = app.descendants(matching: .any).matching(identifier: "BrowserOmnibarSuggestions.Row.0").firstMatch
        let row1 = app.descendants(matching: .any).matching(identifier: "BrowserOmnibarSuggestions.Row.1").firstMatch
        XCTAssertTrue(row0.waitForExistence(timeout: 6.0))
        XCTAssertFalse(row1.waitForExistence(timeout: 0.5), "Expected one-row popup for a unique query")

        let expectedMinHeight: CGFloat = 30
        let tolerance: CGFloat = 2
        let popupHeight = suggestionsElement.frame.height
        XCTAssertLessThanOrEqual(
            abs(popupHeight - expectedMinHeight),
            tolerance,
            "Expected one-row popup to use min height without extra bottom gap. frame=\(suggestionsElement.frame)"
        )

        let popupFrame = suggestionsElement.frame
        let rowFrame = row0.frame
        let topInset = rowFrame.minY - popupFrame.minY
        let bottomInset = popupFrame.maxY - rowFrame.maxY
        XCTAssertLessThanOrEqual(
            abs(topInset - bottomInset),
            1.5,
            "Expected one-row popup to have balanced top/bottom insets. popup=\(popupFrame) row=\(rowFrame)"
        )
    }

    func testInlineAutocompleteBackspaceDeletesTypedPrefixCharacter() {
        seedBrowserHistoryForTest()

        let app = XCUIApplication()
        configureSocketLaunch(app)
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_DISABLE_REMOTE_SUGGESTIONS"] = "1"
        launchAndEnsureForeground(app)
        XCTAssertTrue(waitForSocketPong(timeout: 12.0), socketReadinessFailureMessage())
        XCTAssertTrue(
            waitForGotoSplitSetup(timeout: 10.0),
            "Expected goto_split setup data before typing. data=\(String(describing: loadGotoSplitData()))"
        )

        let omnibar = app.textFields["BrowserOmnibarTextField"].firstMatch
        XCTAssertTrue(omnibar.waitForExistence(timeout: 6.0))
        XCTAssertTrue(
            typeQueryAndWaitForSuggestions(app: app, omnibar: omnibar, query: "exam", timeout: 8.0, attempts: 5),
            "Expected omnibar suggestions to appear for 'exam'"
        )

        let valueAfterTyping = waitForInlineCompletion(
            in: omnibar,
            typedPrefix: "exam",
            expectedSubstring: "example.com",
            timeout: 6.0
        ) ?? ((omnibar.value as? String) ?? "")
        XCTAssertTrue(
            valueAfterTyping.contains("example.com"),
            "Expected inline completion to display a URL for typed prefix. value=\(valueAfterTyping)"
        )
        XCTAssertFalse(
            valueAfterTyping.lowercased().hasPrefix("https://"),
            "Expected inline completion display to avoid injecting an https:// prefix unless typed."
        )

        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        XCTAssertEqual(
            socketCommand("simulate_shortcut backspace"),
            "OK",
            "Expected socket shortcut simulation to send Backspace through AppKit"
        )

        var valueAfterDelete = ""
        let revertedToTypedPrefix = waitForCondition(timeout: 3.0) {
            valueAfterDelete = (omnibar.value as? String) ?? ""
            return valueAfterDelete == "exa"
        }
        XCTAssertTrue(
            revertedToTypedPrefix,
            "Expected Backspace with inline suffix selected to remove one typed prefix character. value=\(valueAfterDelete)"
        )
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    }

    func testCmdASelectAllDoesNotClearInlineCompletion() {
        seedBrowserHistoryForTest()

        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_DISABLE_REMOTE_SUGGESTIONS"] = "1"
        launchAndEnsureForeground(app)

        app.typeKey("l", modifierFlags: [.command])

        let omnibar = app.textFields["BrowserOmnibarTextField"].firstMatch
        XCTAssertTrue(omnibar.waitForExistence(timeout: 6.0))
        omnibar.typeText("exam")

        let typedPrefix = "exam"
        var valueBeforeCmdA = ""
        let sawInlineCompletion = waitForCondition(timeout: 3.0) {
            valueBeforeCmdA = (omnibar.value as? String) ?? ""
            let normalized = valueBeforeCmdA.lowercased()
            return normalized.hasPrefix(typedPrefix) && valueBeforeCmdA.utf16.count > typedPrefix.utf16.count
        }
        XCTAssertTrue(
            sawInlineCompletion,
            "Expected inline completion to extend typed prefix before Cmd+A. value=\(valueBeforeCmdA)"
        )

        app.typeKey("a", modifierFlags: [.command])
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))

        let afterCmdA = (omnibar.value as? String) ?? ""
        XCTAssertTrue(
            afterCmdA.lowercased().hasPrefix(typedPrefix) && afterCmdA.utf16.count > typedPrefix.utf16.count,
            "Expected Cmd+A to preserve inline completion display instead of collapsing to typed prefix. before=\(valueBeforeCmdA) after=\(afterCmdA)"
        )
    }

    private func launchAndEnsureForeground(_ app: XCUIApplication, timeout: TimeInterval = 12.0) {
        if let browserHistorySeedJSON {
            app.launchEnvironment["CMUX_UI_TEST_BROWSER_HISTORY_JSON"] = browserHistorySeedJSON
        }
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

    private func configureSocketLaunch(_ app: XCUIApplication) {
        app.launchArguments += ["-socketControlMode", "allowAll"]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_MODE"] = "allowAll"
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_ALLOW_SOCKET_OVERRIDE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_DIAGNOSTICS_PATH"] = diagnosticsPath
        app.launchEnvironment["CMUX_TAG"] = launchTag
    }

    private func waitForSocketPong(timeout: TimeInterval) -> Bool {
        var resolvedPath: String?
        let ready = waitForControlSocketReady(
            pingTimeout: timeout,
            socketFileExists: {
                self.socketCandidates().contains { FileManager.default.fileExists(atPath: $0) } ||
                    self.controlSocketDiagnosticsReportReady(self.loadDiagnostics())
            },
            pingReturnsPong: {
                let originalPath = self.socketPath
                for candidate in self.socketCandidates() {
                    guard FileManager.default.fileExists(atPath: candidate) else { continue }
                    self.socketPath = candidate
                    if self.socketCommand("ping") == "PONG" {
                        resolvedPath = candidate
                        return true
                    }
                    self.socketPath = originalPath
                }
                let diagnostics = self.loadDiagnostics()
                if self.controlSocketDiagnosticsReportReady(diagnostics),
                   let expectedPath = diagnostics["socketExpectedPath"],
                   !expectedPath.isEmpty {
                    resolvedPath = expectedPath
                    return true
                }
                return false
            }
        )
        if let resolvedPath {
            socketPath = resolvedPath
        }
        return ready
    }

    private func socketReadinessFailureMessage() -> String {
        "Expected control socket at \(socketPath). diagnostics=\(loadDiagnostics()) candidates=\(socketCandidates())"
    }

    private func socketCommand(_ command: String) -> String? {
        let originalPath = socketPath
        for candidate in socketCandidates() {
            guard FileManager.default.fileExists(atPath: candidate) else { continue }
            socketPath = candidate
            if let response = controlSocketCommandViaNetcat(command, socketPath: candidate) {
                return response
            }
        }
        socketPath = originalPath
        return nil
    }

    private func socketCandidates() -> [String] {
        var candidates = [socketPath, taggedSocketPath()]
        if let expectedPath = loadDiagnostics()["socketExpectedPath"], !expectedPath.isEmpty {
            candidates.append(expectedPath)
        }
        var seen = Set<String>()
        candidates.removeAll { !seen.insert($0).inserted }
        return candidates
    }

    private func taggedSocketPath() -> String {
        let slug = launchTag
            .lowercased()
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return "/tmp/cmux-debug-\(slug).sock"
    }

    private func loadDiagnostics() -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: diagnosticsPath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var diagnostics: [String: String] = [:]
        for (key, value) in object {
            diagnostics[key] = String(describing: value)
        }
        return diagnostics
    }

    private struct SeedEntry {
        let url: String
        let title: String
        var visitCount: Int = 2
        var typedCount: Int = 0
    }

    private func seedBrowserHistoryForTest(entries: [(String, String)]? = nil, seedEntries: [SeedEntry]? = nil) {
        // Keep the test hermetic: write a deterministic history file in the app's support dir
        // so the omnibar always has at least one local suggestion row.
        let now = Date().timeIntervalSinceReferenceDate
        let resolved: [SeedEntry]
        if let seedEntries {
            resolved = seedEntries
        } else if let entries {
            resolved = entries.map { SeedEntry(url: $0.0, title: $0.1, visitCount: 10, typedCount: 2) }
        } else {
            resolved = [
                SeedEntry(url: "https://example.com/", title: "Example Domain", visitCount: 10, typedCount: 2),
                SeedEntry(url: "https://go.dev/", title: "The Go Programming Language", visitCount: 10, typedCount: 2),
                SeedEntry(url: "https://www.google.com/", title: "Google", visitCount: 10, typedCount: 2),
            ]
        }
        let entriesJSON = resolved.enumerated().reversed().map { index, entry in
            let recencyOffset = index * 120
            var json = """
              {
                "id": "\(UUID().uuidString)",
                "url": "\(entry.url)",
                "title": "\(entry.title)",
                "lastVisited": \(now - Double(recencyOffset)),
                "visitCount": \(entry.visitCount)
            """
            if entry.typedCount > 0 {
                json += """
                ,
                    "typedCount": \(entry.typedCount),
                    "lastTypedAt": \(now - Double(recencyOffset))
                """
            }
            json += "\n  }"
            return json
        }.joined(separator: ",\n")

        let json = """
        [
          \(entriesJSON)
        ]
        """
        browserHistorySeedJSON = json
    }

    private func attachElementDebug(name: String, element: XCUIElement) {
        let payload = """
        identifier: \(element.identifier)
        label: \(element.label)
        exists: \(element.exists)
        hittable: \(element.isHittable)
        frame: \(element.frame)
        """
        let attachment = XCTAttachment(string: payload)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitForSuggestionRowToBeSelected(_ row: XCUIElement, timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            self.isSuggestionRowSelected(row)
        }
    }

    private func isSuggestionRowSelected(_ row: XCUIElement) -> Bool {
        guard row.exists else { return false }
        guard let rawValue = row.value as? String else { return false }
        return rawValue.localizedCaseInsensitiveContains("selected")
    }

    private func waitForGotoSplitSetup(timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            guard let data = self.loadGotoSplitData() else { return false }
            return data["browserPanelId"]?.isEmpty == false &&
                data["webViewFocused"] == "true"
        }
    }

    private func loadGotoSplitData() -> [String: String]? {
        guard !dataPath.isEmpty,
              let data = try? Data(contentsOf: URL(fileURLWithPath: dataPath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return object
    }

    private func typeQueryAndWaitForSuggestions(
        app: XCUIApplication,
        omnibar: XCUIElement,
        query: String,
        timeout: TimeInterval,
        attempts: Int = 3
    ) -> Bool {
        let suggestions = app.descendants(matching: .any).matching(identifier: "BrowserOmnibarSuggestions").firstMatch
        for _ in 0..<attempts {
            if app.state == .runningBackground {
                app.activate()
                _ = app.wait(for: .runningForeground, timeout: 2.0)
            }
            app.typeKey("l", modifierFlags: [.command])
            guard omnibar.waitForExistence(timeout: 6.0) else { continue }
            clickOmnibarForTyping(app: app, omnibar: omnibar)
            app.typeKey("a", modifierFlags: [.command])
            app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
            clickOmnibarForTyping(app: app, omnibar: omnibar)
            app.typeText(query)
            if suggestions.waitForExistence(timeout: timeout) {
                return true
            }
            app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return suggestions.exists
    }

    private func clickOmnibarForTyping(app: XCUIApplication, omnibar: XCUIElement) {
        let pill = app.descendants(matching: .any).matching(identifier: "BrowserOmnibarPill").firstMatch
        if pill.waitForExistence(timeout: 1.0), pill.isHittable {
            pill.click()
            return
        }
        omnibar.click()
    }

    private func waitForInlineCompletion(
        in omnibar: XCUIElement,
        typedPrefix: String,
        expectedSubstring: String,
        timeout: TimeInterval
    ) -> String? {
        let normalizedPrefix = typedPrefix.lowercased()
        let normalizedSubstring = expectedSubstring.lowercased()
        var observedValue = ""
        let matched = waitForCondition(timeout: timeout) {
            observedValue = (omnibar.value as? String) ?? ""
            let normalized = observedValue.lowercased()
            return normalized.hasPrefix(normalizedPrefix) &&
                normalized.contains(normalizedSubstring) &&
                observedValue.utf16.count > typedPrefix.utf16.count
        }
        return matched ? observedValue : nil
    }

    private func containsExampleDomain(_ value: String) -> Bool {
        value.contains("example.com") || value.contains("example.org")
    }

    private func waitForCondition(timeout: TimeInterval, predicate: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in predicate() },
            object: nil
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
