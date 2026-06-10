import XCTest
import Foundation
import CoreGraphics


// MARK: - CLI Workspace and Window Targeting Tests
extension MultiWindowNotificationsUITests {
    func testOpenNotificationCLISelectsWorkspaceSurfaceAndMarksRowRead() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-socketControlMode", "allowAll"]
        app.launchEnvironment["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_PATH"] = dataPath
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_SOCKET_MODE"] = "allowAll"
        app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        app.launchEnvironment["CMUX_TAG"] = launchTag
        launchAllowingHeadlessBackgroundActivation(app)
        XCTAssertTrue(
            ensureAppRunningAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for open-notification CLI test. state=\(app.state.rawValue)"
        )
        XCTAssertTrue(
            waitForDataMatch(timeout: 20.0) { data in
                let tabId2 = data["tabId2"] ?? ""
                let surfaceId2 = data["surfaceId2"] ?? ""
                let window2Id = data["window2Id"] ?? ""
                let socketReady = data["socketReady"] ?? ""
                return !tabId2.isEmpty &&
                    !surfaceId2.isEmpty &&
                    !window2Id.isEmpty &&
                    !socketReady.isEmpty &&
                    socketReady != "pending"
            },
            "Expected multi-window notification setup data and socket readiness"
        )

        guard let setup = loadData() else {
            XCTFail("Missing setup data")
            return
        }
        if let expectedSocketPath = setup["socketExpectedPath"], !expectedSocketPath.isEmpty {
            socketPath = expectedSocketPath
        }
        guard setup["socketReady"] == "1" else {
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
        let tabId2 = try XCTUnwrap(setup["tabId2"])
        let surfaceId2 = try XCTUnwrap(setup["surfaceId2"])
        let window2Id = try XCTUnwrap(setup["window2Id"])

        let title = "open-cli-\(UUID().uuidString.prefix(8))"
        let notifyResult = runCmuxCommand(
            socketPath: socketPath,
            arguments: [
                "notify",
                "--workspace",
                tabId2,
                "--surface",
                surfaceId2,
                "--title",
                title,
                "--subtitle",
                "ui-test",
                "--body",
                "open-notification",
            ],
            responseTimeoutSeconds: 6.0,
            cliStrategy: .bundledOnly
        )
        XCTAssertEqual(notifyResult.terminationStatus, 0, notifyResult.stderr)

        guard let notification = waitForNotification(title: title, timeout: 8.0),
              let notificationId = notification["id"] as? String,
              !notificationId.isEmpty else {
            XCTFail("Expected CLI-created notification to appear in list-notifications")
            return
        }

        let beforeToken = loadData()?["focusToken"]
        let openResult = runCmuxCommand(
            socketPath: socketPath,
            arguments: [
                "open-notification",
                "--id",
                notificationId,
                "--json",
                "--id-format",
                "uuids",
            ],
            responseTimeoutSeconds: 6.0,
            cliStrategy: .bundledOnly
        )
        XCTAssertEqual(openResult.terminationStatus, 0, openResult.stderr)
        let openPayload = parseJSONObject(openResult.stdout)
        XCTAssertEqual(openPayload?["workspace_id"] as? String, tabId2)
        XCTAssertEqual(openPayload?["surface_id"] as? String, surfaceId2)

        XCTAssertTrue(
            waitForFocusChange(from: beforeToken, timeout: 8.0),
            "Expected focus record after open-notification CLI command"
        )
        guard let afterOpen = loadData() else {
            XCTFail("Missing focus data after open-notification")
            return
        }
        XCTAssertEqual(afterOpen["focusedWindowId"], window2Id)
        XCTAssertEqual(afterOpen["focusedTabId"], tabId2)
        XCTAssertEqual(afterOpen["focusedSurfaceId"], surfaceId2)
        XCTAssertEqual(afterOpen["focusedSidebarSelection"], "tabs")
        XCTAssertTrue(
            waitForNotificationRead(notificationId, timeout: 8.0),
            "Expected open-notification to mark the opened row read"
        )
    }

