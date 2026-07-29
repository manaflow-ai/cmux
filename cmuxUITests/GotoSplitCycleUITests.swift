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

    // MARK: - Tests

    func testGotoSplitNextCyclesAllPanes() {
        // Uses the Ghostty trigger loaded by the app for goto_split:next.
        let (app, configCleanup) = launchWithThreePaneLayout()
        defer { configCleanup() }

        XCTAssertTrue(
            waitForData(
                keys: ["setupComplete", "allPaneIds", "focusedPaneId", "ghosttyGotoSplitNextShortcut"],
                timeout: 10.0
            ),
            "Expected three-pane setup data to be written"
        )

        guard let setup = loadData() else {
            XCTFail("Missing setup data")
            return
        }
        XCTAssertEqual(setup["paneCount"], "3", "Expected 3 panes")

        let allPaneIds = Set(setup["allPaneIds"]!.split(separator: ",").map(String.init))
        XCTAssertEqual(allPaneIds.count, 3, "Expected 3 distinct pane IDs")

        let startPane = setup["focusedPaneId"]!
        XCTAssertTrue(allPaneIds.contains(startPane), "Start pane should be in allPaneIds")
        let nextShortcut = setup["ghosttyGotoSplitNextShortcut"] ?? ""
        XCTAssertFalse(nextShortcut.isEmpty, "Expected Ghostty goto_split:next shortcut")

        // Send goto_split:next 3 times — should visit all panes and wrap.
        var visited = [startPane]
        for i in 0..<3 {
            typeShortcut(nextShortcut, in: app)

            XCTAssertTrue(
                waitForDataMatch(timeout: 3.0) { data in
                    guard let focused = data["focusedPaneId"], !focused.isEmpty else { return false }
                    return focused != visited.last
                },
                "Focus did not change after goto_split:next #\(i + 1)"
            )

            guard let data = loadData(), let focused = data["focusedPaneId"] else {
                XCTFail("Missing focusedPaneId after goto_split:next #\(i + 1)")
                return
            }
            visited.append(focused)
        }

        let visitedSet = Set(visited.prefix(3))
        XCTAssertEqual(visitedSet, allPaneIds, "goto_split:next should visit all 3 panes")
        XCTAssertEqual(visited[3], visited[0], "goto_split:next should wrap back to start")
    }

    func testGotoSplitPreviousCyclesAllPanes() {
        // Uses the Ghostty trigger loaded by the app for goto_split:previous.
        let (app, configCleanup) = launchWithThreePaneLayout()
        defer { configCleanup() }

        XCTAssertTrue(
            waitForData(
                keys: ["setupComplete", "allPaneIds", "focusedPaneId", "ghosttyGotoSplitPreviousShortcut"],
                timeout: 10.0
            ),
            "Expected three-pane setup data to be written"
        )

        guard let setup = loadData() else {
            XCTFail("Missing setup data")
            return
        }
        XCTAssertEqual(setup["paneCount"], "3", "Expected 3 panes")

        let allPaneIds = Set(setup["allPaneIds"]!.split(separator: ",").map(String.init))
        XCTAssertEqual(allPaneIds.count, 3, "Expected 3 distinct pane IDs")

        let startPane = setup["focusedPaneId"]!
        let previousShortcut = setup["ghosttyGotoSplitPreviousShortcut"] ?? ""
        XCTAssertFalse(previousShortcut.isEmpty, "Expected Ghostty goto_split:previous shortcut")

        var visited = [startPane]
        for i in 0..<3 {
            typeShortcut(previousShortcut, in: app)

            XCTAssertTrue(
                waitForDataMatch(timeout: 3.0) { data in
                    guard let focused = data["focusedPaneId"], !focused.isEmpty else { return false }
                    return focused != visited.last
                },
                "Focus did not change after goto_split:previous #\(i + 1)"
            )

            guard let data = loadData(), let focused = data["focusedPaneId"] else {
                XCTFail("Missing focusedPaneId after goto_split:previous #\(i + 1)")
                return
            }
            visited.append(focused)
        }

        let visitedSet = Set(visited.prefix(3))
        XCTAssertEqual(visitedSet, allPaneIds, "goto_split:previous should visit all 3 panes")
        XCTAssertEqual(visited[3], visited[0], "goto_split:previous should wrap back to start")
    }

    // MARK: - Launch Helpers

    private func launchWithThreePaneLayout() -> (XCUIApplication, () -> Void) {
        let fileManager = FileManager.default
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            XCTFail("Missing Application Support directory")
            return (XCUIApplication(), {})
        }

        let ghosttyDir = appSupport.appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)
        let nativeConfigURL = ghosttyDir.appendingPathComponent("config.ghostty", isDirectory: false)
        let cmuxConfigURLs = [
            appSupport
                .appendingPathComponent("com.cmuxterm.app.debug.goto.split.cycle", isDirectory: true)
                .appendingPathComponent("config.ghostty", isDirectory: false),
            appSupport
                .appendingPathComponent("com.cmuxterm.app", isDirectory: true)
                .appendingPathComponent("config.ghostty", isDirectory: false),
        ]
        let configURLs = [nativeConfigURL] + cmuxConfigURLs

        do {
            try fileManager.createDirectory(at: ghosttyDir, withIntermediateDirectories: true)
            for url in cmuxConfigURLs {
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
        } catch {
            XCTFail("Failed to create Ghostty config dir: \(error)")
            return (XCUIApplication(), {})
        }

        let originalConfigData = configURLs.map { url in
            (url, try? Data(contentsOf: url))
        }
        let cleanup: () -> Void = {
            for (url, data) in originalConfigData {
                if let data {
                    try? data.write(to: url, options: .atomic)
                } else {
                    try? fileManager.removeItem(at: url)
                }
            }
        }

        let home = fileManager.homeDirectoryForCurrentUser
        let configContents = """
        # cmux goto_split cycle UI test
        working-directory = \(home.path)

        """

        do {
            for url in configURLs {
                try configContents.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            XCTFail("Failed to write Ghostty config: \(error)")
            return (XCUIApplication(), {})
        }

        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_LAYOUT"] = "three_pane_terminal"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_USE_GHOSTTY_CONFIG"] = "1"
        launchAndEnsureForeground(app)

        return (app, cleanup)
    }

    // MARK: - Data Polling

    private func typeShortcut(
        _ shortcut: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
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
            return
        }

        app.typeKey(key, modifierFlags: flags)
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
        if app.state == .runningBackground { return }
        XCTFail("App failed to start. state=\(app.state.rawValue)")
    }
}
