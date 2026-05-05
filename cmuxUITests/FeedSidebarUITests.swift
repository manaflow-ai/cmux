import Foundation
import Darwin
import XCTest

/// Exercises the right-sidebar Feed end-to-end: boot the app with a
/// dedicated socket, inject a synthetic permission request through the same
/// V2 dispatcher used by that socket,
/// switch the sidebar to Dock mode, drive the Feed TUI from the keyboard,
/// and assert the hook-side response carries the resolved decision.
final class FeedSidebarUITests: XCTestCase {
    private var socketPath = ""
    private var diagnosticsPath = ""
    private var feedResultPath = ""
    private var feedTUIReadyPath = ""
    private var dockConfigPath = ""
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
        dockConfigPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-feed-sidebar-dock-\(UUID().uuidString).json")
            .path
        requestId = "uitest-\(UUID().uuidString)"
        removeSocketFile()
        try? FileManager.default.removeItem(atPath: diagnosticsPath)
        try? FileManager.default.removeItem(atPath: feedResultPath)
        try? FileManager.default.removeItem(atPath: feedTUIReadyPath)
        try? FileManager.default.removeItem(atPath: dockConfigPath)
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
        app.launchEnvironment["CMUX_UI_TEST_DOCK_CONFIG_PATH"] = dockConfigPath
        if let path = ProcessInfo.processInfo.environment["PATH"], !path.isEmpty {
            app.launchEnvironment["PATH"] = path
        }
        let bunPath = resolvedBunPathForFeedTUI()
        try writeFeedDockConfig(bunPath: bunPath)
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
            waitForFeedTUIReady(timeout: 90),
            "Feed TUI was not ready. marker=\(loadFeedTUIReadyMarker()) result=\(loadFeedResult())"
        )

        XCTAssertTrue(
            waitForFeedPushPendingObserved(timeout: 15),
            "feed.push did not publish a pending item. result=\(loadFeedResult())"
        )

        // The TUI blocks on keyboard input. Refresh first so it observes the
        // pending request, then Enter accepts the default "once" action.
        app.typeKey("r", modifierFlags: [])
        Thread.sleep(forTimeInterval: 1.0)
        app.typeKey(.return, modifierFlags: [])

        // Await the hook-side reply from the Feed dispatcher.
        let result = try waitForFeedPushResult(timeout: 35)
        XCTAssertEqual(
            result.status, "resolved",
            "Expected feed.push to resolve, got status=\(result.status)"
        )
        XCTAssertEqual(result.mode, "once")

        XCTAssertTrue(
            waitForFeedShortcutResponse(timeout: 10),
            "App-side Ctrl-3 shortcut simulation did not run. result=\(loadFeedResult())"
        )
        XCTAssertTrue(
            waitForDockPortalToLeaveVisibleSidebar(timeout: 5),
            "Dock terminal portal stayed visible after switching from Dock to Ctrl-3 Sessions"
        )
        XCTAssertTrue(
            waitForFeedTUIProcessAlive(timeout: 3),
            "Feed TUI exited after Ctrl-3. marker=\(loadFeedTUIReadyMarker())"
        )

        app.terminate()
    }

    // MARK: - Socket helpers

    private struct FeedPushResult {
        let status: String
        let mode: String
    }

    private func waitForInAppSocketReady(timeout: TimeInterval) -> Bool {
        pollUntil(timeout: timeout) {
            let diagnostics = loadDiagnostics()
            guard diagnostics["socketReady"] == "1", diagnostics["socketPingResponse"] == "PONG" else {
                return false
            }
            if let expectedPath = diagnostics["socketExpectedPath"], !expectedPath.isEmpty {
                socketPath = expectedPath
            }
            return true
        }
    }

    private func waitForFeedPushPendingObserved(timeout: TimeInterval) -> Bool {
        pollUntil(timeout: timeout, interval: 0.2) {
            self.loadFeedResult()["pushPendingObserved"] == "1"
        }
    }

    private func waitForFeedPushResult(timeout: TimeInterval) throws -> FeedPushResult {
        var payload: [String: String] = [:]
        let resolved = pollUntil(timeout: timeout, interval: 0.2) {
            payload = self.loadFeedResult()
            return payload["pushResultStatus"] != nil || payload["pushError"] != nil
        }
        guard resolved else {
            throw NSError(
                domain: "FeedPush",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "feed.push never returned. result=\(loadFeedResult())"]
            )
        }
        if let error = payload["pushError"] {
            throw NSError(
                domain: "FeedPush",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "feed.push failed: \(error). result=\(payload)"]
            )
        }
        return FeedPushResult(
            status: payload["pushResultStatus"] ?? "",
            mode: payload["pushResultMode"] ?? ""
        )
    }

    private func waitForFeedShortcutResponse(timeout: TimeInterval) -> Bool {
        pollUntil(timeout: timeout, interval: 0.2) {
            self.loadFeedResult()["shortcutResponse"] == "OK"
        }
    }

    private func waitForFeedTUIReady(timeout: TimeInterval) -> Bool {
        return pollUntil(timeout: timeout, interval: 0.5) {
            let payload = loadFeedTUIReadyPayload()
            guard payload["stage"] == "opentui-ready",
                  payload["tui"] == "opentui",
                  payload["screen_mode"] == "alternate-screen",
                  let cwd = payload["cwd"],
                  !cwd.contains(".cmuxterm/feed-tui-opentui") else {
                return false
            }
            return true
        }
    }

    private func waitForFeedTUIProcessAlive(timeout: TimeInterval) -> Bool {
        return pollUntil(timeout: timeout, interval: 0.2) {
            feedTUIProcessIsAlive()
        }
    }

    private func resolvedBunPathForFeedTUI() -> String? {
        let environment = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let bunInstall = environment["BUN_INSTALL"], !bunInstall.isEmpty {
            candidates.append((bunInstall as NSString).appendingPathComponent("bin/bun"))
        }
        if let home = environment["HOME"], !home.isEmpty {
            candidates.append((home as NSString).appendingPathComponent(".bun/bin/bun"))
        }
        if let path = environment["PATH"] {
            for directory in path.split(separator: ":") {
                candidates.append((String(directory) as NSString).appendingPathComponent("bun"))
            }
        }
        candidates.append(contentsOf: ["/opt/homebrew/bin/bun", "/usr/local/bin/bun"])
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
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
            guard let invalidAnchorEntryText = diagnostics["portal_visible_invalid_anchor_entry_count"],
                  let orphanSubviewText = diagnostics["portal_visible_orphan_terminal_subview_count"],
                  let invalidAnchorEntryCount = Int(invalidAnchorEntryText),
                  let orphanSubviewCount = Int(orphanSubviewText) else {
                return false
            }
            return invalidAnchorEntryCount == 0 && orphanSubviewCount == 0
        }
    }

    private func revealDockMode(in app: XCUIApplication) -> Bool {
        app.activate()
        if waitForFeedSidebarReveal(timeout: 5), waitForDockModeVisible(in: app, timeout: 8) {
            return true
        }

        let dockButton = app.buttons["RightSidebarModeButton.dock"].firstMatch
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

        app.typeKey("5", modifierFlags: [.control])
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

    private func removeSocketFile() {
        try? FileManager.default.removeItem(atPath: socketPath)
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

    private func writeFeedDockConfig(bunPath: String?) throws {
        var env = ["CMUX_FEED_TUI_READY_PATH": feedTUIReadyPath]
        if let bunPath, !bunPath.isEmpty {
            env["CMUX_FEED_TUI_BUN_PATH"] = bunPath
        }
        let config: [String: Any] = [
            "controls": [[
                "id": "feed",
                "title": "Feed",
                "command": "cmux feed tui --opentui",
                "env": env
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: dockConfigPath), options: .atomic)
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
