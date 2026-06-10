import XCTest
import Foundation
import CoreGraphics


// MARK: - Notification Routing and Focus Across Windows Tests
extension MultiWindowNotificationsUITests {
    func testNotificationsRouteToCorrectWindow() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_PATH"] = dataPath
        app.launchEnvironment["CMUX_TAG"] = launchTag
        launchAllowingHeadlessBackgroundActivation(app)
        XCTAssertTrue(
            ensureAppRunningAfterLaunch(app, timeout: 12.0),
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
        XCTAssertTrue(
            ensureAppForegroundForInteraction(app, timeout: 6.0),
            "Expected cmux to be foreground before sending notification shortcut. state=\(app.state.rawValue)"
        )

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
        launchAllowingHeadlessBackgroundActivation(app)
        XCTAssertTrue(
            ensureAppRunningAfterLaunch(app, timeout: 12.0),
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

        XCTAssertTrue(
            ensureAppForegroundForInteraction(app, timeout: 6.0),
            "Expected cmux to be foreground before typing delayed notify command. state=\(app.state.rawValue)"
        )
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

}
