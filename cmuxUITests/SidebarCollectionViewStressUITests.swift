import CmuxTestSupport
import XCTest

final class SidebarCollectionViewStressUITests: XCTestCase {
    private var stateURL: URL!
    private var armURL: URL!
    private var stderrURL: URL!
    private var unifiedLogURL: URL!
    private var logCapture: SidebarProcessLogCapture?

    override func setUpWithError() throws {
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-sidebar-collection-stress-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        stateURL = root.appendingPathComponent("state.json")
        armURL = root.appendingPathComponent("arm")
        stderrURL = root.appendingPathComponent("stderr.log")
        unifiedLogURL = root.appendingPathComponent("unified.log")
    }

    override func tearDownWithError() throws {
        _ = logCapture?.finish()
        logCapture = nil
        if let stateURL {
            try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent())
        }
    }

    func testVisibleWindowChurnHasNoViewUpdateReentrancyOrHeartbeatLoss() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-newWorkspacePlacement", "end",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = "ui-sidebar-collection-stress"
        app.launchEnvironment["CMUX_UI_TEST_SIDEBAR_COLLECTION_STRESS"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SIDEBAR_COLLECTION_STRESS_STATE_PATH"] = stateURL.path
        app.launchEnvironment["CMUX_UI_TEST_SIDEBAR_COLLECTION_STRESS_ARM_PATH"] = armURL.path
        app.launchEnvironment["CMUX_UI_TEST_SIDEBAR_COLLECTION_STRESS_STDERR_PATH"] = stderrURL.path
        app.launchEnvironment["OS_ACTIVITY_MODE"] = "debug"
        app.launch()

        XCTAssertTrue(
            waitForStatePhase("ready", timeout: 35),
            "Expected the visible stress window to seed 300 workspaces. state=\(stateDescription())"
        )
        XCTAssertEqual(state()["workspaceCount"] as? Int, 300)

        let logCapture = SidebarProcessLogCapture(
            processIdentifier: app.processID,
            outputURL: unifiedLogURL
        )
        self.logCapture = logCapture
        try logCapture.start()

        let sidebar = app.descendants(matching: .any)
            .matching(identifier: "Sidebar")
            .firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 8), "Expected the visible workspace sidebar")
        let firstRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "sidebarWorkspace."))
            .firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 8), "Expected a realized workspace row")
        firstRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        _ = FileManager.default.createFile(atPath: armURL.path, contents: Data())

        let heartbeat = app.descendants(matching: .any)
            .matching(identifier: "SidebarCollectionStressHeartbeat")
            .firstMatch
        XCTAssertTrue(
            heartbeat.waitForExistence(timeout: 5),
            "Expected the main-thread heartbeat element"
        )

        var lastHeartbeat = heartbeat.value as? String
        var lastHeartbeatChange = ProcessInfo.processInfo.systemUptime
        var scrollDirection: CGFloat = 480
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while !waitForStatePhase("complete", timeout: 0.05) {
            XCTAssertLessThan(
                ProcessInfo.processInfo.systemUptime,
                deadline,
                "Stress churn did not complete. state=\(stateDescription())"
            )

            let nextHeartbeat = heartbeat.value as? String
            if nextHeartbeat != lastHeartbeat {
                lastHeartbeat = nextHeartbeat
                lastHeartbeatChange = ProcessInfo.processInfo.systemUptime
            }
            XCTAssertLessThan(
                ProcessInfo.processInfo.systemUptime - lastHeartbeatChange,
                2.0,
                "Main-thread heartbeat stopped during sidebar churn. state=\(stateDescription())"
            )

            if sidebar.exists {
                sidebar.scroll(byDeltaX: 0, deltaY: scrollDirection)
                scrollDirection = -scrollDirection
            }
        }

        let unifiedLog = logCapture.finish()
        self.logCapture = nil
        let stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        let faults = SidebarRuntimeFaultScanner().faults(in: unifiedLog + "\n" + stderr)
        XCTAssertTrue(
            faults.isEmpty,
            "Detected issue 8004 runtime faults:\n\(faults.map(\.line).joined(separator: "\n"))"
        )
    }

    private func waitForStatePhase(_ phase: String, timeout: TimeInterval) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            if state()["phase"] as? String == phase { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    private func state() -> [String: Any] {
        guard let data = try? Data(contentsOf: stateURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    private func stateDescription() -> String {
        String(
            data: (try? Data(contentsOf: stateURL)) ?? Data(),
            encoding: .utf8
        ) ?? "<missing>"
    }
}
