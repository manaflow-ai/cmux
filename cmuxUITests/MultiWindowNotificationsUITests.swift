import XCTest
import Foundation
import CoreGraphics

final class MultiWindowNotificationsUITests: XCTestCase {
    private var dataPath = ""
    private var socketPath = ""
    private var launchTag = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        dataPath = "/tmp/cmux-ui-test-multi-window-notifs-\(UUID().uuidString).json"
        socketPath = "/tmp/cmux-ui-test-socket-\(UUID().uuidString).sock"
        launchTag = "ui-tests-multi-window-notifs-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.removeItem(atPath: dataPath)
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dataPath)
        try? FileManager.default.removeItem(atPath: socketPath)
        super.tearDown()
    }

    func testNotificationsRouteToCorrectWindow() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_PATH"] = dataPath
        app.launchEnvironment["CMUX_TAG"] = launchTag
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for multi-window routing test. state=\(app.state.rawValue)"
        )

        XCTAssertTrue(
            waitForData(keys: [
                "window1Id",
                "window2Id",
                "window2InitialSidebarSelection",
                "tabId1",
                "tabId2",
                "notifId1",
                "notifId2",
                "expectedLatestWindowId",
                "expectedLatestTabId",
            ], timeout: 15.0),
            "Expected multi-window notification setup data"
        )

        guard let setup = loadData() else {
            XCTFail("Missing setup data")
            return
        }

        let expectedLatestWindowId = setup["expectedLatestWindowId"] ?? ""
        let expectedLatestTabId = setup["expectedLatestTabId"] ?? ""
        let window2Id = setup["window2Id"] ?? ""
        let window2InitialSidebarSelection = setup["window2InitialSidebarSelection"] ?? ""
        let tabId2 = setup["tabId2"] ?? ""
        let notifId2 = setup["notifId2"] ?? ""

        XCTAssertFalse(expectedLatestWindowId.isEmpty)
        XCTAssertFalse(expectedLatestTabId.isEmpty)
        XCTAssertFalse(window2Id.isEmpty)
        XCTAssertEqual(window2InitialSidebarSelection, "notifications")
        XCTAssertFalse(tabId2.isEmpty)
        XCTAssertFalse(notifId2.isEmpty)

        // Sanity: ensure the second window was actually created.
        XCTAssertTrue(waitForWindowCount(atLeast: 2, app: app, timeout: 6.0))

        // Jump to latest unread (Cmd+Shift+U). This should bring the owning window forward.
        let beforeToken = loadData()?["focusToken"]
        app.typeKey("u", modifierFlags: [.command, .shift])

        XCTAssertTrue(
            waitForFocusChange(from: beforeToken, timeout: 6.0),
            "Expected focus record after jump-to-unread"
        )
        guard let afterJump = loadData() else {
            XCTFail("Missing focus data after jump")
            return
        }
        XCTAssertEqual(afterJump["focusedWindowId"], expectedLatestWindowId)
        XCTAssertEqual(afterJump["focusedTabId"], expectedLatestTabId)

        // Open the notifications popover (Cmd+I) and click the notification belonging to window 2.
        let beforeClickToken = afterJump["focusToken"]
        app.typeKey("i", modifierFlags: [.command])

        let targetButton = app.buttons["NotificationPopoverRow.\(notifId2)"]
        XCTAssertTrue(targetButton.waitForExistence(timeout: 6.0), "Expected notification row button to exist")
        XCTAssertTrue(
            clickNotificationPopoverRowAndWaitForFocusChange(
                button: targetButton,
                app: app,
                from: beforeClickToken,
                timeout: 6.0
            ),
            "Expected focus record after clicking notification"
        )
        guard let afterClick = loadData() else {
            XCTFail("Missing focus data after click")
            return
        }
        XCTAssertEqual(afterClick["focusedWindowId"], window2Id)
        XCTAssertEqual(afterClick["focusedTabId"], tabId2)
        XCTAssertEqual(afterClick["focusedSidebarSelection"], "tabs")
    }

    func testNotificationsPopoverCanCloseViaShortcutAndEscape() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_PATH"] = dataPath
        app.launchEnvironment["CMUX_TAG"] = launchTag
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for notifications popover shortcut test. state=\(app.state.rawValue)"
        )

        XCTAssertTrue(
            waitForData(keys: ["notifId1"], timeout: 15.0),
            "Expected multi-window notification setup data"
        )

        guard let notifId1 = loadData()?["notifId1"], !notifId1.isEmpty else {
            XCTFail("Missing setup notification id")
            return
        }

        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: app, timeout: 6.0))

        app.typeKey("i", modifierFlags: [.command])
        let targetButton = app.buttons["NotificationPopoverRow.\(notifId1)"]
        XCTAssertTrue(targetButton.waitForExistence(timeout: 6.0), "Expected popover to open on Show Notifications shortcut")

        app.typeKey("i", modifierFlags: [.command])
        XCTAssertTrue(waitForElementToDisappear(targetButton, timeout: 3.0), "Expected popover to close on repeated Show Notifications shortcut")

        app.typeKey("i", modifierFlags: [.command])
        XCTAssertTrue(targetButton.waitForExistence(timeout: 6.0), "Expected popover to reopen on Show Notifications shortcut")

        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(waitForElementToDisappear(targetButton, timeout: 3.0), "Expected popover to close on Escape")
    }

    func testNotificationsPopoverJumpToLatestButtonShowsShortcut() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_PATH"] = dataPath
        app.launchEnvironment["CMUX_TAG"] = launchTag
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for jump-to-latest popover test. state=\(app.state.rawValue)"
        )

        XCTAssertTrue(waitForData(keys: ["notifId1"], timeout: 15.0), "Expected multi-window notification setup data")
        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: app, timeout: 6.0))

        app.typeKey("i", modifierFlags: [.command])

        let jumpButton = app.buttons["notificationsPopover.jumpToLatest"]
        XCTAssertTrue(jumpButton.waitForExistence(timeout: 6.0), "Expected Jump to Latest button in notifications popover")
        let shortcutValue = jumpButton.value as? String
        XCTAssertNotNil(shortcutValue, "Expected Jump to Latest shortcut badge")
        XCTAssertTrue(shortcutValue?.contains("⌘") == true, "Expected Jump to Latest shortcut to include Command")
        XCTAssertTrue(shortcutValue?.contains("⇧") == true, "Expected Jump to Latest shortcut to include Shift")
        XCTAssertTrue(shortcutValue?.uppercased().contains("U") == true, "Expected Jump to Latest shortcut to include U")
    }

    func testEmptyNotificationsPopoverBlocksTerminalTyping() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-socketControlMode", "allowAll"]
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_SOCKET_MODE"] = "allowAll"
        app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        app.launchEnvironment["CMUX_TAG"] = launchTag
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for empty popover blocking test. state=\(app.state.rawValue)"
        )

        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: app, timeout: 8.0))
        guard let resolvedPath = resolveSocketPath(timeout: 8.0) else {
            throw XCTSkip("Control socket unavailable in this test environment. requested=\(socketPath)")
        }
        socketPath = resolvedPath
        let pingResponse = waitForSocketPong(timeout: 8.0)
        guard pingResponse == "PONG" else {
            throw XCTSkip("Control socket did not respond in time. path=\(socketPath) response=\(pingResponse ?? "<nil>")")
        }

        _ = socketCommand("clear_notifications")

        app.typeKey("i", modifierFlags: [.command])
        XCTAssertTrue(app.staticTexts["No notifications yet"].waitForExistence(timeout: 6.0), "Expected empty notifications popover state")
        let jumpButton = app.buttons["notificationsPopover.jumpToLatest"]
        XCTAssertTrue(jumpButton.waitForExistence(timeout: 2.0), "Expected Jump to Latest button in empty notifications popover")
        XCTAssertFalse(jumpButton.isEnabled, "Expected Jump to Latest button to be disabled with no notifications")
        let clearAllButton = app.buttons["notificationsPopover.clearAll"]
        XCTAssertTrue(clearAllButton.waitForExistence(timeout: 2.0), "Expected Clear All button in empty notifications popover")
        XCTAssertFalse(clearAllButton.isEnabled, "Expected Clear All button to be disabled with no notifications")

        let marker = "cmux_notif_block_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))"
        let before = readCurrentTerminalText() ?? ""
        XCTAssertFalse(before.contains(marker), "Unexpected marker precondition collision")

        app.typeText(marker)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))

        guard let after = readCurrentTerminalText() else {
            XCTFail("Expected terminal text from control socket")
            return
        }
        XCTAssertFalse(after.contains(marker), "Expected typing to be blocked while empty notifications popover is open")
    }

    func testNotifyCLIDoesNotStealFocusAcrossWindows() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-socketControlMode", "allowAll"]
        app.launchEnvironment["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_PATH"] = dataPath
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_SOCKET_MODE"] = "allowAll"
        app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_NOTIFY_SOURCE_TERMINAL_READY"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_ENABLE_DUPLICATE_LAUNCH_OBSERVER"] = "1"
        app.launchEnvironment["CMUX_TAG"] = launchTag
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for notify focus regression test. state=\(app.state.rawValue)"
        )
        XCTAssertTrue(
            waitForDataMatch(timeout: 20.0) { data in
                let tabId2 = data["tabId2"] ?? ""
                let surfaceId2 = data["surfaceId2"] ?? ""
                let socketReady = data["socketReady"] ?? ""
                let sourceTerminalReady = data["sourceTerminalReady"] ?? ""
                return !tabId2.isEmpty &&
                    !surfaceId2.isEmpty &&
                    !socketReady.isEmpty &&
                    socketReady != "pending" &&
                    !sourceTerminalReady.isEmpty &&
                    sourceTerminalReady != "pending"
            },
            "Expected multi-window notification setup data, socket readiness, and source terminal focus"
        )

        guard let setup = loadData() else {
            XCTFail("Missing setup data")
            return
        }
        guard let tabId2 = setup["tabId2"], !tabId2.isEmpty else {
            XCTFail("Missing setup workspace id")
            return
        }
        if let expectedSocketPath = setup["socketExpectedPath"], !expectedSocketPath.isEmpty {
            socketPath = expectedSocketPath
        }
        if setup["socketReady"] != "1" {
            XCTFail(
                "Control socket unavailable in this test environment. expected=\(socketPath) " +
                socketDiagnostics(from: setup)
            )
            return
        }
        guard setup["socketPingResponse"] == "PONG" else {
            XCTFail(
                "Control socket ping sanity check failed. path=\(socketPath) " +
                socketDiagnostics(from: setup)
            )
            return
        }
        guard let surfaceId = setup["surfaceId2"], !surfaceId.isEmpty else {
            XCTFail("Missing target surface id for workspace \(tabId2)")
            return
        }
        guard setup["sourceTerminalReady"] == "1" else {
            XCTFail(
                "Expected source terminal to be focused before typing. " +
                "failure=\(setup["sourceTerminalFocusFailure"] ?? "<unknown>")"
            )
            return
        }

        XCTAssertTrue(waitForWindowCount(atLeast: 2, app: app, timeout: 6.0))

        let title = "focus-regression-\(UUID().uuidString.prefix(8))"
        let commandResultStem = UUID().uuidString
        let commandStatusPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ui-test-notify-\(commandResultStem).status")
            .path
        let commandStdoutPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ui-test-notify-\(commandResultStem).stdout")
            .path
        let commandStderrPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ui-test-notify-\(commandResultStem).stderr")
            .path
        let commandScriptPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ui-test-notify-\(commandResultStem).sh")
            .path
        defer {
            try? FileManager.default.removeItem(atPath: commandStatusPath)
            try? FileManager.default.removeItem(atPath: commandStdoutPath)
            try? FileManager.default.removeItem(atPath: commandStderrPath)
            try? FileManager.default.removeItem(atPath: commandScriptPath)
        }

        guard let bundledCLIPath = resolveCmuxCLIPaths(strategy: .bundledOnly).first else {
            XCTFail("Failed to locate bundled cmux CLI for notify regression test")
            return
        }

        let notifyScript = [
            "#!/bin/sh",
            "sleep 1",
            "rm -f \(shellSingleQuote(commandStatusPath)) \(shellSingleQuote(commandStdoutPath)) \(shellSingleQuote(commandStderrPath))",
            "\(shellSingleQuote(bundledCLIPath)) --socket \(shellSingleQuote(socketPath)) notify --workspace \(shellSingleQuote(tabId2)) --surface \(shellSingleQuote(surfaceId)) --title \(shellSingleQuote(title)) --subtitle \(shellSingleQuote("ui-test")) --body \(shellSingleQuote("focus-regression")) >\(shellSingleQuote(commandStdoutPath)) 2>\(shellSingleQuote(commandStderrPath))",
            "printf '%s' $? >\(shellSingleQuote(commandStatusPath))"
        ].joined(separator: "\n")
        do {
            try notifyScript.write(toFile: commandScriptPath, atomically: true, encoding: .utf8)
        } catch {
            XCTFail(
                "Failed to write delayed bundled `cmux notify` script. " +
                "path=\(commandScriptPath) error=\(error)"
            )
            return
        }

        app.typeText("sh \(commandScriptPath)")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        XCTAssertTrue(
            waitForAppToLeaveForeground(app, timeout: 8.0),
            "Expected cmux to move to background before delayed notify command runs. state=\(app.state.rawValue)"
        )

        XCTAssertTrue(
            waitForCommandCompletionWhileBackgrounded(
                statusPath: commandStatusPath,
                app: app,
                timeout: 15.0
            ),
            "Expected delayed bundled `cmux notify` command to finish without foregrounding cmux. state=\(app.state.rawValue)"
        )

        let notifyExitStatus = readTrimmedFile(atPath: commandStatusPath) ?? "<missing>"
        let notifyStdout = readTrimmedFile(atPath: commandStdoutPath) ?? ""
        let notifyStderr = readTrimmedFile(atPath: commandStderrPath) ?? ""

        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertFalse(
            app.state == .runningForeground,
            "Expected cmux to remain in background after bundled `cmux notify`. state=\(app.state.rawValue) stderr=\(notifyStderr)"
        )
        guard notifyExitStatus == "0" else {
            XCTFail(
                "Expected bundled `cmux notify` launched from the in-app shell to succeed. " +
                "status=\(notifyExitStatus) stdout=\(notifyStdout) stderr=\(notifyStderr)"
            )
            return
        }
        XCTAssertTrue(notifyStdout.contains("OK"), "Expected notify command to return OK. stdout=\(notifyStdout) stderr=\(notifyStderr)")
    }

    private func clickNotificationPopoverRowAndWaitForFocusChange(
        button: XCUIElement,
        app: XCUIApplication,
        from token: String?,
        timeout: TimeInterval
    ) -> Bool {
        // `.click()` on a button inside an NSPopover can be flaky on the VM; prefer a coordinate click
        // within the left side of the row (away from the clear button).
        if button.exists {
            let coord = button.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
            coord.click()
        } else {
            button.click()
        }

        // If the coordinate click was swallowed (popover auto-dismiss, etc), retry with a normal click.
        let firstDeadline = min(1.0, timeout)
        if waitForFocusChange(from: token, timeout: firstDeadline) {
            return true
        }
        button.click()
        return waitForFocusChange(from: token, timeout: max(0.0, timeout - firstDeadline))
    }

    private func waitForWindowCount(atLeast count: Int, app: XCUIApplication, timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            app.windows.count >= count
        }
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

    private func waitForElementToDisappear(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForFocusChange(from token: String?, timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            guard let data = self.loadData(),
                  let current = data["focusToken"],
                  !current.isEmpty else {
                return false
            }
            return current != token
        }
    }

    private func waitForData(keys: [String], timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            guard let data = self.loadData() else { return false }
            return keys.allSatisfy { (data[$0] ?? "").isEmpty == false }
        }
    }

    private func waitForDataMatch(timeout: TimeInterval, predicate: @escaping ([String: String]) -> Bool) -> Bool {
        waitForCondition(timeout: timeout) {
            guard let data = self.loadData() else { return false }
            return predicate(data)
        }
    }

    private func waitForSocketPong(timeout: TimeInterval) -> String? {
        var lastResponse: String?
        _ = waitForCondition(timeout: timeout) {
            lastResponse = self.socketCommand("ping")
            return lastResponse == "PONG"
        }
        return lastResponse == "PONG" ? "PONG" : (socketCommand("ping") ?? lastResponse)
    }

    private func waitForTerminalFocus(surfaceId: String, timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            self.socketCommand("is_terminal_focused \(surfaceId)") == "true"
        }
    }

    private func waitForCmuxPing(timeout: TimeInterval) -> (stdout: String?, stderr: String?) {
        var lastStdout: String?
        var lastStderr: String?
        let didSucceed = waitForCondition(timeout: timeout) {
            let result = self.runCmuxCommand(
                socketPath: self.socketPath,
                arguments: ["ping"],
                responseTimeoutSeconds: 2.0
            )
            let stdout = result.stdout.isEmpty ? nil : result.stdout
            let stderr = result.stderr.isEmpty ? nil : result.stderr
            if let stdout {
                lastStdout = stdout
            }
            if let stderr {
                lastStderr = stderr
            }
            if result.terminationStatus == 0, stdout == "PONG" {
                return true
            }
            if self.isSocketPermissionFailure(stderr),
               self.waitForSocketPong(timeout: 0.5) == "PONG" {
                return true
            }
            return false
        }
        if didSucceed {
            return ("PONG", lastStderr)
        }

        let result = runCmuxCommand(socketPath: socketPath, arguments: ["ping"], responseTimeoutSeconds: 2.0)
        let stdout = result.stdout.isEmpty ? nil : result.stdout
        let stderr = result.stderr.isEmpty ? nil : result.stderr
        if isSocketPermissionFailure(stderr), waitForSocketPong(timeout: 0.5) == "PONG" {
            return ("PONG", stderr)
        }
        return (stdout ?? lastStdout, stderr ?? lastStderr)
    }

    private func waitForCommandCompletionWhileBackgrounded(
        statusPath: String,
        app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        var sawCompletion = false
        let completed = waitForCondition(timeout: timeout) {
            if app.state == .runningForeground {
                return false
            }
            if FileManager.default.fileExists(atPath: statusPath) {
                sawCompletion = true
                return true
            }
            return false
        }
        guard completed || sawCompletion || FileManager.default.fileExists(atPath: statusPath) else {
            return false
        }

        return waitForCondition(timeout: 0.75) {
            app.state != .runningForeground
        }
    }

    private func waitForAppToLeaveForeground(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            app.state != .runningForeground
        }
    }

    private func firstSurfaceId(forWorkspaceId workspaceId: String) -> String? {
        guard let response = socketCommand("list_surfaces \(workspaceId)"),
              !response.isEmpty,
              !response.hasPrefix("ERROR"),
              response != "No surfaces" else {
            return nil
        }

        for line in response.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let candidate = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            if UUID(uuidString: candidate) != nil {
                return candidate
            }
        }
        return nil
    }

    private func waitForSurfaceId(forWorkspaceId workspaceId: String, timeout: TimeInterval) -> String? {
        var surfaceId: String?
        _ = waitForCondition(timeout: timeout) {
            surfaceId = self.firstSurfaceId(forWorkspaceId: workspaceId)
            return surfaceId != nil
        }
        return surfaceId ?? firstSurfaceId(forWorkspaceId: workspaceId)
    }

    private func waitForSurfaceIdViaCLI(forWorkspaceId workspaceId: String, timeout: TimeInterval) -> String? {
        var surfaceId: String?
        _ = waitForCondition(timeout: timeout) {
            surfaceId = self.firstSurfaceIdViaCLI(forWorkspaceId: workspaceId)
            return surfaceId != nil
        }
        return surfaceId ?? firstSurfaceIdViaCLI(forWorkspaceId: workspaceId)
    }

    private func waitForCondition(timeout: TimeInterval, predicate: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in predicate() },
            object: nil
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func firstSurfaceIdViaCLI(forWorkspaceId workspaceId: String) -> String? {
        guard let paneId = firstPaneIdViaCLI(forWorkspaceId: workspaceId) else {
            return firstSurfaceId(forWorkspaceId: workspaceId)
        }
        let result = runCmuxCommand(
            socketPath: socketPath,
            arguments: [
                "list-pane-surfaces",
                "--workspace",
                workspaceId,
                "--pane",
                paneId,
                "--id-format",
                "uuids"
            ],
            responseTimeoutSeconds: 3.0
        )
        guard result.terminationStatus == 0 else {
            if isSocketPermissionFailure(result.stderr) {
                return firstSurfaceId(forWorkspaceId: workspaceId)
            }
            return nil
        }
        return firstHandle(in: result.stdout)
    }

    private func firstPaneIdViaCLI(forWorkspaceId workspaceId: String) -> String? {
        let result = runCmuxCommand(
            socketPath: socketPath,
            arguments: [
                "list-panes",
                "--workspace",
                workspaceId,
                "--id-format",
                "uuids"
            ],
            responseTimeoutSeconds: 3.0
        )
        guard result.terminationStatus == 0 else {
            if isSocketPermissionFailure(result.stderr) {
                return nil
            }
            return nil
        }
        return firstHandle(in: result.stdout)
    }

    private func firstHandle(in output: String) -> String? {
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("No ") else { continue }
            if line.hasPrefix("* ") || line.hasPrefix("  ") {
                line = String(line.dropFirst(2))
            }
            guard let token = line.split(whereSeparator: \.isWhitespace).first else { continue }
            return String(token)
        }
        return nil
    }

    private func runCmuxNotify(
        socketPath: String,
        workspaceId: String,
        surfaceId: String,
        title: String
    ) -> (terminationStatus: Int32, stdout: String, stderr: String) {
        runCmuxCommand(
            socketPath: socketPath,
            arguments: [
                "notify",
                "--workspace",
                workspaceId,
                "--surface",
                surfaceId,
                "--title",
                title,
                "--subtitle",
                "ui-test",
                "--body",
                "focus-regression"
            ],
            responseTimeoutSeconds: 4.0,
            cliStrategy: .bundledOnly
        )
    }

    private func runCmuxCommand(
        socketPath: String,
        arguments: [String],
        responseTimeoutSeconds: Double = 3.0,
        cliStrategy: CmuxCLIStrategy = .any
    ) -> (terminationStatus: Int32, stdout: String, stderr: String) {
        var args = ["--socket", socketPath]
        args.append(contentsOf: arguments)
        var environment = ProcessInfo.processInfo.environment
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = String(responseTimeoutSeconds)

        let cliPaths = resolveCmuxCLIPaths(strategy: cliStrategy)
        if cliPaths.isEmpty, cliStrategy == .bundledOnly {
            return (
                terminationStatus: -1,
                stdout: "",
                stderr: "Failed to locate bundled cmux CLI"
            )
        }

        var lastPermissionFailure: (terminationStatus: Int32, stdout: String, stderr: String)?
        for cliPath in cliPaths {
            let result = executeCmuxCommand(
                executablePath: cliPath,
                arguments: args,
                environment: environment
            )
            if result.terminationStatus == 0 {
                return result
            }
            if result.stderr.localizedCaseInsensitiveContains("operation not permitted") {
                lastPermissionFailure = result
                continue
            }
            return result
        }

        if cliStrategy == .bundledOnly {
            return lastPermissionFailure ?? (
                terminationStatus: -1,
                stdout: "",
                stderr: "Bundled cmux CLI command failed without an executable path"
            )
        }

        let fallbackArgs = ["cmux"] + args
        let fallbackResult = executeCmuxCommand(
            executablePath: "/usr/bin/env",
            arguments: fallbackArgs,
            environment: environment
        )
        if fallbackResult.terminationStatus == 0 || lastPermissionFailure == nil {
            return fallbackResult
        }
        return lastPermissionFailure ?? fallbackResult
    }

    private enum CmuxCLIStrategy: Equatable {
        case any
        case bundledOnly
    }

    private func socketDiagnostics(from data: [String: String]) -> String {
        let pingResponse = data["socketPingResponse"].flatMap { $0.isEmpty ? nil : $0 } ?? "<nil>"
        return "mode=\(data["socketMode"] ?? "") running=\(data["socketIsRunning"] ?? "") " +
            "acceptLoopAlive=\(data["socketAcceptLoopAlive"] ?? "") pathMatches=\(data["socketPathMatches"] ?? "") " +
            "pathExists=\(data["socketPathExists"] ?? "") ping=\(pingResponse) " +
            "signals=\(data["socketFailureSignals"] ?? "")"
    }

    private func resolveCmuxCLIPaths(strategy: CmuxCLIStrategy) -> [String] {
        let fileManager = FileManager.default
        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        var productDirectories: [String] = []

        if strategy == .any {
            for key in ["CMUX_UI_TEST_CLI_PATH", "CMUXTERM_CLI"] {
                if let value = env[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    candidates.append(value)
                }
            }
        }

        if let builtProductsDir = env["BUILT_PRODUCTS_DIR"], !builtProductsDir.isEmpty {
            productDirectories.append(builtProductsDir)
        }

        if let hostPath = env["TEST_HOST"], !hostPath.isEmpty {
            let hostURL = URL(fileURLWithPath: hostPath)
            let productsDir = hostURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .path
            productDirectories.append(productsDir)
        }

        productDirectories.append(contentsOf: inferredBuildProductsDirectories())
        for productsDir in uniquePaths(productDirectories) {
            appendCLIPathCandidates(fromProductsDirectory: productsDir, strategy: strategy, to: &candidates)
        }

        candidates.append("/tmp/cmux-\(launchTag)/Build/Products/Debug/cmux DEV.app/Contents/Resources/bin/cmux")
        candidates.append("/tmp/cmux-\(launchTag)/Build/Products/Debug/cmux.app/Contents/Resources/bin/cmux")
        if strategy == .any {
            candidates.append("/tmp/cmux-\(launchTag)/Build/Products/Debug/cmux")
        }

        var resolvedPaths: [String] = []
        for path in uniquePaths(candidates) {
            guard fileManager.isExecutableFile(atPath: path) else { continue }
            resolvedPaths.append(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
        }
        return uniquePaths(resolvedPaths)
    }

    private func inferredBuildProductsDirectories() -> [String] {
        let bundleURLs = [
            Bundle.main.bundleURL,
            Bundle(for: Self.self).bundleURL,
        ]

        return bundleURLs.compactMap { bundleURL in
            let standardizedPath = bundleURL.standardizedFileURL.path
            let components = standardizedPath.split(separator: "/")
            guard let productsIndex = components.firstIndex(of: "Products"),
                  productsIndex + 1 < components.count else {
                return nil
            }
            let prefixComponents = components.prefix(productsIndex + 2)
            return "/" + prefixComponents.joined(separator: "/")
        }
    }

    private func appendCLIPathCandidates(
        fromProductsDirectory productsDir: String,
        strategy: CmuxCLIStrategy,
        to candidates: inout [String]
    ) {
        candidates.append("\(productsDir)/cmux DEV.app/Contents/Resources/bin/cmux")
        candidates.append("\(productsDir)/cmux.app/Contents/Resources/bin/cmux")
        if strategy == .any {
            candidates.append("\(productsDir)/cmux")
        }

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: productsDir) else {
            return
        }

        for entry in entries.sorted() where entry.hasSuffix(".app") {
            let cliPath = URL(fileURLWithPath: productsDir)
                .appendingPathComponent(entry)
                .appendingPathComponent("Contents/Resources/bin/cmux")
                .path
            candidates.append(cliPath)
        }
        if strategy == .any {
            for entry in entries.sorted() where entry == "cmux" {
                let cliPath = URL(fileURLWithPath: productsDir)
                    .appendingPathComponent(entry)
                    .path
                candidates.append(cliPath)
            }
        }
    }

    private func executeCmuxCommand(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) -> (terminationStatus: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (
                terminationStatus: -1,
                stdout: "",
                stderr: "Failed to run cmux command: \(error.localizedDescription) (cliPath=\(executablePath))"
            )
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawStderr = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = rawStderr.isEmpty ? "" : "\(rawStderr) (cliPath=\(executablePath))"
        return (process.terminationStatus, stdout, stderr)
    }

    private func isSocketPermissionFailure(_ stderr: String?) -> Bool {
        guard let stderr, !stderr.isEmpty else { return false }
        return stderr.localizedCaseInsensitiveContains("failed to connect to socket") &&
            stderr.localizedCaseInsensitiveContains("operation not permitted")
    }

    private func uniquePaths(_ paths: [String]) -> [String] {
        var unique: [String] = []
        var seen = Set<String>()
        for path in paths {
            if seen.insert(path).inserted {
                unique.append(path)
            }
        }
        return unique
    }

    private func resolveSocketPath(timeout: TimeInterval, requiredWorkspaceId: String? = nil) -> String? {
        let primaryCandidates = expectedSocketCandidates(includeGlobalFallback: false)
        let fallbackCandidates: [String]
        if let requiredWorkspaceId, !requiredWorkspaceId.isEmpty {
            fallbackCandidates = expectedSocketCandidates(includeGlobalFallback: true)
                .filter { !primaryCandidates.contains($0) }
        } else {
            fallbackCandidates = []
        }

        var resolvedPath: String?
        _ = waitForCondition(timeout: timeout) {
            for candidate in primaryCandidates {
                guard FileManager.default.fileExists(atPath: candidate) else { continue }
                // Primary candidate is the explicitly requested CMUX_SOCKET_PATH. If it responds,
                // prefer it even before workspace contents are fully initialized.
                if self.socketRespondsToPing(at: candidate) {
                    resolvedPath = candidate
                    return true
                }
            }
            for candidate in fallbackCandidates {
                guard FileManager.default.fileExists(atPath: candidate) else { continue }
                if self.socketRespondsToPing(at: candidate),
                   self.socketMatchesRequiredWorkspace(candidate, workspaceId: requiredWorkspaceId) {
                    resolvedPath = candidate
                    return true
                }
            }
            return false
        }
        if let resolvedPath {
            return resolvedPath
        }
        for candidate in primaryCandidates {
            guard FileManager.default.fileExists(atPath: candidate) else { continue }
            if socketRespondsToPing(at: candidate) {
                return candidate
            }
        }
        for candidate in fallbackCandidates {
            guard FileManager.default.fileExists(atPath: candidate) else { continue }
            if socketRespondsToPing(at: candidate),
               socketMatchesRequiredWorkspace(candidate, workspaceId: requiredWorkspaceId) {
                return candidate
            }
        }
        return nil
    }

    private func expectedSocketCandidates(includeGlobalFallback: Bool) -> [String] {
        var candidates = [socketPath]
        let taggedDebugSocket = "/tmp/cmux-debug-\(launchTag).sock"
        if !taggedDebugSocket.isEmpty {
            candidates.append(taggedDebugSocket)
        }
        if includeGlobalFallback {
            candidates.append(contentsOf: discoverTmpSocketCandidates(limit: 12))
            candidates.append("/tmp/cmux-debug.sock")
            candidates.append(stableSocketPath())
            candidates.append("/tmp/cmux.sock")
        }

        var unique: [String] = []
        var seen = Set<String>()
        for candidate in candidates {
            if seen.insert(candidate).inserted {
                unique.append(candidate)
            }
        }
        return unique
    }

    private func stableSocketPath() -> String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("cmux.sock", isDirectory: false)
            .path ?? "/tmp/cmux.sock"
    }

    private func socketMatchesRequiredWorkspace(_ candidatePath: String, workspaceId: String?) -> Bool {
        guard let workspaceId, !workspaceId.isEmpty else { return true }
        let originalPath = socketPath
        socketPath = candidatePath
        defer { socketPath = originalPath }

        guard let response = socketCommand("list_surfaces \(workspaceId)"),
              !response.isEmpty,
              !response.hasPrefix("ERROR"),
              response != "No surfaces" else {
            return false
        }
        return true
    }

    private func discoverTmpSocketCandidates(limit: Int) -> [String] {
        let tmpPath = "/tmp"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: tmpPath) else {
            return []
        }

        let matches = entries.filter { $0.hasPrefix("cmux") && $0.hasSuffix(".sock") }
        let sorted = matches.compactMap { entry -> (path: String, mtime: Date)? in
            let fullPath = (tmpPath as NSString).appendingPathComponent(entry)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath) else {
                return nil
            }
            let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
            return (fullPath, mtime)
        }
        .sorted { $0.mtime > $1.mtime }

        return Array(sorted.prefix(limit)).map(\.path)
    }

    private func socketRespondsToPing(at path: String) -> Bool {
        let originalPath = socketPath
        socketPath = path
        defer { socketPath = originalPath }
        return socketCommand("ping") == "PONG"
    }

    private func socketCommand(_ cmd: String, responseTimeout: TimeInterval = 2.0) -> String? {
        if let response = ControlSocketClient(path: socketPath, responseTimeout: responseTimeout).sendLine(cmd) {
            return response
        }
        return socketCommandViaNetcat(cmd, responseTimeout: responseTimeout)
    }

    private func socketCommandViaNetcat(_ cmd: String, responseTimeout: TimeInterval = 2.0) -> String? {
        let nc = "/usr/bin/nc"
        guard FileManager.default.isExecutableFile(atPath: nc) else { return nil }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        let timeoutSeconds = max(1, Int(ceil(responseTimeout)))
        let script = "printf '%s\\n' \(shellSingleQuote(cmd)) | \(nc) -U \(shellSingleQuote(socketPath)) -w \(timeoutSeconds) 2>/dev/null"
        proc.arguments = ["-lc", script]

        let outPipe = Pipe()
        proc.standardOutput = outPipe

        do {
            try proc.run()
        } catch {
            return nil
        }

        proc.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let outStr = String(data: outData, encoding: .utf8) else { return nil }
        if let first = outStr.split(separator: "\n", maxSplits: 1).first {
            return String(first).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let trimmed = outStr.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func shellSingleQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func readTrimmedFile(atPath path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private final class ControlSocketClient {
        private let path: String
        private let responseTimeout: TimeInterval

        init(path: String, responseTimeout: TimeInterval = 2.0) {
            self.path = path
            self.responseTimeout = responseTimeout
        }

        func sendLine(_ line: String) -> String? {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var socketTimeout = timeval(
                tv_sec: Int(responseTimeout.rounded(.down)),
                tv_usec: Int32(((responseTimeout - floor(responseTimeout)) * 1_000_000).rounded())
            )

#if os(macOS)
            var noSigPipe: Int32 = 1
            _ = withUnsafePointer(to: &noSigPipe) { ptr in
                setsockopt(
                    fd,
                    SOL_SOCKET,
                    SO_NOSIGPIPE,
                    ptr,
                    socklen_t(MemoryLayout<Int32>.size)
                )
            }
#endif
            _ = withUnsafePointer(to: &socketTimeout) { ptr in
                setsockopt(
                    fd,
                    SOL_SOCKET,
                    SO_RCVTIMEO,
                    ptr,
                    socklen_t(MemoryLayout<timeval>.size)
                )
            }
            _ = withUnsafePointer(to: &socketTimeout) { ptr in
                setsockopt(
                    fd,
                    SOL_SOCKET,
                    SO_SNDTIMEO,
                    ptr,
                    socklen_t(MemoryLayout<timeval>.size)
                )
            }

            var addr = sockaddr_un()
            memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
            addr.sun_family = sa_family_t(AF_UNIX)

            let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
            let bytes = Array(path.utf8CString)
            guard bytes.count <= maxLen else { return nil }
            withUnsafeMutablePointer(to: &addr.sun_path) { p in
                let raw = UnsafeMutableRawPointer(p).assumingMemoryBound(to: CChar.self)
                memset(raw, 0, maxLen)
                for i in 0..<bytes.count {
                    raw[i] = bytes[i]
                }
            }

            let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
            let addrLen = socklen_t(pathOffset + bytes.count)
#if os(macOS)
            addr.sun_len = UInt8(min(Int(addrLen), 255))
#endif

            let connected = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    connect(fd, sa, addrLen)
                }
            }
            guard connected == 0 else { return nil }

            let payload = line + "\n"
            let wrote: Bool = payload.withCString { cstr in
                var remaining = strlen(cstr)
                var p = UnsafeRawPointer(cstr)
                while remaining > 0 {
                    let n = write(fd, p, remaining)
                    if n <= 0 { return false }
                    remaining -= n
                    p = p.advanced(by: n)
                }
                return true
            }
            guard wrote else { return nil }

            var buf = [UInt8](repeating: 0, count: 4096)
            var accum = ""
            while true {
                let n = read(fd, &buf, buf.count)
                if n < 0 {
                    let code = errno
                    if code == EAGAIN || code == EWOULDBLOCK {
                        break
                    }
                    return nil
                }
                if n <= 0 { break }
                if let chunk = String(bytes: buf[0..<n], encoding: .utf8) {
                    accum.append(chunk)
                    if let idx = accum.firstIndex(of: "\n") {
                        return String(accum[..<idx])
                    }
                }
            }
            return accum.isEmpty ? nil : accum.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func readCurrentTerminalText() -> String? {
        guard let response = socketCommand("read_terminal_text"), response.hasPrefix("OK ") else {
            return nil
        }
        let encoded = String(response.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func loadData() -> [String: String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: dataPath)) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
    }
}
