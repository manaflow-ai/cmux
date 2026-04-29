import Foundation
import Darwin
import XCTest

/// Exercises the right-sidebar Feed end-to-end: boot the app with a
/// dedicated socket, inject a synthetic permission request inside the app,
/// toggle the sidebar to Dock mode, drive the Feed TUI from the keyboard,
/// and assert the Feed item carries the resolved decision.
final class FeedSidebarUITests: XCTestCase {
    private var socketPath = ""
    private var diagnosticsPath = ""
    private var feedResultPath = ""
    private var feedTUIReadyPath = ""
    private var requestId = ""
    private let modeKey = "socketControlMode"
    private let launchTag = "ui-tests-feed-sidebar"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        socketPath = "/tmp/cmux-debug-\(UUID().uuidString).sock"
        diagnosticsPath = "/tmp/cmux-feed-sidebar-\(UUID().uuidString).json"
        feedResultPath = "/tmp/cmux-feed-sidebar-result-\(UUID().uuidString).json"
        feedTUIReadyPath = "/tmp/cmux-feed-sidebar-tui-ready-\(UUID().uuidString).json"
        requestId = "uitest-\(UUID().uuidString)"
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: diagnosticsPath)
        try? FileManager.default.removeItem(atPath: feedResultPath)
        try? FileManager.default.removeItem(atPath: feedTUIReadyPath)
    }

    func testFeedReceivesAndResolvesPermissionRequest() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-\(modeKey)", "allowAll",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ]
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_MODE"] = "allowAll"
        app.launchEnvironment["CMUX_ALLOW_SOCKET_OVERRIDE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = launchTag
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_DIAGNOSTICS_PATH"] = diagnosticsPath
        app.launchEnvironment["CMUX_UI_TEST_PORTAL_STATS"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_FEED_SIDEBAR_RESULT_PATH"] = feedResultPath
        app.launchEnvironment["CMUX_UI_TEST_FEED_SIDEBAR_REQUEST_ID"] = requestId
        app.launchEnvironment["CMUX_UI_TEST_FEED_TUI_READY_PATH"] = feedTUIReadyPath
        launchAndEnsureUsable(app)

        XCTAssertTrue(
            waitForInAppSocketReady(timeout: 75),
            "Expected app-side control socket readiness at \(socketPath). diagnostics=\(loadDiagnostics())"
        )
        XCTAssertTrue(
            revealDockMode(in: app),
            "Dock mode did not open in the right sidebar. diagnostics=\(loadDiagnostics())"
        )

        let focusButton = app.buttons["Focus Control"].firstMatch
        XCTAssertTrue(
            focusButton.waitForExistence(timeout: 10),
            "Dock Feed focus button did not appear"
        )
        focusButton.click()
        XCTAssertTrue(
            waitForFeedTUIReady(timeout: 45),
            "Feed TUI was not ready. marker=\(loadFeedTUIReadyMarker()) result=\(loadFeedResult())"
        )

        XCTAssertTrue(
            waitForInjectedFeedItem(requestId: requestId, timeout: 10),
            "feed.push did not publish pending item. result=\(loadFeedResult())"
        )

        // The TUI blocks on keyboard input. Refresh first so it observes the
        // pending request, then Enter accepts the default "once" action.
        app.typeKey("r", modifierFlags: [])
        Thread.sleep(forTimeInterval: 1.0)
        app.typeKey(.return, modifierFlags: [])

        guard let result = waitForFeedResult(timeout: 35) else {
            XCTFail("Expected Feed item to resolve. result=\(loadFeedResult())")
            return
        }
        XCTAssertEqual(
            result.status, "resolved",
            "Expected feed.push to resolve, got status=\(result.status)"
        )
        XCTAssertEqual(result.mode, "once")

        app.typeKey("3", modifierFlags: [.control])
        XCTAssertTrue(
            app.buttons["RightSidebarModeButton.sessions"].firstMatch.waitForExistence(timeout: 5),
            "Sessions mode button disappeared after Ctrl-3"
        )
        XCTAssertTrue(
            waitForDockPortalToLeaveVisibleSidebar(timeout: 5),
            "Dock terminal portal stayed visible after switching from Ctrl-4 Dock to Ctrl-3 Sessions"
        )
        XCTAssertTrue(
            waitForFeedTUIProcessAlive(timeout: 3),
            "Feed TUI exited after Ctrl-3. marker=\(loadFeedTUIReadyMarker())"
        )

        app.terminate()
    }

    // MARK: - Feed helpers

    private struct FeedPushResult {
        let status: String
        let mode: String
    }

    private func waitForInAppSocketReady(timeout: TimeInterval) -> Bool {
        pollUntil(timeout: timeout) {
            let diagnostics = loadDiagnostics()
            return diagnostics["socketReady"] == "1" &&
                diagnostics["socketPingResponse"] == "PONG" &&
                diagnostics["socketPathMatches"] == "1" &&
                diagnostics["socketPathExists"] == "1"
        }
    }

    private func waitForInjectedFeedItem(requestId: String, timeout: TimeInterval) -> Bool {
        pollUntil(timeout: timeout, interval: 0.2) {
            let result = loadFeedResult()
            return result["requestId"] == requestId &&
                result["published"] == "1" &&
                (result["status"] == "pending" || result["status"] == "resolved")
        }
    }

    private func waitForFeedResult(timeout: TimeInterval) -> FeedPushResult? {
        var resolved: FeedPushResult?
        _ = pollUntil(timeout: timeout, interval: 0.2) {
            let result = loadFeedResult()
            guard result["requestId"] == requestId,
                  result["status"] == "resolved" else {
                return false
            }
            resolved = FeedPushResult(status: result["status"] ?? "", mode: result["mode"] ?? "")
            return true
        }
        return resolved
    }

    private func waitForFeedTUIReady(timeout: TimeInterval) -> Bool {
        return pollUntil(timeout: timeout, interval: 0.5) {
            FileManager.default.fileExists(atPath: feedTUIReadyPath)
        }
    }

    private func waitForFeedTUIProcessAlive(timeout: TimeInterval) -> Bool {
        return pollUntil(timeout: timeout, interval: 0.2) {
            feedTUIProcessIsAlive()
        }
    }

    private func feedTUIProcessIsAlive() -> Bool {
        guard let pidText = loadFeedTUIReadyPayload()["pid"],
              let pidValue = Int32(pidText) else {
            return false
        }
        errno = 0
        return kill(pidValue, 0) == 0 || errno == EPERM
    }

    private func waitForDockPortalToLeaveVisibleSidebar(timeout: TimeInterval) -> Bool {
        pollUntil(timeout: timeout) {
            let diagnostics = self.loadDiagnostics()
            return (Int(diagnostics["portal_visible_invalid_anchor_entry_count"] ?? "") ?? 0) == 0 &&
                (Int(diagnostics["portal_visible_orphan_terminal_subview_count"] ?? "") ?? 0) == 0
        }
    }

    private func revealDockMode(in app: XCUIApplication) -> Bool {
        app.activate()
        if waitForFeedSidebarReveal(timeout: 5), waitForDockModeVisible(in: app, timeout: 8) {
            return true
        }

        let dockButton = app.buttons["RightSidebarModeButton.feed"].firstMatch
        if waitForHittable(dockButton, timeout: 5) {
            dockButton.click()
            return waitForDockModeVisible(in: app, timeout: 8)
        }

        app.typeKey("e", modifierFlags: [.command, .shift])
        if waitForHittable(dockButton, timeout: 5) {
            dockButton.click()
            return waitForDockModeVisible(in: app, timeout: 8)
        }

        app.typeKey("b", modifierFlags: [.command, .option])
        if waitForHittable(dockButton, timeout: 5) {
            dockButton.click()
            return waitForDockModeVisible(in: app, timeout: 8)
        }

        app.typeKey("4", modifierFlags: [.control])
        if waitForDockModeVisible(in: app, timeout: 8) {
            return true
        }
        if waitForHittable(dockButton, timeout: 2) {
            dockButton.click()
            return waitForDockModeVisible(in: app, timeout: 8)
        }
        return false
    }

    private func waitForFeedSidebarReveal(timeout: TimeInterval) -> Bool {
        pollUntil(timeout: timeout) {
            self.loadFeedResult()["reveal"] == "1"
        }
    }

    private func waitForDockModeVisible(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let focusButton = app.buttons["Focus Control"].firstMatch
        let dockPanel = app.otherElements["DockPanel"].firstMatch
        return pollUntil(timeout: timeout, interval: 0.2) {
            focusButton.exists || dockPanel.exists
        }
    }

    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        pollUntil(timeout: timeout) {
            element.exists && element.isHittable
        }
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
            app.wait(for: .runningForeground, timeout: 15),
            "cmux failed to launch for Feed UI test. state=\(app.state.rawValue)"
        )
    }

    private func loadDiagnostics() -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: diagnosticsPath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }

    private func loadFeedResult() -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: feedResultPath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }

    private func loadFeedTUIReadyMarker() -> String {
        (try? String(contentsOfFile: feedTUIReadyPath, encoding: .utf8)) ?? ""
    }

    private func loadFeedTUIReadyPayload() -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: feedTUIReadyPath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }

    private func pollUntil(timeout: TimeInterval, interval: TimeInterval = 0.1, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() {
                return true
            }
            Thread.sleep(forTimeInterval: interval)
        }
        return predicate()
    }
}
