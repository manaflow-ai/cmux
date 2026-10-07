import XCTest
import Foundation

/// Tests that goto_split:previous and goto_split:next cycle through ALL panes
/// regardless of split direction (horizontal and vertical), wrapping at the ends.
///
/// Before the fix, goto_split:previous/next were mapped to directional left/right
/// navigation in Bonsplit, which skipped vertically-split panes and did not wrap.
final class GotoSplitCycleUITests: XCTestCase {
    private var dataPath = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        dataPath = "/tmp/cmux-ui-test-goto-split-cycle-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: dataPath)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dataPath)
        super.tearDown()
    }

    // MARK: - Tests

    func testGotoSplitNextCyclesAllPanes() {
        verifyCycleNavigation(
            shortcutKey: "ghosttyGotoSplitNextShortcut",
            directionName: "next",
            step: 1
        )
    }

    func testGotoSplitPreviousCyclesAllPanes() {
        verifyCycleNavigation(
            shortcutKey: "ghosttyGotoSplitPreviousShortcut",
            directionName: "previous",
            step: -1
        )
    }

    private func verifyCycleNavigation(
        shortcutKey: String,
        directionName: String,
        step: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // Uses the Ghostty trigger loaded by the app for goto_split:previous/next.
        let (app, configCleanup) = launchWithThreePaneLayout()
        defer { configCleanup() }

        XCTAssertTrue(
            waitForData(
                keys: ["setupComplete", "allPaneIds", "focusedPaneId", shortcutKey],
                timeout: 10.0
            ),
            "Expected three-pane setup data to be written",
            file: file,
            line: line
        )

        guard let setup = loadData() else {
            XCTFail("Missing setup data", file: file, line: line)
            return
        }
        XCTAssertEqual(setup["paneCount"], "3", "Expected 3 panes", file: file, line: line)

        guard let allPaneIdsRaw = setup["allPaneIds"] else {
            XCTFail("Missing allPaneIds in setup data", file: file, line: line)
            return
        }
        let orderedPaneIds = allPaneIdsRaw.split(separator: ",").map(String.init)
        let allPaneIds = Set(orderedPaneIds)
        XCTAssertEqual(allPaneIds.count, 3, "Expected 3 distinct pane IDs", file: file, line: line)

        guard let startPane = setup["focusedPaneId"] else {
            XCTFail("Missing focusedPaneId in setup data", file: file, line: line)
            return
        }
        XCTAssertTrue(allPaneIds.contains(startPane), "Start pane should be in allPaneIds", file: file, line: line)
        guard let startIndex = orderedPaneIds.firstIndex(of: startPane) else {
            XCTFail("Start pane missing from ordered pane IDs", file: file, line: line)
            return
        }
        let shortcut = setup[shortcutKey] ?? ""
        XCTAssertFalse(shortcut.isEmpty, "Expected Ghostty goto_split:\(directionName) shortcut", file: file, line: line)

        let expectedVisited = (0...3).map { offset in
            let rawIndex = startIndex + (step * offset)
            let wrappedIndex = (rawIndex % orderedPaneIds.count + orderedPaneIds.count) % orderedPaneIds.count
            return orderedPaneIds[wrappedIndex]
        }

        // Send the shortcut 3 times: visit all panes once, then wrap to the start.
        var visited = [startPane]
        for i in 0..<3 {
            guard typeShortcut(shortcut, in: app, file: file, line: line) else { return }
            let expectedPane = expectedVisited[i + 1]

            XCTAssertTrue(
                waitForDataMatch(timeout: 10.0) { data in
                    data["focusedPaneId"] == expectedPane
                },
                "goto_split:\(directionName) #\(i + 1) did not focus expected pane \(shortPaneId(expectedPane))",
                file: file,
                line: line
            )

            guard let data = loadData(), let focused = data["focusedPaneId"] else {
                XCTFail("Missing focusedPaneId after goto_split:\(directionName) #\(i + 1)", file: file, line: line)
                return
            }
            visited.append(focused)
        }

        XCTAssertEqual(visited, expectedVisited, "goto_split:\(directionName) should cycle in ordered panes", file: file, line: line)
        XCTAssertEqual(Set(visited.prefix(3)), allPaneIds, "goto_split:\(directionName) should visit all 3 panes", file: file, line: line)
        XCTAssertEqual(visited[3], visited[0], "goto_split:\(directionName) should wrap back to start", file: file, line: line)
    }

    // MARK: - Launch Helpers

    private func launchWithThreePaneLayout() -> (XCUIApplication, () -> Void) {
        let fileManager = FileManager.default
        let isolatedHome = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-ui-test-goto-split-cycle-\(UUID().uuidString)",
            isDirectory: true
        )
        let ghosttyDir = isolatedHome
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)
        let configURL = ghosttyDir.appendingPathComponent("config.ghostty", isDirectory: false)

        do {
            try fileManager.createDirectory(at: ghosttyDir, withIntermediateDirectories: true)
        } catch {
            XCTFail("Failed to create isolated Ghostty config directory: \(error)")
            return (XCUIApplication(), {})
        }

        let configContents = """
        # cmux goto_split cycle UI test
        working-directory = \(isolatedHome.path)
        # Keep the imported Ghostty fallbacks distinct from cmux's configured
        # focus-history defaults; this test owns the fallback behavior only.
        keybind = cmd+ctrl+p=goto_split:previous
        keybind = cmd+ctrl+n=goto_split:next

        """

        do {
            try configContents.write(to: configURL, atomically: true, encoding: .utf8)
        } catch {
            XCTFail("Failed to write isolated Ghostty config: \(error)")
            try? fileManager.removeItem(at: isolatedHome)
            return (XCUIApplication(), {})
        }

        let app = XCUIApplication()
        app.launchEnvironment["HOME"] = isolatedHome.path
        app.launchEnvironment["CFFIXED_USER_HOME"] = isolatedHome.path
        app.launchEnvironment["XDG_CONFIG_HOME"] =
            isolatedHome.appendingPathComponent(".config", isDirectory: true).path
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_LAYOUT"] = "three_pane_terminal"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_USE_GHOSTTY_CONFIG"] = "1"
        launchAndEnsureForeground(app)

        return (app, {
            app.terminate()
            try? fileManager.removeItem(at: isolatedHome)
        })
    }

    // MARK: - Data Polling

    @discardableResult
    private func typeShortcut(
        _ shortcut: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        guard ensureForeground(app, timeout: 20.0) else {
            XCTFail("App failed to enter foreground before shortcut. state=\(app.state.rawValue)", file: file, line: line)
            return false
        }

        var flags: XCUIElement.KeyModifierFlags = []
        if shortcut.contains("⌘") { flags.insert(.command) }
        if shortcut.contains("⌃") { flags.insert(.control) }
        if shortcut.contains("⌥") { flags.insert(.option) }
        if shortcut.contains("⇧") { flags.insert(.shift) }

        let key: String
        if shortcut.contains("→") {
            key = XCUIKeyboardKey.rightArrow.rawValue
        } else if shortcut.contains("←") {
            key = XCUIKeyboardKey.leftArrow.rawValue
        } else if shortcut.contains("]") {
            key = "]"
        } else if shortcut.contains("[") {
            key = "["
        } else if shortcut.localizedCaseInsensitiveContains("n") {
            key = "n"
        } else if shortcut.localizedCaseInsensitiveContains("p") {
            key = "p"
        } else {
            XCTFail("Unsupported goto_split shortcut: \(shortcut)", file: file, line: line)
            return false
        }

        app.typeKey(key, modifierFlags: flags)
        return true
    }

    private func waitForData(keys: [String], timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            guard let data = self.loadData() else { return false }
            return keys.allSatisfy { data[$0] != nil }
        }
    }

    private func waitForDataMatch(timeout: TimeInterval, predicate: @escaping ([String: String]) -> Bool) -> Bool {
        waitForCondition(timeout: timeout) {
            guard let data = self.loadData() else { return false }
            return predicate(data)
        }
    }

    private func loadData() -> [String: String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: dataPath)) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
    }

    private func waitForCondition(timeout: TimeInterval, predicate: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in predicate() },
            object: nil
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func launchAndEnsureForeground(_ app: XCUIApplication, timeout: TimeInterval = 12.0) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: options) {
            app.launch()
        }

        if app.state == .runningForeground { return }
        if ensureForeground(app, timeout: timeout) {
            return
        }
        XCTFail("App failed to start. state=\(app.state.rawValue)")
    }

    private func ensureForeground(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if app.state == .runningForeground {
                return true
            }
            if app.state == .runningBackground {
                app.activate()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return app.state == .runningForeground
    }

    private func shortPaneId(_ paneId: String) -> String {
        String(paneId.prefix(5))
    }
}
