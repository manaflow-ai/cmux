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
        // Uses Cmd+] which is Ghostty's default keybind for goto_split:next.
        let (app, configCleanup) = launchWithThreePaneLayout()
        defer { configCleanup() }

        XCTAssertTrue(
            waitForData(keys: ["setupComplete", "allPaneIds", "focusedPaneId"], timeout: 10.0),
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

        // Send goto_split:next (Cmd+]) 3 times — should visit all panes and wrap.
        // Ghostty default keybind: super+]=goto_split:next
        var visited = [startPane]
        for i in 0..<3 {
            app.typeKey("]", modifierFlags: [.command])

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
        // Uses Cmd+[ which is Ghostty's default keybind for goto_split:previous.
        let (app, configCleanup) = launchWithThreePaneLayout()
        defer { configCleanup() }

        XCTAssertTrue(
            waitForData(keys: ["setupComplete", "allPaneIds", "focusedPaneId"], timeout: 10.0),
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

        var visited = [startPane]
        for i in 0..<3 {
            app.typeKey("[", modifierFlags: [.command])

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
        let configURL = ghosttyDir.appendingPathComponent("config.ghostty", isDirectory: false)

        do {
            try fileManager.createDirectory(at: ghosttyDir, withIntermediateDirectories: true)
        } catch {
            XCTFail("Failed to create Ghostty app support dir: \(error)")
            return (XCUIApplication(), {})
        }

        let originalConfigData = try? Data(contentsOf: configURL)
        let cleanup: () -> Void = {
            if let originalConfigData {
                try? originalConfigData.write(to: configURL, options: .atomic)
            } else {
                try? fileManager.removeItem(at: configURL)
            }
        }

        let home = fileManager.homeDirectoryForCurrentUser
        let configContents = "# cmux goto_split cycle UI test\nworking-directory = \(home.path)\n"

        do {
            try configContents.write(to: configURL, atomically: true, encoding: .utf8)
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
