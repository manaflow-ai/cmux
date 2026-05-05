import XCTest
import Foundation

final class FeedActivityPaginationUITests: XCTestCase {
    private var chromePath = ""
    private var paginationPath = ""
    private var workstreamPath = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        chromePath = "/tmp/cmux-feed-activity-chrome-\(UUID().uuidString).json"
        paginationPath = "/tmp/cmux-feed-activity-pagination-\(UUID().uuidString).json"
        workstreamPath = "/tmp/cmux-feed-activity-workstream-\(UUID().uuidString).jsonl"
        try? FileManager.default.removeItem(atPath: chromePath)
        try? FileManager.default.removeItem(atPath: paginationPath)
        try? FileManager.default.removeItem(atPath: workstreamPath)
    }

    func testActivityAutoLoadsBoundedPagesFromPersistedHistory() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-workspacePresentationMode", "minimal",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launchEnvironment["CMUX_TAG"] = "ui-feed-page"
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH"] = chromePath
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_SHOW_RIGHT_SIDEBAR"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_WINDOW_SIZE"] = "1120x900"
        app.launchEnvironment["CMUX_UI_TEST_WORKSTREAM_FILE"] = workstreamPath
        app.launchEnvironment["CMUX_UI_TEST_WORKSTREAM_INITIAL_LOAD_LIMIT"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_WORKSTREAM_HISTORY_PAGE_SIZE"] = "2"
        app.launchEnvironment["CMUX_UI_TEST_FEED_ACTIVITY_SEED_COUNT"] = "30"
        app.launchEnvironment["CMUX_UI_TEST_FEED_ACTIVITY_PAGINATION_PATH"] = paginationPath

        launchAndEnsureUsable(app)
        defer { app.terminate() }

        guard let setup = waitForJSONKey("ready", equals: "1", atPath: chromePath, timeout: 25) else {
            XCTFail("Timed out waiting for right-sidebar test setup. data=\(loadJSON(atPath: chromePath) ?? [:])")
            return
        }
        if let setupError = setup["setupError"], !setupError.isEmpty {
            XCTFail("Right-sidebar test setup failed: \(setupError)")
            return
        }

        let feedButton = app.buttons["RightSidebarModeButton.feed"].firstMatch
        XCTAssertTrue(feedButton.waitForExistence(timeout: 8), "Feed mode button did not appear")
        feedButton.click()

        let activityButton = app.buttons["FeedFilterButton.activity"].firstMatch
        XCTAssertTrue(activityButton.waitForExistence(timeout: 8), "Activity filter did not appear")
        activityButton.click()

        let newestRow = app.descendants(matching: .any)["FeedRow.opencode-ui-page-29"].firstMatch
        XCTAssertTrue(newestRow.waitForExistence(timeout: 8), "Newest seeded activity row did not render")

        guard let state = waitForPaginationIdleAfterAutoLoad(timeout: 12) else {
            XCTFail("Timed out waiting for Activity auto-pagination. data=\(loadJSON(atPath: paginationPath) ?? [:])")
            return
        }

        let itemsCount = Int(state["itemsCount"] ?? "") ?? 0
        let autoPages = Int(state["activityAutoPagesRequested"] ?? "") ?? 0
        XCTAssertEqual(state["seeded"], "1", "Expected seeded workstream history. state=\(state)")
        XCTAssertGreaterThan(itemsCount, 1, "Activity should auto-load older rows on open. state=\(state)")
        XCTAssertLessThanOrEqual(itemsCount, 7, "Activity should keep auto-load bounded to three pages. state=\(state)")
        XCTAssertGreaterThanOrEqual(autoPages, 1, "Expected at least one automatic page request. state=\(state)")
        XCTAssertLessThanOrEqual(autoPages, 3, "Expected automatic pagination budget to cap at three pages. state=\(state)")
        XCTAssertEqual(state["hasMorePersistedItems"], "1", "Manual pagination should remain available. state=\(state)")

        let olderRow = app.descendants(matching: .any)["FeedRow.opencode-ui-page-28"].firstMatch
        XCTAssertTrue(olderRow.waitForExistence(timeout: 3), "First older auto-loaded row did not render")
        XCTAssertTrue(app.buttons["FeedHistoryLoadMoreButton"].firstMatch.exists, "Load-more row should remain for manual pagination")
    }

    private func launchAndEnsureUsable(_ app: XCUIApplication) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: options) {
            app.launch()
        }

        if app.state == .runningForeground {
            return
        }
        if app.state == .runningBackground {
            app.activate()
        }
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 20) || app.windows.firstMatch.waitForExistence(timeout: 6),
            "cmux failed to launch for Activity pagination UI test. state=\(app.state.rawValue)"
        )
    }

    private func waitForPaginationIdleAfterAutoLoad(timeout: TimeInterval) -> [String: String]? {
        waitForJSON(atPath: paginationPath, timeout: timeout) { data in
            guard data["activityAutoPaginationActive"] == "1",
                  data["isLoadingOlderItems"] == "0",
                  data["stage"] == "auto.idle",
                  let itemsCount = Int(data["itemsCount"] ?? ""),
                  let autoPages = Int(data["activityAutoPagesRequested"] ?? "") else {
                return false
            }
            return itemsCount > 1 && autoPages > 0
        }
    }

    private func waitForJSONKey(
        _ key: String,
        equals expected: String,
        atPath path: String,
        timeout: TimeInterval
    ) -> [String: String]? {
        waitForJSON(atPath: path, timeout: timeout) { data in
            data[key] == expected
        }
    }

    private func waitForJSON(
        atPath path: String,
        timeout: TimeInterval,
        matching predicate: ([String: String]) -> Bool
    ) -> [String: String]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = loadJSON(atPath: path), predicate(data) {
                return data
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return loadJSON(atPath: path).flatMap { predicate($0) ? $0 : nil }
    }

    private func loadJSON(atPath path: String) -> [String: String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object.reduce(into: [String: String]()) { result, pair in
            result[pair.key] = "\(pair.value)"
        }
    }
}