    func testNewWorkspaceCLIWindowFlagTargetsSpecificWindow() throws {
        let app = XCUIApplication()
        let title = "window-route-\(UUID().uuidString.prefix(8))"
        app.launchArguments += ["-socketControlMode", "allowAll"]
        app.launchEnvironment["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_PATH"] = dataPath
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_SOCKET_MODE"] = "allowAll"
        app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_WINDOW_ROUTE_CLI"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_WINDOW_ROUTE_CLI_TITLE"] = title
        app.launchEnvironment["CMUX_TAG"] = launchTag
        launchAllowingHeadlessBackgroundActivation(app)
        XCTAssertTrue(
            ensureAppRunningAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for CLI --window workspace routing test. state=\(app.state.rawValue)"
        )
        XCTAssertTrue(
            waitForDataMatch(timeout: 20.0) { data in
                let window1Id = data["window1Id"] ?? ""
                let window2Id = data["window2Id"] ?? ""
                let tabId1 = data["tabId1"] ?? ""
                let socketReady = data["socketReady"] ?? ""
                let routeStatus = data["windowRouteStatus"] ?? ""
                return !window1Id.isEmpty &&
                    !window2Id.isEmpty &&
                    !tabId1.isEmpty &&
                    !socketReady.isEmpty &&
                    socketReady != "pending" &&
                    !routeStatus.isEmpty &&
                    routeStatus != "pending"
            },
            "Expected multi-window setup data, socket readiness, and CLI route result. data=\(loadData() ?? [:])"
        )

        guard let setup = loadData() else {
            XCTFail("Missing setup data")
            return
        }
        if let expectedSocketPath = setup["socketExpectedPath"], !expectedSocketPath.isEmpty {
            socketPath = expectedSocketPath
        }
        guard setup["socketReady"] == "1" else {
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
        let window1Id = try XCTUnwrap(setup["window1Id"])
        let window2Id = try XCTUnwrap(setup["window2Id"])
        XCTAssertTrue(waitForWindowCount(atLeast: 2, app: app, timeout: 6.0))

        XCTAssertEqual(
            setup["windowRouteStatus"],
            "1",
            "Expected bundled `cmux --window` route test hook to finish. failure=\(setup["windowRouteFailure"] ?? "")"
        )

        let createExitStatus = setup["windowRouteCreateStatus"] ?? "<missing>"
        let createStdout = setup["windowRouteCreateStdout"] ?? ""
        let createStderr = setup["windowRouteCreateStderr"] ?? ""
        XCTAssertEqual(
            createExitStatus,
            "0",
            "Expected `new-workspace --window` to succeed. stdout=\(createStdout) stderr=\(createStderr)"
        )

        let window2ExitStatus = setup["windowRouteWindow2Status"] ?? "<missing>"
        let window2Stdout = setup["windowRouteWindow2Stdout"] ?? ""
        let window2Stderr = setup["windowRouteWindow2Stderr"] ?? ""
        XCTAssertEqual(
            window2ExitStatus,
            "0",
            "Expected `list-workspaces --window` for target window to succeed. stdout=\(window2Stdout) stderr=\(window2Stderr)"
        )
        guard let window2Payload = parseJSONObject(window2Stdout),
              let window2Rows = window2Payload["workspaces"] as? [[String: Any]] else {
            XCTFail("Failed to parse target window workspace list. stdout=\(window2Stdout) stderr=\(window2Stderr)")
            return
        }
        XCTAssertTrue(
            window2Rows.contains { $0["title"] as? String == title },
            "Expected new workspace '\(title)' in targeted window \(window2Id). stdout=\(window2Stdout)"
        )

        let window1ExitStatus = setup["windowRouteWindow1Status"] ?? "<missing>"
        let window1Stdout = setup["windowRouteWindow1Stdout"] ?? ""
        let window1Stderr = setup["windowRouteWindow1Stderr"] ?? ""
        XCTAssertEqual(
            window1ExitStatus,
            "0",
            "Expected `list-workspaces --window` for source window to succeed. stdout=\(window1Stdout) stderr=\(window1Stderr)"
        )
        guard let window1Payload = parseJSONObject(window1Stdout),
              let window1Rows = window1Payload["workspaces"] as? [[String: Any]] else {
            XCTFail("Failed to parse source window workspace list. stdout=\(window1Stdout) stderr=\(window1Stderr)")
            return
        }
        XCTAssertFalse(
            window1Rows.contains { $0["title"] as? String == title },
            "Expected new workspace '\(title)' not to appear in source window \(window1Id). stdout=\(window1Stdout)"
        )
    }

}
