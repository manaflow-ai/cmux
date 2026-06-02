import AppKit
import XCTest
import Foundation

private func sidebarHelpPollUntil(
    timeout: TimeInterval,
    pollInterval: TimeInterval = 0.05,
    condition: () -> Bool
) -> Bool {
    let start = ProcessInfo.processInfo.systemUptime
    while true {
        if condition() {
            return true
        }
        if (ProcessInfo.processInfo.systemUptime - start) >= timeout {
            return false
        }
        RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
    }
}

final class SidebarHelpMenuUITests: XCTestCase {
    private let socketBridgePasteboardRequestType = NSPasteboard.PasteboardType("com.cmux.ui-test.socket-bridge.request")
    private let socketBridgePasteboardResponseType = NSPasteboard.PasteboardType("com.cmux.ui-test.socket-bridge.response")
    private var socketPath = ""
    private var socketBridgePath = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        resetMenuBarOnlyDefault()
        terminateUserNotificationCenter()
        XCUIApplication().terminate()
        socketPath = "/tmp/cmux-ui-test-sidebar-help-\(UUID().uuidString).sock"
        socketBridgePath = "/tmp/cmux-ui-test-sidebar-help-bridge-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: socketPath)
        removeSidebarSocketBridgeFiles()
    }

    override func tearDown() {
        XCUIApplication().terminate()
        terminateUserNotificationCenter()
        resetMenuBarOnlyDefault()
        try? FileManager.default.removeItem(atPath: socketPath)
        removeSidebarSocketBridgeFiles()
        super.tearDown()
    }

    func testHelpMenuCheckForUpdatesTriggersSidebarUpdatePill() {
        let app = XCUIApplication()
        configureSidebarHelpLaunch(app)
        app.launchEnvironment["CMUX_UI_TEST_FEED_URL"] = "https://cmux.test/appcast.xml"
        app.launchEnvironment["CMUX_UI_TEST_FEED_MODE"] = "available"
        app.launchEnvironment["CMUX_UI_TEST_UPDATE_VERSION"] = "9.9.9"
        app.launchEnvironment["CMUX_UI_TEST_TRIGGER_UPDATE_CHECK"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_DEFER_UPDATE_CHECK_TO_ACTION"] = "1"
        launchAndActivate(app)

        XCTAssertTrue(
            waitForSidebarReady(app: app, timeout: 8.0),
            "Expected sidebar help controls to be ready. \(sidebarReadinessDebug(app: app))"
        )
        XCTAssertTrue(
            openSidebarHelpMenu(
                app: app,
                expectedItemIdentifier: "SidebarHelpMenuOptionCheckForUpdates",
                expectedItemTitle: "Check for Updates"
            ),
            "Expected the sidebar help menu to open. \(sidebarReadinessDebug(app: app))"
        )

        let checkForUpdatesItem = requireElement(
            candidates: helpMenuItemCandidates(in: app, identifier: "SidebarHelpMenuOptionCheckForUpdates", title: "Check for Updates"),
            timeout: 3.0,
            description: "Check for Updates help menu item"
        )
        XCTAssertTrue(checkForUpdatesItem.exists)
        performSidebarHelpAction("check_for_updates")

        let updatePill = app.buttons["Update Available: 9.9.9"]
        XCTAssertTrue(updatePill.waitForExistence(timeout: 8.0))
        XCTAssertEqual(updatePill.label, "Update Available: 9.9.9")
    }

    func testHelpMenuSendFeedbackOpensComposerSheet() throws {
        let app = XCUIApplication()
        configureSidebarHelpLaunch(app)
        launchAndActivate(app)

        XCTAssertTrue(
            waitForSidebarReady(app: app, timeout: 8.0),
            "Expected sidebar help controls to be ready. \(sidebarReadinessDebug(app: app))"
        )
        let mainWindowId = try XCTUnwrap(
            sidebarSocketCommand("current_window")?.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        XCTAssertTrue(
            openSidebarHelpMenu(
                app: app,
                expectedItemIdentifier: "SidebarHelpMenuOptionSendFeedback",
                expectedItemTitle: "Send Feedback"
            ),
            "Expected the sidebar help menu to open. \(sidebarReadinessDebug(app: app))"
        )

        let sendFeedbackItem = requireElement(
            candidates: helpMenuItemCandidates(in: app, identifier: "SidebarHelpMenuOptionSendFeedback", title: "Send Feedback"),
            timeout: 3.0,
            description: "Send Feedback help menu item"
        )
        XCTAssertTrue(sendFeedbackItem.exists)
        performSidebarHelpAction("send_feedback", windowId: mainWindowId)

        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 8.0) {
                app.otherElements["SidebarFeedbackDialog"].exists
                    || app.textFields["SidebarFeedbackEmailField"].exists
                    || app.staticTexts["Send Feedback"].exists
            },
            "Expected the feedback composer to appear after running the sidebar help action"
        )
        XCTAssertTrue(app.staticTexts["Send Feedback"].waitForExistence(timeout: 3.0))
        XCTAssertTrue(
            firstExistingElement(
                candidates: [
                    app.textFields["SidebarFeedbackEmailField"],
                    app.textFields["Your Email"],
                ],
                timeout: 2.0
            ) != nil
        )
        XCTAssertTrue(
            firstExistingElement(
                candidates: [
                    app.buttons["SidebarFeedbackAttachButton"],
                    app.buttons["Attach Images"],
                ],
                timeout: 2.0
            ) != nil
        )
        XCTAssertTrue(
            firstExistingElement(
                candidates: [
                    app.buttons["SidebarFeedbackSendButton"],
                    app.buttons["Send"],
                ],
                timeout: 2.0
            ) != nil
        )
        let messageEditor = requireElement(
            candidates: [
                app.textViews["SidebarFeedbackMessageEditor"],
                app.scrollViews["SidebarFeedbackMessageEditor"],
                app.otherElements["SidebarFeedbackMessageEditor"],
                app.textViews["Message"],
            ],
            timeout: 2.0,
            description: "feedback message editor"
        )
        XCTAssertTrue(messageEditor.exists)
        setFeedbackMessage("hello", windowId: mainWindowId)
        let messageCounter = app.descendants(matching: .any)["SidebarFeedbackMessageCounter"]
        var observedCounterLabel = "<missing>"
        let didUpdateCounter = sidebarHelpPollUntil(timeout: 3.0) {
            guard messageCounter.exists else {
                observedCounterLabel = "<missing>"
                return false
            }
            let value = messageCounter.value as? String
            observedCounterLabel = value.map { "\(messageCounter.label) value=\($0)" } ?? messageCounter.label
            return messageCounter.label == "5/4000" || value == "5/4000"
        }
        XCTAssertTrue(
            didUpdateCounter,
            "Expected feedback message counter to update to 5/4000, got \(observedCounterLabel)"
        )
    }

    private func configureSidebarHelpLaunch(_ app: XCUIApplication) {
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-ApplePersistenceIgnoreState", "YES",
            "-NSQuitAlwaysKeepsWindows", "NO",
            "-workspacePresentationMode", "standard",
            "-menuBarOnly", "false",
            "-showSidebarDevBuildBanner", "false",
        ]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SUPPRESS_SYSTEM_NOTIFICATIONS"] = "1"
        app.launchArguments += ["-socketControlMode", "allowAll"]
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_MODE"] = "allowAll"
        app.launchEnvironment["CMUX_ALLOW_SOCKET_OVERRIDE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_BRIDGE_PATH"] = socketBridgePath
    }

    private func removeSidebarSocketBridgeFiles() {
        guard !socketBridgePath.isEmpty else { return }
        try? FileManager.default.removeItem(atPath: socketBridgePath)
        try? FileManager.default.removeItem(atPath: socketBridgePath + ".request")
        try? FileManager.default.removeItem(atPath: socketBridgePath + ".response")
    }

    private func performSidebarHelpAction(
        _ action: String,
        windowId: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var params: [String: Any] = ["action": action]
        if let windowId {
            params["window_id"] = windowId
        }
        let response = sidebarSocketJSON(
            method: "debug.sidebar_help.perform",
            params: params,
            timeout: 8.0
        )
        XCTAssertEqual(response?["ok"] as? Bool, true, "Expected sidebar help action \(action) to succeed. response=\(response ?? [:])", file: file, line: line)
    }

    private func setFeedbackMessage(
        _ message: String,
        windowId: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let response = sidebarSocketJSON(
            method: "debug.feedback.message.set",
            params: [
                "message": message,
                "window_id": windowId,
            ],
            timeout: 8.0
        )
        XCTAssertEqual(response?["ok"] as? Bool, true, "Expected feedback message debug set to succeed. response=\(response ?? [:])", file: file, line: line)
    }

    private func sidebarSocketJSON(method: String, params: [String: Any], timeout: TimeInterval) -> [String: Any]? {
        let request: [String: Any] = [
            "id": UUID().uuidString,
            "method": method,
            "params": params,
        ]
        guard JSONSerialization.isValidJSONObject(request),
              let data = try? JSONSerialization.data(withJSONObject: request),
              let line = String(data: data, encoding: .utf8) else {
            return nil
        }

        var response: [String: Any]?
        _ = sidebarHelpPollUntil(timeout: timeout) {
            guard let raw = sidebarSocketBridgeCommand(line, responseTimeout: 1.0),
                  let responseData = raw.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                return false
            }
            response = parsed
            return true
        }
        return response
    }

    private func sidebarSocketCommand(_ command: String) -> String? {
        sidebarSocketBridgeCommand(command, responseTimeout: 2.0)
    }

    private func sidebarSocketBridgeCommand(_ command: String, responseTimeout: TimeInterval) -> String? {
        guard !socketBridgePath.isEmpty else { return nil }
        let requestId = UUID().uuidString
        let payload: [String: Any] = [
            "id": requestId,
            "line": command,
            "bridgePath": socketBridgePath,
            "completed": false,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let raw = String(data: data, encoding: .utf8) else {
            return nil
        }

        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([socketBridgePasteboardRequestType], owner: nil)
        pasteboard.setString(raw, forType: socketBridgePasteboardRequestType)

        let deadline = ProcessInfo.processInfo.systemUptime + responseTimeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let response = sidebarSocketBridgeResponse(requestId: requestId) {
                return response
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return nil
    }

    private func sidebarSocketBridgeResponse(requestId: String) -> String? {
        guard let raw = NSPasteboard.general.string(forType: socketBridgePasteboardResponseType),
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["bridgePath"] as? String == socketBridgePath,
              object["id"] as? String == requestId,
              object["completed"] as? Bool == true else {
            return nil
        }
        return object["response"] as? String
    }

    private func waitForWindowCount(atLeast count: Int, app: XCUIApplication, timeout: TimeInterval) -> Bool {
        sidebarHelpPollUntil(timeout: timeout) {
            app.windows.count >= count
        }
    }

    private func waitForSidebarReady(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        sidebarHelpPollUntil(timeout: timeout) {
            app.windows.count >= 1 && app.otherElements["Sidebar"].exists
        }
    }

    private func openSidebarHelpMenu(
        app: XCUIApplication,
        expectedItemIdentifier: String,
        expectedItemTitle: String
    ) -> Bool {
        if let helpButton = firstExistingElement(candidates: helpButtonCandidates(in: app), timeout: 1.5) {
            clickElement(helpButton)
        } else {
            let sidebar = app.otherElements["Sidebar"].firstMatch
            guard sidebar.exists else { return false }
            sidebar.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.965)).click()
        }

        return firstExistingElement(
            candidates: helpMenuItemCandidates(
                in: app,
                identifier: expectedItemIdentifier,
                title: expectedItemTitle
            ),
            timeout: 2.0
        ) != nil
    }

    private func helpButtonCandidates(in app: XCUIApplication) -> [XCUIElement] {
        let sidebar = app.otherElements["Sidebar"]
        return [
            app.buttons["SidebarHelpMenuButton"],
            app.images["SidebarHelpMenuButton"],
            app.otherElements["SidebarHelpMenuButton"],
            app.descendants(matching: .any)["SidebarHelpMenuButton"],
            sidebar.buttons["SidebarHelpMenuButton"],
            sidebar.images["SidebarHelpMenuButton"],
            sidebar.otherElements["SidebarHelpMenuButton"],
            sidebar.descendants(matching: .any)["SidebarHelpMenuButton"],
        ]
    }

    private func sidebarReadinessDebug(app: XCUIApplication) -> String {
        let helpExists = helpButtonCandidates(in: app).map { $0.exists }
        return "state=\(app.state.rawValue) windows=\(app.windows.count) " +
            "sidebar=\(app.otherElements["Sidebar"].exists) helpCandidates=\(helpExists)"
    }

    private func helpMenuItemCandidates(
        in app: XCUIApplication,
        identifier: String,
        title: String
    ) -> [XCUIElement] {
        [
            app.buttons[identifier],
            app.menuItems[identifier],
            app.descendants(matching: .any)[identifier],
            app.buttons[title],
            app.descendants(matching: .any)[title],
        ]
    }

    private func firstExistingElement(
        candidates: [XCUIElement],
        timeout: TimeInterval
    ) -> XCUIElement? {
        var match: XCUIElement?
        let found = sidebarHelpPollUntil(timeout: timeout) {
            for candidate in candidates {
                let resolved = candidate.firstMatch
                guard resolved.exists else { continue }
                match = resolved
                return true
            }
            return false
        }
        return found ? match : nil
    }

    private func requireElement(
        candidates: [XCUIElement],
        timeout: TimeInterval,
        description: String
    ) -> XCUIElement {
        guard let element = firstExistingElement(candidates: candidates, timeout: timeout) else {
            XCTFail("Expected \(description) to exist")
            return candidates[0]
        }
        return element
    }

    private func clickElement(_ element: XCUIElement) {
        let target = element.firstMatch
        if target.isHittable {
            target.click()
        } else {
            target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        }
    }

    private func terminateUserNotificationCenter() {
        let notificationCenter = XCUIApplication(bundleIdentifier: "com.apple.UserNotificationCenter")
        notificationCenter.terminate()
    }

    private func resetMenuBarOnlyDefault() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["write", "com.cmuxterm.app.debug", "menuBarOnly", "-bool", "false"]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
        }
    }

    private func launchAndActivate(_ app: XCUIApplication, activateTimeout: TimeInterval = 2.0) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("Headless CI may launch the app without foreground activation", options: options) {
            app.launch()
        }

        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 10.0) {
                app.state == .runningForeground || app.state == .runningBackground
            },
            "App failed to launch. state=\(app.state.rawValue)"
        )

        if app.state != .runningForeground {
            let activated = sidebarHelpPollUntil(timeout: activateTimeout) {
                guard app.state != .runningForeground else {
                    return true
                }
                app.activate()
                return app.state == .runningForeground
            }
            if !activated {
                app.activate()
            }
        }

        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 6.0) {
                app.state == .runningForeground
            },
            "App did not become foreground before interactions. state=\(app.state.rawValue)"
        )
    }
}

final class FeedbackComposerShortcutUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testCmdOptionFOpensFeedbackComposer() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launch()
        app.activate()

        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 6.0) {
                app.windows.count >= 1
            }
        )

        app.typeKey("f", modifierFlags: [.command, .option])

        XCTAssertTrue(app.staticTexts["Send Feedback"].waitForExistence(timeout: 3.0))
        XCTAssertTrue(
            app.textFields["SidebarFeedbackEmailField"].waitForExistence(timeout: 2.0)
                || app.textFields["Your Email"].waitForExistence(timeout: 2.0)
        )
    }

    func testCmdOptionFWorksWithHiddenSidebar() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launch()
        app.activate()

        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 6.0) {
                app.windows.count >= 1
            }
        )

        app.typeKey("b", modifierFlags: [.command])

        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 3.0) {
                !app.buttons["SidebarHelpMenuButton"].exists
                    && !app.images["SidebarHelpMenuButton"].exists
                    && !app.otherElements["SidebarHelpMenuButton"].exists
            }
        )

        app.typeKey("f", modifierFlags: [.command, .option])

        XCTAssertTrue(app.staticTexts["Send Feedback"].waitForExistence(timeout: 3.0))
    }

    func testCmdOptionFWorksFromSettingsWindow() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SHOW_SETTINGS"] = "1"
        app.launch()
        app.activate()

        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 6.0) {
                app.windows.count >= 2
            }
        )

        app.typeKey("f", modifierFlags: [.command, .option])

        XCTAssertTrue(app.staticTexts["Send Feedback"].waitForExistence(timeout: 3.0))
        XCTAssertTrue(
            app.textFields["SidebarFeedbackEmailField"].waitForExistence(timeout: 2.0)
                || app.textFields["Your Email"].waitForExistence(timeout: 2.0)
        )
    }
}

final class CommandPaletteAllSurfacesUITests: XCTestCase {
    private let socketBridgePasteboardRequestType = NSPasteboard.PasteboardType("com.cmux.ui-test.socket-bridge.request")
    private let socketBridgePasteboardResponseType = NSPasteboard.PasteboardType("com.cmux.ui-test.socket-bridge.response")

    private var socketPath = ""
    private var socketBridgePath = ""
    private var diagnosticsPath = ""
    private let debugDefaultsDomain = "com.cmuxterm.app.debug"
    private let hiddenSurfaceToken = "cmux-command-palette-hidden-surface"
    private let visibleSurfaceToken = "cmux-command-palette-visible-surface"
    private let noMatchWorkspaceQuery = "cmux-command-palette-no-match"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        resetMenuBarOnlyDefault()
        XCUIApplication().terminate()
        socketPath = "/tmp/cmux-ui-test-command-palette-\(UUID().uuidString).sock"
        socketBridgePath = "/tmp/cmux-ui-test-command-palette-bridge-\(UUID().uuidString).json"
        diagnosticsPath = "/tmp/cmux-ui-test-command-palette-diagnostics-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: socketPath)
        removeSocketBridgeFiles()
        try? FileManager.default.removeItem(atPath: diagnosticsPath)
    }

    override func tearDown() {
        XCUIApplication().terminate()
        resetMenuBarOnlyDefault()
        try? FileManager.default.removeItem(atPath: socketPath)
        removeSocketBridgeFiles()
        try? FileManager.default.removeItem(atPath: diagnosticsPath)
        super.tearDown()
    }

    private func configureCommandPaletteLaunch(_ app: XCUIApplication) {
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-ApplePersistenceIgnoreState", "YES",
            "-NSQuitAlwaysKeepsWindows", "NO",
            "-workspacePresentationMode", "standard",
            "-menuBarOnly", "false",
        ]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
    }

    private func configureSocketControlledLaunch(
        _ app: XCUIApplication,
        showSettingsWindow: Bool = false
    ) {
        configureCommandPaletteLaunch(app)
        app.launchArguments += ["-socketControlMode", "allowAll"]
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_MODE"] = "allowAll"
        app.launchEnvironment["CMUX_ALLOW_SOCKET_OVERRIDE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_BRIDGE_PATH"] = socketBridgePath
        app.launchEnvironment["CMUX_UI_TEST_DIAGNOSTICS_PATH"] = diagnosticsPath
        if showSettingsWindow {
            app.launchEnvironment["CMUX_UI_TEST_SHOW_SETTINGS"] = "1"
        }
    }

    func testCmdShiftPBackspaceReturnsToWorkspaceResults() throws {
        let app = XCUIApplication()
        configureSocketControlledLaunch(app)
        launchAndActivate(app)

        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 8.0) {
                app.windows.count >= 1
            },
            "Expected the main window to be visible"
        )
        XCTAssertTrue(waitForSocketPong(timeout: 12.0), "Expected control dispatcher. \(socketReadinessDebug())")

        let mainWindowId = try XCTUnwrap(
            socketCommand("current_window")?.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        openCommandPaletteCommands(app: app)

        _ = try XCTUnwrap(
            waitForCommandPaletteSnapshot(windowId: mainWindowId, mode: "commands", query: "", timeout: 5.0) { snapshot in
                self.commandPaletteResultRows(from: snapshot).contains { row in
                    let commandId = row["command_id"] as? String ?? ""
                    return !commandId.hasPrefix("switcher.")
                }
            }
        )

        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])

        let switcherSnapshot = try XCTUnwrap(
            waitForCommandPaletteSnapshot(windowId: mainWindowId, mode: "switcher", query: "", timeout: 5.0) { snapshot in
                self.commandPaletteResultRows(from: snapshot).contains { row in
                    let commandId = row["command_id"] as? String ?? ""
                    return commandId.hasPrefix("switcher.workspace.")
                }
            }
        )

        XCTAssertTrue(
            commandPaletteResultRows(from: switcherSnapshot).contains { row in
                let commandId = row["command_id"] as? String ?? ""
                return commandId.hasPrefix("switcher.workspace.")
            },
            "Expected deleting the command prefix to restore workspace rows. snapshot=\(switcherSnapshot)"
        )

        let rows = commandPaletteResultRows(from: switcherSnapshot)
        let firstRowCommandId = rows.first?["command_id"] as? String ?? ""
        XCTAssertTrue(
            firstRowCommandId.hasPrefix("switcher.workspace."),
            "Expected the first restored row to be a workspace. snapshot=\(switcherSnapshot)"
        )

        let firstWorkspaceRow = try XCTUnwrap(
            rows.first(where: { row in
                let commandId = row["command_id"] as? String ?? ""
                return commandId.hasPrefix("switcher.workspace.")
            }),
            "Expected a workspace row in the restored switcher results. snapshot=\(switcherSnapshot)"
        )
        let workspaceTitle = try XCTUnwrap(
            firstWorkspaceRow["title"] as? String,
            "Expected the restored workspace row to include a title. snapshot=\(switcherSnapshot)"
        )
        let workspaceLabel = app.staticTexts[workspaceTitle].firstMatch
        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 2.0) {
                workspaceLabel.exists
            },
            "Expected the restored workspace row to be rendered. title=\(workspaceTitle) snapshot=\(switcherSnapshot)"
        )

        let staleCommandLabel = app.staticTexts["Close Other Workspaces"].firstMatch
        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 2.0) {
                !staleCommandLabel.exists || !staleCommandLabel.isHittable
            },
            "Expected the stale command row to disappear after deleting the command prefix. snapshot=\(switcherSnapshot)"
        )
    }

    func testCmdShiftPCheckQueryPrefersCheckForUpdatesBeforeAttemptUpdate() throws {
        let app = XCUIApplication()
        configureSocketControlledLaunch(app)
        launchAndActivate(app)

        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 8.0) {
                app.windows.count >= 1
            },
            "Expected the main window to be visible"
        )
        XCTAssertTrue(waitForSocketPong(timeout: 12.0), "Expected control dispatcher. \(socketReadinessDebug())")

        let mainWindowId = try XCTUnwrap(
            socketCommand("current_window")?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        try openCommandPaletteCommands(app: app, windowId: mainWindowId, query: "check")

        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 5.0) {
                let values = self.commandPaletteRowValues(app: app, limit: 12)
                guard let checkIndex = values.firstIndex(of: "palette.checkForUpdates"),
                      let attemptIndex = values.firstIndex(of: "palette.attemptUpdate") else {
                    return false
                }
                return checkIndex < attemptIndex
            },
            "Expected the check query to rank Check for Updates before Attempt Update. " +
            "values=\(commandPaletteRowValues(app: app, limit: 12))"
        )
    }

    func testCmdPSearchCanIncludeSurfacesFromOtherWorkspacesWhenEnabled() throws {
        let app = XCUIApplication()
        configureSocketControlledLaunch(app)
        launchAndActivate(app)

        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 8.0) {
                app.windows.count >= 1
            },
            "Expected the main window to be visible"
        )
        XCTAssertTrue(waitForSocketPong(timeout: 12.0), "Expected control dispatcher. \(socketReadinessDebug())")

        let mainWindowId = try XCTUnwrap(socketCommand("current_window")?.trimmingCharacters(in: .whitespacesAndNewlines))
        let secondaryWorkspaceId = try XCTUnwrap(okUUID(from: socketCommand("new_workspace")))
        XCTAssertEqual(socketCommand("select_workspace \(secondaryWorkspaceId)"), "OK")
        let initialSurfaceId = try XCTUnwrap(waitForSurfaceIDs(minimumCount: 1, timeout: 5.0).first)
        let hiddenSurfaceId = try XCTUnwrap(okUUID(from: socketCommand("new_surface --type=terminal")))
        XCTAssertTrue(
            waitForSurfaceID(workspaceId: secondaryWorkspaceId, surfaceId: hiddenSurfaceId, timeout: 5.0),
            "Expected the hidden surface to exist before reporting its directory"
        )

        XCTAssertTrue(
            reportSurfaceDirectoryAndWait(
                workspaceId: secondaryWorkspaceId,
                surfaceId: hiddenSurfaceId,
                directory: "/tmp/\(hiddenSurfaceToken)",
                timeout: 5.0
            ),
            "Expected hidden surface directory to be visible in surface.list before opening Cmd+P"
        )
        XCTAssertEqual(socketCommand("focus_surface \(initialSurfaceId)"), "OK")
        XCTAssertTrue(
            reportSurfaceDirectoryAndWait(
                workspaceId: secondaryWorkspaceId,
                surfaceId: initialSurfaceId,
                directory: "/tmp/\(visibleSurfaceToken)",
                timeout: 5.0
            ),
            "Expected visible surface directory to be visible in surface.list before opening Cmd+P"
        )
        XCTAssertEqual(socketCommand("select_workspace 0"), "OK")
        XCTAssertEqual(socketCommand("focus_window \(mainWindowId)"), "OK")

        try openCommandPalette(app: app, windowId: mainWindowId, query: hiddenSurfaceToken)
        let disabledSnapshot = try XCTUnwrap(
            waitForCommandPaletteSnapshot(windowId: mainWindowId, query: hiddenSurfaceToken, timeout: 5.0) { snapshot in
                self.commandPaletteResultRows(from: snapshot).isEmpty
            }
        )
        XCTAssertEqual(commandPaletteResultRows(from: disabledSnapshot).count, 0)
        dismissCommandPalette(app: app)

        try setDebugBoolSetting(key: "commandPalette.switcherSearchAllSurfaces", value: true)
        XCTAssertTrue(
            waitForStoredBoolSetting("commandPalette.switcherSearchAllSurfaces", value: true, timeout: 3.0),
            "Expected all-surfaces search default to be enabled before reopening Cmd+P"
        )

        XCTAssertEqual(socketCommand("focus_window \(mainWindowId)"), "OK")

        try openCommandPalette(app: app, windowId: mainWindowId, query: hiddenSurfaceToken)
        let enabledSnapshot = try XCTUnwrap(
            waitForCommandPaletteSnapshot(windowId: mainWindowId, query: hiddenSurfaceToken, timeout: 5.0) { snapshot in
                self.commandPaletteResultRows(from: snapshot).contains { row in
                    let commandId = row["command_id"] as? String ?? ""
                    let trailingLabel = row["trailing_label"] as? String ?? ""
                    return commandId.hasPrefix("switcher.surface.") && trailingLabel == "Terminal"
                }
            }
        )

        XCTAssertTrue(
            commandPaletteResultRows(from: enabledSnapshot).contains { row in
                let commandId = row["command_id"] as? String ?? ""
                let trailingLabel = row["trailing_label"] as? String ?? ""
                return commandId.hasPrefix("switcher.surface.") && trailingLabel == "Terminal"
            },
            "Expected Cmd+P to surface the hidden terminal when all-surfaces search is enabled. snapshot=\(enabledSnapshot)"
        )
    }

    func testMinimalModeToggleKeepsSettingsWindowFocused() throws {
        let app = XCUIApplication()
        let diagnosticsPath = "/tmp/cmux-ui-test-settings-focus-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: diagnosticsPath)
        configureSocketControlledLaunch(app, showSettingsWindow: true)
        app.launchEnvironment["CMUX_UI_TEST_DIAGNOSTICS_PATH"] = diagnosticsPath
        launchAndActivate(app)

        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 8.0) {
                app.windows.count >= 2
            },
            "Expected the main window and Settings window to be visible"
        )
        XCTAssertTrue(waitForSocketPong(timeout: 12.0), "Expected control dispatcher. \(socketReadinessDebug())")

        let targetMode = "minimal"

        try setDebugStringSetting(key: "workspacePresentationMode", value: targetMode)

        let diagnostics = waitForDiagnostics(
            at: diagnosticsPath,
            timeout: 3.0
        ) { data in
            data["keyWindowIdentifier"] == "cmux.settings" && data["settingsWindowIsKey"] == "1"
        }

        XCTAssertEqual(
            diagnostics?["keyWindowIdentifier"],
            "cmux.settings",
            "Expected the Settings window to remain key after toggling minimal mode. diagnostics=\(diagnostics ?? [:])"
        )
        XCTAssertEqual(
            diagnostics?["settingsWindowIsKey"],
            "1",
            "Expected the Settings window to report itself as key after toggling minimal mode. diagnostics=\(diagnostics ?? [:])"
        )
        XCTAssertTrue(
            diagnosticsRemainStable(
                at: diagnosticsPath,
                duration: 0.8
            ) { data in
                data["keyWindowIdentifier"] == "cmux.settings" && data["settingsWindowIsKey"] == "1"
            },
            "Expected the Settings window to stay key after toggling minimal mode. diagnostics=\(loadDiagnostics(at: diagnosticsPath) ?? [:])"
        )
    }

    func testMenuBarOnlyToggleKeepsSettingsWindowFocused() throws {
        let app = XCUIApplication()
        let diagnosticsPath = "/tmp/cmux-ui-test-menu-bar-only-focus-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: diagnosticsPath)
        resetMenuBarOnlyDefault()
        addTeardownBlock {
            app.terminate()
            self.resetMenuBarOnlyDefault()
            try? FileManager.default.removeItem(atPath: diagnosticsPath)
        }
        app.launchArguments += [
            "-menuBarOnly", "false",
            "-showMenuBarExtra", "true",
        ]
        configureSocketControlledLaunch(app, showSettingsWindow: true)
        app.launchEnvironment["CMUX_UI_TEST_DIAGNOSTICS_PATH"] = diagnosticsPath
        launchAndActivate(app)

        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 8.0) {
                app.windows.count >= 2
            },
            "Expected the main window and Settings window to be visible"
        )
        XCTAssertTrue(waitForSocketPong(timeout: 12.0), "Expected control dispatcher. \(socketReadinessDebug())")

        try setDebugBoolSetting(key: "menuBarOnly", value: true)

        let diagnostics = waitForDiagnostics(
            at: diagnosticsPath,
            timeout: 3.0
        ) { data in
            data["keyWindowIdentifier"] == "cmux.settings" && data["settingsWindowIsKey"] == "1"
        }

        XCTAssertEqual(
            diagnostics?["keyWindowIdentifier"],
            "cmux.settings",
            "Expected the Settings window to remain key after enabling menu-bar-only mode. diagnostics=\(diagnostics ?? [:])"
        )
        XCTAssertEqual(
            diagnostics?["settingsWindowIsKey"],
            "1",
            "Expected the Settings window to report itself as key after enabling menu-bar-only mode. diagnostics=\(diagnostics ?? [:])"
        )
        XCTAssertTrue(
            diagnosticsRemainStable(
                at: diagnosticsPath,
                duration: 0.8
            ) { data in
                data["keyWindowIdentifier"] == "cmux.settings" && data["settingsWindowIsKey"] == "1"
            },
            "Expected the Settings window to stay key after enabling menu-bar-only mode. diagnostics=\(loadDiagnostics(at: diagnosticsPath) ?? [:])"
        )

        try setDebugBoolSetting(key: "menuBarOnly", value: false)
    }

    func testCommandPaletteCanEnableAndDisableMinimalMode() throws {
        let app = XCUIApplication()
        configureSocketControlledLaunch(app)
        app.launchArguments += ["-workspacePresentationMode", "standard"]
        launchAndActivate(app)

        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 8.0) {
                app.windows.count >= 1
            },
            "Expected the main window to be visible"
        )
        XCTAssertTrue(waitForSocketPong(timeout: 12.0), "Expected control dispatcher. \(socketReadinessDebug())")

        let mainWindowId = try XCTUnwrap(
            socketCommand("current_window")?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        try setDebugStringSetting(key: "workspacePresentationMode", value: "standard")

        XCTAssertEqual(socketCommand("focus_window \(mainWindowId)"), "OK")
        try openCommandPaletteCommands(app: app, windowId: mainWindowId, query: "enable minimal")

        let enableSnapshot = try XCTUnwrap(
            waitForCommandPaletteSnapshot(windowId: mainWindowId, mode: "commands", query: "enable minimal", timeout: 5.0) { snapshot in
                self.commandPaletteResultRows(from: snapshot).first?["command_id"] as? String == "palette.enableMinimalMode"
            },
            "Expected the command palette to show Enable Minimal Mode while standard mode is active"
        )
        XCTAssertEqual(
            commandPaletteResultRows(from: enableSnapshot).first?["command_id"] as? String,
            "palette.enableMinimalMode",
            "Expected Enable Minimal Mode to be the selected command. snapshot=\(enableSnapshot)"
        )
        XCTAssertFalse(
            commandPaletteResultRows(from: enableSnapshot).contains { row in
                (row["command_id"] as? String) == "palette.disableMinimalMode"
            },
            "Expected Disable Minimal Mode to stay hidden while standard mode is active. snapshot=\(enableSnapshot)"
        )

        try submitCommandPalette(windowId: mainWindowId, commandId: "palette.enableMinimalMode")

        XCTAssertTrue(
            waitForStoredStringSetting("workspacePresentationMode", value: "minimal", timeout: 3.0),
            "Expected running the command palette action to enable minimal mode"
        )

        XCTAssertEqual(socketCommand("focus_window \(mainWindowId)"), "OK")
        try openCommandPaletteCommands(app: app, windowId: mainWindowId, query: "disable minimal")

        let disableSnapshot = try XCTUnwrap(
            waitForCommandPaletteSnapshot(windowId: mainWindowId, mode: "commands", query: "disable minimal", timeout: 5.0) { snapshot in
                self.commandPaletteResultRows(from: snapshot).first?["command_id"] as? String == "palette.disableMinimalMode"
            },
            "Expected the command palette to show Disable Minimal Mode while minimal mode is active"
        )
        XCTAssertEqual(
            commandPaletteResultRows(from: disableSnapshot).first?["command_id"] as? String,
            "palette.disableMinimalMode",
            "Expected Disable Minimal Mode to be the selected command. snapshot=\(disableSnapshot)"
        )
        XCTAssertFalse(
            commandPaletteResultRows(from: disableSnapshot).contains { row in
                (row["command_id"] as? String) == "palette.enableMinimalMode"
            },
            "Expected Enable Minimal Mode to stay hidden while minimal mode is active. snapshot=\(disableSnapshot)"
        )

        try submitCommandPalette(windowId: mainWindowId, commandId: "palette.disableMinimalMode")

        XCTAssertTrue(
            waitForStoredStringSetting("workspacePresentationMode", value: "standard", timeout: 3.0),
            "Expected running the command palette action to disable minimal mode"
        )
    }

    func testSwitcherEmptyStateDoesNotBlinkWhileRefiningNoMatchQuery() throws {
        let app = XCUIApplication()
        configureSocketControlledLaunch(app)
        launchAndActivate(app)

        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 8.0) {
                app.windows.count >= 1
            },
            "Expected the main window to be visible"
        )
        XCTAssertTrue(waitForSocketPong(timeout: 12.0), "Expected control dispatcher. \(socketReadinessDebug())")

        let mainWindowId = try XCTUnwrap(
            socketCommand("current_window")?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        try setDebugBoolSetting(key: "commandPalette.switcherSearchAllSurfaces", value: false)
        XCTAssertTrue(
            waitForStoredBoolSetting("commandPalette.switcherSearchAllSurfaces", value: false, timeout: 3.0),
            "Expected switcher search-all-surfaces default to be disabled for the workspace empty-state assertion"
        )
        try seedWorkspaceSwitcherCorpus(workspaceCount: 96)

        let seededWorkspaceTitlePrefix = "\(noMatchWorkspaceQuery)-"
        try openCommandPalette(app: app, windowId: mainWindowId, query: noMatchWorkspaceQuery)

        let seededSnapshot = try XCTUnwrap(
            waitForCommandPaletteSnapshot(windowId: mainWindowId, query: noMatchWorkspaceQuery, timeout: 5.0) { snapshot in
                self.commandPaletteResultRows(from: snapshot).contains { row in
                    ((row["title"] as? String) ?? "").hasPrefix(seededWorkspaceTitlePrefix)
                }
            },
            "Expected seeded workspace titles to be indexed before exercising the no-match path"
        )
        XCTAssertTrue(
            commandPaletteResultRows(from: seededSnapshot).contains { row in
                ((row["title"] as? String) ?? "").hasPrefix(seededWorkspaceTitlePrefix)
            },
            "Expected the seeded workspace corpus to be searchable before the no-match assertion. snapshot=\(seededSnapshot)"
        )

        try clearCommandPaletteSearchField(app: app, windowId: mainWindowId)
        try setCommandPaletteQuery(windowId: mainWindowId, mode: "switcher", query: String(repeating: "z", count: 8))

        let emptyLabel = app.staticTexts["No workspaces match your search."].firstMatch
        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 5.0) {
                guard emptyLabel.exists else { return false }
                guard let snapshot = commandPaletteSnapshot(windowId: mainWindowId) else { return false }
                return (snapshot["query"] as? String) == String(repeating: "z", count: 8)
                    && self.commandPaletteResultRows(from: snapshot).isEmpty
            },
            "Expected the switcher to reach a visible no-results state before refining the query"
        )

        let refinedQuery = String(repeating: "z", count: 9)
        try setCommandPaletteQuery(windowId: mainWindowId, mode: "switcher", query: refinedQuery)

        var refinedSnapshot: [String: Any]?
        var emptyLabelDisappearedWhileRefining = false
        let refinedQueryResolvedWhileKeepingEmptyStateVisible = sidebarHelpPollUntil(
            timeout: 5.0,
            pollInterval: 0.01
        ) {
            guard emptyLabel.exists else {
                emptyLabelDisappearedWhileRefining = true
                return false
            }
            guard let snapshot = commandPaletteSnapshot(windowId: mainWindowId) else { return false }
            guard (snapshot["query"] as? String) == refinedQuery else { return false }
            guard self.commandPaletteResultRows(from: snapshot).isEmpty else { return false }
            refinedSnapshot = snapshot
            return true
        }
        XCTAssertFalse(
            emptyLabelDisappearedWhileRefining,
            "Expected refining an already-empty switcher query to keep the empty-state label visible"
        )
        XCTAssertTrue(
            refinedQueryResolvedWhileKeepingEmptyStateVisible,
            "Expected the refined no-match query to resolve while keeping the empty-state label visible"
        )
        let resolvedRefinedSnapshot = try XCTUnwrap(refinedSnapshot)
        XCTAssertTrue(
            commandPaletteResultRows(from: resolvedRefinedSnapshot).isEmpty,
            "Expected the refined no-match query to stay empty. snapshot=\(resolvedRefinedSnapshot)"
        )
    }

    private func launchAndActivate(_ app: XCUIApplication) {
        app.launch()
        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 10.0) {
                guard app.state != .runningForeground else { return true }
                app.activate()
                return app.state == .runningForeground
            },
            "App did not reach runningForeground before UI interactions"
        )
    }

    private func commandPaletteRowValues(app: XCUIApplication, limit: Int) -> [String] {
        (0..<limit).compactMap { index in
            let row = app.descendants(matching: .any)
                .matching(identifier: "CommandPaletteResultRow.\(index)")
                .firstMatch
            guard row.exists else { return nil }
            return row.value as? String
        }
    }

    private func openCommandPalette(app: XCUIApplication, windowId: String, query: String) throws {
        let searchField = app.textFields["CommandPaletteSearchField"]
        app.typeKey("p", modifierFlags: [.command])
        XCTAssertTrue(searchField.waitForExistence(timeout: 5.0), "Expected command palette search field")
        try setCommandPaletteQuery(windowId: windowId, mode: "switcher", query: query)
    }

    private func openCommandPaletteCommands(app: XCUIApplication) {
        let searchField = app.textFields["CommandPaletteSearchField"]
        app.typeKey("p", modifierFlags: [.command, .shift])
        XCTAssertTrue(searchField.waitForExistence(timeout: 5.0), "Expected command palette search field")
    }

    private func openCommandPaletteCommands(app: XCUIApplication, windowId: String, query: String) throws {
        openCommandPaletteCommands(app: app)
        try setCommandPaletteQuery(windowId: windowId, mode: "commands", query: query)
    }

    private func dismissCommandPalette(app: XCUIApplication) {
        let searchField = app.textFields["CommandPaletteSearchField"]
        for _ in 0..<2 {
            app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
            if sidebarHelpPollUntil(timeout: 1.0, condition: { !searchField.exists }) {
                return
            }
        }
        XCTAssertFalse(searchField.exists, "Expected command palette to dismiss")
    }

    @discardableResult
    private func focusSettingsWindow(app: XCUIApplication) -> XCUIElement {
        let window = settingsWindow(app: app)
        if !window.exists {
            app.typeKey(",", modifierFlags: [.command])
        }
        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 6.0) { window.exists },
            "Expected Settings window to be visible"
        )
        if window.exists {
            clickElement(window)
        }
        return window
    }

    private func settingsWindow(app: XCUIApplication) -> XCUIElement {
        let titledWindow = app.windows["Settings"]
        if titledWindow.exists {
            return titledWindow
        }
        return app.windows["cmux.settings"]
    }

    private func ensureAppSettingsSection(app: XCUIApplication) -> XCUIElement {
        let window = focusSettingsWindow(app: app)
        let header = window.descendants(matching: .any)["SettingsAppSection"]
        if header.exists {
            return window
        }

        let appRow = window.cells.containing(.staticText, identifier: "App").firstMatch
        let appText = window.staticTexts["App"]
        if let target = firstExistingElement(candidates: [appRow, appText], timeout: 3.0) {
            clickElement(target)
        }
        XCTAssertTrue(
            sidebarHelpPollUntil(timeout: 5.0) { header.exists },
            "Expected Settings App section to render"
        )
        return window
    }

    private func requireSearchAllSurfacesToggle(app: XCUIApplication, root: XCUIElement) throws -> XCUIElement {
        let toggleId = "CommandPaletteSearchAllSurfacesToggle"
        return try requireSettingToggle(app: app, root: root, identifier: toggleId, title: "Search All Surfaces")
    }

    private func requireMinimalModeToggle(app: XCUIApplication, root: XCUIElement) throws -> XCUIElement {
        try requireSettingToggle(app: app, root: root, identifier: "SettingsMinimalModeToggle", title: "Minimal Mode")
    }

    private func requireMenuBarOnlyToggle(app: XCUIApplication, root: XCUIElement) throws -> XCUIElement {
        try requireSettingToggle(app: app, root: root, identifier: "SettingsMenuBarOnlyToggle", title: "Menu Bar Only")
    }

    private func requireSettingToggle(
        app: XCUIApplication,
        root: XCUIElement,
        identifier: String,
        title: String
    ) throws -> XCUIElement {
        if let element = findSettingToggle(app: app, root: root, identifier: identifier, title: title, timeout: 5.0) {
            return element
        }
        return try XCTUnwrap(
            nil as XCUIElement?,
            "Could not find setting toggle \(identifier)"
        )
    }

    private func findSettingToggle(
        app: XCUIApplication,
        root: XCUIElement,
        identifier: String,
        title: String,
        timeout: TimeInterval
    ) -> XCUIElement? {
        let scrollView = settingsContentScrollView(root: root)
        var firstVisible: XCUIElement?
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            let candidates = settingToggleCandidates(app: app, root: root, identifier: identifier, title: title)
            for candidate in candidates {
                let resolved = candidate.firstMatch
                guard resolved.exists else { continue }
                if resolved.isHittable {
                    return resolved
                }
                if firstVisible == nil {
                    firstVisible = resolved
                }
            }
            if scrollView.exists {
                if scrollView.isHittable {
                    scrollView.swipeUp()
                } else {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return firstVisible
    }

    private func settingToggleCandidates(
        app: XCUIApplication,
        root: XCUIElement,
        identifier: String,
        title: String
    ) -> [XCUIElement] {
        [
            root.switches[identifier],
            root.checkBoxes[identifier],
            root.buttons[identifier],
            root.descendants(matching: .any)[identifier],
            app.switches[identifier],
            app.checkBoxes[identifier],
            app.descendants(matching: .any)[identifier],
            root.switches[title],
            root.checkBoxes[title],
            root.buttons[title],
            root.otherElements[title],
            app.switches[title],
            app.checkBoxes[title],
            app.buttons[title],
            app.otherElements[title],
        ]
    }

    private func settingsContentScrollView(root: XCUIElement) -> XCUIElement {
        let appSectionScrollView = root.scrollViews
            .containing(.any, identifier: "SettingsAppSection")
            .firstMatch
        if appSectionScrollView.exists {
            return appSectionScrollView
        }
        return root.scrollViews.firstMatch
    }

    private func waitForSettingToggleState(
        app: XCUIApplication,
        root: XCUIElement,
        identifier: String,
        title: String,
        isOn: Bool,
        timeout: TimeInterval
    ) -> Bool {
        sidebarHelpPollUntil(timeout: timeout) {
            guard let element = findSettingToggle(
                app: app,
                root: root,
                identifier: identifier,
                title: title,
                timeout: 0.1
            ) else {
                return false
            }
            return settingStateMatches(identifier: identifier, element: element, isOn: isOn)
        }
    }

    private func setSettingToggle(
        app: XCUIApplication,
        root: XCUIElement,
        identifier: String,
        title: String,
        isOn: Bool,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var actionIndex = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            if waitForSettingToggleState(
                app: app,
                root: root,
                identifier: identifier,
                title: title,
                isOn: isOn,
                timeout: 0.2
            ) {
                return true
            }

            guard let element = findSettingToggle(
                app: app,
                root: root,
                identifier: identifier,
                title: title,
                timeout: 0.3
            ) else {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                continue
            }

            performSettingToggleAction(
                index: actionIndex,
                app: app,
                root: root,
                element: element,
                title: title
            )
            actionIndex += 1

            if waitForSettingToggleState(
                app: app,
                root: root,
                identifier: identifier,
                title: title,
                isOn: isOn,
                timeout: min(1.5, max(0.1, deadline - ProcessInfo.processInfo.systemUptime))
            ) {
                return true
            }
        }

        return waitForSettingToggleState(
            app: app,
            root: root,
            identifier: identifier,
            title: title,
            isOn: isOn,
            timeout: 0.2
        )
    }

    private func performSettingToggleAction(
        index: Int,
        app: XCUIApplication,
        root: XCUIElement,
        element: XCUIElement,
        title: String
    ) {
        switch index % 4 {
        case 0:
            clickElement(element)
        case 1:
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.5)).click()
        case 2:
            if element.exists {
                clickElement(element)
            }
            app.typeKey(XCUIKeyboardKey.space.rawValue, modifierFlags: [])
        default:
            let label = root.staticTexts[title].firstMatch
            if label.exists {
                clickElement(label)
            } else {
                clickElement(element)
            }
        }
    }

    private func settingIsOn(identifier: String, element: XCUIElement) -> Bool {
        if let storedState = storedSettingState(identifier: identifier) {
            return storedState
        }
        return toggleIsOn(element)
    }

    private func settingStateMatches(identifier: String, element: XCUIElement, isOn: Bool) -> Bool {
        if let storedState = storedSettingState(identifier: identifier), storedState == isOn {
            return true
        }
        if let state = toggleState(element), state == isOn {
            return true
        }
        return false
    }

    private func storedSettingState(identifier: String) -> Bool? {
        switch identifier {
        case "CommandPaletteSearchAllSurfacesToggle":
            return readDefaultsBool("commandPalette.switcherSearchAllSurfaces")
        case "SettingsMenuBarOnlyToggle":
            return readDefaultsBool("menuBarOnly")
        case "SettingsMinimalModeToggle":
            let raw = readDefaultsValue("workspacePresentationMode")
            if raw == "standard" {
                return false
            }
            if raw == "minimal" {
                return true
            }
            return nil
        default:
            return nil
        }
    }

    private func readDefaultsBool(_ key: String) -> Bool? {
        if let value = readDebugSettingValue(key) as? Bool {
            return value
        }
        guard let raw = readDefaultsValue(key) else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes":
            return true
        case "0", "false", "no":
            return false
        default:
            return nil
        }
    }

    private func waitForStoredBoolSetting(_ key: String, value: Bool, timeout: TimeInterval) -> Bool {
        sidebarHelpPollUntil(timeout: timeout) {
            readDefaultsBool(key) == value
        }
    }

    private func waitForStoredStringSetting(_ key: String, value: String, timeout: TimeInterval) -> Bool {
        sidebarHelpPollUntil(timeout: timeout) {
            readDefaultsValue(key) == value
        }
    }

    private func setDebugBoolSetting(key: String, value: Bool) throws {
        let result = try setDebugSetting(key: key, value: value)
        XCTAssertEqual(result["value"] as? Bool, value, "Expected debug.settings.set to return the stored bool value")
    }

    private func setDebugStringSetting(key: String, value: String) throws {
        let result = try setDebugSetting(key: key, value: value)
        XCTAssertEqual(result["value"] as? String, value, "Expected debug.settings.set to return the stored string value")
    }

    private func setDebugSetting(key: String, value: Any) throws -> [String: Any] {
        let response = try XCTUnwrap(
            socketJSON(
                method: "debug.settings.set",
                params: [
                    "key": key,
                    "value": value,
                ]
            ),
            "Expected a response from debug.settings.set"
        )
        XCTAssertEqual(response["ok"] as? Bool, true, "Expected debug.settings.set to succeed. response=\(response)")
        return try XCTUnwrap(response["result"] as? [String: Any], "Expected debug.settings.set result payload")
    }

    private func readDefaultsValue(_ key: String) -> String? {
        guard let value = readDebugSettingValue(key) else { return nil }
        if let stringValue = value as? String {
            return stringValue
        }
        if let boolValue = value as? Bool {
            return boolValue ? "true" : "false"
        }
        return nil
    }

    private func readDebugSettingValue(_ key: String) -> Any? {
        guard let response = socketJSON(
            method: "debug.settings.get",
            params: ["key": key]
        ), response["ok"] as? Bool == true,
            let result = response["result"] as? [String: Any] else {
            return nil
        }
        return result["value"]
    }

    private func toggleIsOn(_ element: XCUIElement) -> Bool {
        toggleState(element) ?? false
    }

    private func toggleState(_ element: XCUIElement) -> Bool? {
        let value = String(describing: element.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value == "1" || value == "true" || value == "on" {
            return true
        }
        if value == "0" || value == "false" || value == "off" {
            return false
        }
        return nil
    }

    private func firstExistingElement(
        candidates: [XCUIElement],
        timeout: TimeInterval
    ) -> XCUIElement? {
        var match: XCUIElement?
        let found = sidebarHelpPollUntil(timeout: timeout) {
            for candidate in candidates {
                let resolved = candidate.firstMatch
                guard resolved.exists else { continue }
                match = resolved
                return true
            }
            return false
        }
        return found ? match : nil
    }

    private func clickElement(_ element: XCUIElement) {
        let target = element.firstMatch
        if target.isHittable {
            target.click()
        } else {
            target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        }
    }

    private func waitForSocketPong(timeout: TimeInterval) -> Bool {
        sidebarHelpPollUntil(timeout: timeout) {
            socketCommand("ping") == "PONG"
        }
    }

    private func socketReadinessDebug() -> String {
        let diagnostics = loadDiagnostics(at: diagnosticsPath) ?? [:]
        let socketExists = FileManager.default.fileExists(atPath: socketPath)
        let directPing = ControlSocketClient(path: socketPath, responseTimeout: 0.5).sendLine("ping") ?? "<nil>"
        let netcatPing = socketCommandViaNetcat("ping", responseTimeout: 1.0) ?? "<nil>"
        let bridgePing = socketBridgeCommand("ping", responseTimeout: 1.0) ?? "<nil>"
        return "socketExists=\(socketExists) directPing=\(directPing) netcatPing=\(netcatPing) bridgePing=\(bridgePing) diagnostics=\(diagnostics)"
    }

    private func waitForSurfaceIDs(minimumCount: Int, timeout: TimeInterval) -> [String] {
        var ids: [String] = []
        let found = sidebarHelpPollUntil(timeout: timeout) {
            ids = surfaceIDs()
            return ids.count >= minimumCount
        }
        return found ? ids : surfaceIDs()
    }

    private func surfaceIDs() -> [String] {
        guard let response = socketCommand("list_surfaces"), !response.isEmpty, !response.hasPrefix("No surfaces") else {
            return []
        }
        return response
            .split(separator: "\n")
            .compactMap { line in
                guard let range = line.range(of: ": ") else { return nil }
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
    }

    private func okUUID(from response: String?) -> String? {
        guard let response, response.hasPrefix("OK ") else { return nil }
        let value = String(response.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        return UUID(uuidString: value) != nil ? value : nil
    }

    private func debugTypeText(_ text: String) throws {
        let response = try XCTUnwrap(
            socketJSON(
                method: "debug.type",
                params: ["text": text]
            ),
            "Expected a response from debug.type"
        )
        XCTAssertEqual(response["ok"] as? Bool, true, "Expected debug.type to succeed. response=\(response)")
    }

    private func setCommandPaletteQuery(windowId: String, mode: String, query: String) throws {
        let response = try XCTUnwrap(
            socketJSON(
                method: "debug.command_palette.query.set",
                params: [
                    "window_id": windowId,
                    "mode": mode,
                    "query": query,
                ]
            ),
            "Expected a response from debug.command_palette.query.set"
        )
        XCTAssertEqual(
            response["ok"] as? Bool,
            true,
            "Expected debug.command_palette.query.set to succeed. response=\(response)"
        )
    }

    private func submitCommandPalette(windowId: String, commandId: String? = nil) throws {
        var params: [String: Any] = ["window_id": windowId]
        if let commandId {
            params["command_id"] = commandId
        }
        let response = try XCTUnwrap(
            socketJSON(
                method: "debug.command_palette.submit",
                params: params
            ),
            "Expected a response from debug.command_palette.submit"
        )
        XCTAssertEqual(
            response["ok"] as? Bool,
            true,
            "Expected debug.command_palette.submit to succeed. response=\(response)"
        )
        guard let commandId else { return }
        let result = try XCTUnwrap(
            response["result"] as? [String: Any],
            "Expected debug.command_palette.submit result payload. response=\(response)"
        )
        XCTAssertEqual(
            result["command_handled"] as? Bool,
            true,
            "Expected command palette submit to run \(commandId). response=\(response)"
        )
    }

    private func waitForSurfaceID(workspaceId: String, surfaceId: String, timeout: TimeInterval) -> Bool {
        sidebarHelpPollUntil(timeout: timeout) {
            guard let response = socketJSON(method: "surface.list", params: ["workspace_id": workspaceId]),
                  response["ok"] as? Bool == true,
                  let result = response["result"] as? [String: Any],
                  let surfaces = result["surfaces"] as? [[String: Any]] else {
                return false
            }
            return surfaces.contains { surface in
                surface["id"] as? String == surfaceId
            }
        }
    }

    private func waitForSurfaceDirectory(
        workspaceId: String,
        surfaceId: String,
        directory: String,
        timeout: TimeInterval
    ) -> Bool {
        sidebarHelpPollUntil(timeout: timeout) {
            self.surfaceDirectoryMatches(workspaceId: workspaceId, surfaceId: surfaceId, directory: directory)
        }
    }

    private func reportSurfaceDirectoryAndWait(
        workspaceId: String,
        surfaceId: String,
        directory: String,
        timeout: TimeInterval
    ) -> Bool {
        sidebarHelpPollUntil(timeout: timeout) {
            guard self.socketCommand("report_pwd \(directory) --tab=\(workspaceId) --panel=\(surfaceId)") == "OK" else {
                return false
            }
            return self.surfaceDirectoryMatches(workspaceId: workspaceId, surfaceId: surfaceId, directory: directory)
        }
    }

    private func surfaceDirectoryMatches(workspaceId: String, surfaceId: String, directory: String) -> Bool {
            guard let response = socketJSON(method: "surface.list", params: ["workspace_id": workspaceId]),
                  response["ok"] as? Bool == true,
                  let result = response["result"] as? [String: Any],
                  let surfaces = result["surfaces"] as? [[String: Any]] else {
                return false
            }
            return surfaces.contains { surface in
                surface["id"] as? String == surfaceId
                    && surface["current_directory"] as? String == directory
            }
    }

    private func clearCommandPaletteSearchField(app: XCUIApplication, windowId: String) throws {
        try setCommandPaletteQuery(windowId: windowId, mode: "switcher", query: "")
        let clearedSnapshot = try XCTUnwrap(
            waitForCommandPaletteSnapshot(windowId: windowId, query: "", timeout: 5.0),
            "Expected the command palette query to clear"
        )
        XCTAssertEqual(
            clearedSnapshot["query"] as? String,
            "",
            "Expected the command palette query to clear"
        )
    }

    private func seedWorkspaceSwitcherCorpus(workspaceCount: Int) throws {
        guard workspaceCount > 1 else { return }

        for index in 1..<workspaceCount {
            let workspaceId = try XCTUnwrap(
                okUUID(from: socketCommand("new_workspace")),
                "Expected new_workspace to return a workspace ID"
            )
            let title = seededWorkspaceTitle(index: index)
            let response = try XCTUnwrap(
                socketJSON(
                    method: "workspace.rename",
                    params: [
                        "workspace_id": workspaceId,
                        "title": title,
                    ]
                ),
                "Expected a response from workspace.rename"
            )
            XCTAssertEqual(
                response["ok"] as? Bool,
                true,
                "Expected workspace.rename to succeed. response=\(response)"
            )
        }

        XCTAssertEqual(socketCommand("select_workspace 0"), "OK")
    }

    private func seededWorkspaceTitle(index: Int) -> String {
        "\(noMatchWorkspaceQuery)-\(index)-" + String(repeating: "workspace-", count: 8)
    }

    private func socketCommand(_ command: String) -> String? {
        if let response = socketBridgeCommand(command, responseTimeout: 2.0) {
            return response
        }
        if let response = ControlSocketClient(path: socketPath, responseTimeout: 2.0).sendLine(command) {
            return response
        }
        return socketCommandViaNetcat(command, responseTimeout: 2.0)
    }

    private func socketBridgeCommand(_ command: String, responseTimeout: TimeInterval) -> String? {
        if let response = socketPasteboardBridgeCommand(command, responseTimeout: responseTimeout) {
            return response
        }
        return socketFileBridgeCommand(command, responseTimeout: responseTimeout)
    }

    private func socketPasteboardBridgeCommand(_ command: String, responseTimeout: TimeInterval) -> String? {
        guard !socketBridgePath.isEmpty else { return nil }
        let requestId = UUID().uuidString
        let payload: [String: Any] = [
            "id": requestId,
            "line": command,
            "bridgePath": socketBridgePath,
            "completed": false,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let raw = String(data: data, encoding: .utf8) else {
            return nil
        }

        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([socketBridgePasteboardRequestType], owner: nil)
        pasteboard.setString(raw, forType: socketBridgePasteboardRequestType)

        let deadline = ProcessInfo.processInfo.systemUptime + responseTimeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let response = socketPasteboardBridgeResponse(requestId: requestId) {
                return response
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return nil
    }

    private func socketPasteboardBridgeResponse(requestId: String) -> String? {
        guard let raw = NSPasteboard.general.string(forType: socketBridgePasteboardResponseType),
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["bridgePath"] as? String == socketBridgePath,
              object["id"] as? String == requestId,
              object["completed"] as? Bool == true else {
            return nil
        }
        return object["response"] as? String
    }

    private func socketFileBridgeCommand(_ command: String, responseTimeout: TimeInterval) -> String? {
        guard !socketBridgePath.isEmpty else { return nil }
        let requestId = UUID().uuidString
        let payload: [String: Any] = [
            "id": requestId,
            "line": command,
            "completed": false,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return nil
        }
        try? FileManager.default.removeItem(atPath: socketBridgeResponsePath)
        try? data.write(to: URL(fileURLWithPath: socketBridgeRequestPath), options: .atomic)

        let deadline = ProcessInfo.processInfo.systemUptime + responseTimeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let response = socketBridgeResponse(requestId: requestId) {
                return response
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return nil
    }

    private func socketBridgeResponse(requestId: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: socketBridgeResponsePath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["id"] as? String == requestId,
              object["completed"] as? Bool == true else {
            return nil
        }
        return object["response"] as? String
    }

    private var socketBridgeRequestPath: String {
        socketBridgePath + ".request"
    }

    private var socketBridgeResponsePath: String {
        socketBridgePath + ".response"
    }

    private func removeSocketBridgeFiles() {
        guard !socketBridgePath.isEmpty else { return }
        try? FileManager.default.removeItem(atPath: socketBridgePath)
        try? FileManager.default.removeItem(atPath: socketBridgeRequestPath)
        try? FileManager.default.removeItem(atPath: socketBridgeResponsePath)
    }

    private func socketCommandViaNetcat(_ command: String, responseTimeout: TimeInterval) -> String? {
        let nc = "/usr/bin/nc"
        guard FileManager.default.isExecutableFile(atPath: nc) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let timeoutSeconds = max(1, Int(ceil(responseTimeout)))
        process.arguments = [
            "-lc",
            "printf '%s\\n' \(shellSingleQuote(command)) | \(nc) -U \(shellSingleQuote(socketPath)) -w \(timeoutSeconds) 2>/dev/null"
        ]

        let stdout = Pipe()
        process.standardOutput = stdout

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        if let first = output.split(separator: "\n", maxSplits: 1).first {
            return String(first).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func shellSingleQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func resetMenuBarOnlyDefault() {
        runDefaultsCommand(["delete", debugDefaultsDomain, "workspacePresentationMode"])
        runDefaultsCommand(["delete", debugDefaultsDomain, "commandPalette.switcherSearchAllSurfaces"])
        runDefaultsCommand(["write", debugDefaultsDomain, "menuBarOnly", "-bool", "false"])
    }

    private func runDefaultsCommand(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
        }
    }

    private func commandPaletteResultRows(from snapshot: [String: Any]) -> [[String: Any]] {
        snapshot["results"] as? [[String: Any]] ?? []
    }

    private func waitForCommandPaletteSnapshot(
        windowId: String,
        mode: String = "switcher",
        query: String,
        timeout: TimeInterval,
        predicate: (([String: Any]) -> Bool)? = nil
    ) -> [String: Any]? {
        var latest: [String: Any]?
        let matched = sidebarHelpPollUntil(timeout: timeout) {
            guard let snapshot = commandPaletteSnapshot(windowId: windowId) else { return false }
            latest = snapshot
            guard (snapshot["visible"] as? Bool) == true else { return false }
            guard (snapshot["mode"] as? String) == mode else { return false }
            guard (snapshot["query"] as? String) == query else { return false }
            return predicate?(snapshot) ?? true
        }
        return matched ? latest : nil
    }

    private func commandPaletteSnapshot(windowId: String) -> [String: Any]? {
        let envelope = socketJSON(
            method: "debug.command_palette.results",
            params: [
                "window_id": windowId,
                "limit": 20,
            ]
        )
        guard let ok = envelope?["ok"] as? Bool, ok else { return nil }
        return envelope?["result"] as? [String: Any]
    }

    private func socketJSON(method: String, params: [String: Any]) -> [String: Any]? {
        let request: [String: Any] = [
            "id": UUID().uuidString,
            "method": method,
            "params": params,
        ]
        if let line = socketJSONLine(request),
           let raw = socketBridgeCommand(line, responseTimeout: 2.0),
           let response = parseSocketJSONResponse(raw) {
            return response
        }
        if let response = ControlSocketClient(path: socketPath, responseTimeout: 2.0).sendJSON(request) {
            return response
        }
        guard let line = socketJSONLine(request),
              let raw = socketCommandViaNetcat(line, responseTimeout: 2.0),
              let response = parseSocketJSONResponse(raw) else {
            return nil
        }
        return response
    }

    private func socketJSONLine(_ request: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(request),
              let data = try? JSONSerialization.data(withJSONObject: request),
              let line = String(data: data, encoding: .utf8) else {
            return nil
        }
        return line
    }

    private func parseSocketJSONResponse(_ raw: String) -> [String: Any]? {
        guard let responseData = raw.data(using: .utf8),
              let response = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            return nil
        }
        return response
    }

    private func waitForDiagnostics(
        at path: String,
        timeout: TimeInterval,
        condition: ([String: String]) -> Bool
    ) -> [String: String]? {
        let deadline = Date().addingTimeInterval(timeout)
        var last: [String: String]?

        while Date() < deadline {
            if let data = loadDiagnostics(at: path) {
                last = data
                if condition(data) {
                    return data
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        return last
    }

    private func diagnosticsRemainStable(
        at path: String,
        duration: TimeInterval,
        condition: ([String: String]) -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            guard let data = loadDiagnostics(at: path), condition(data) else {
                return false
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return true
    }

    private func loadDiagnostics(at path: String) -> [String: String]? {
        guard let raw = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: raw) as? [String: String] else {
            return nil
        }
        return object
    }

    private final class ControlSocketClient {
        private let path: String
        private let responseTimeout: TimeInterval

        init(path: String, responseTimeout: TimeInterval) {
            self.path = path
            self.responseTimeout = responseTimeout
        }

        func sendJSON(_ object: [String: Any]) -> [String: Any]? {
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object),
                  let line = String(data: data, encoding: .utf8),
                  let response = sendLine(line),
                  let responseData = response.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                return nil
            }
            return parsed
        }

        func sendLine(_ line: String) -> String? {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }

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

            var addr = sockaddr_un()
            memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
            addr.sun_family = sa_family_t(AF_UNIX)

            let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
            let bytes = Array(path.utf8CString)
            guard bytes.count <= maxLen else { return nil }
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                let raw = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
                memset(raw, 0, maxLen)
                for index in 0..<bytes.count {
                    raw[index] = bytes[index]
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
            let wrote: Bool = payload.withCString { cString in
                var remaining = strlen(cString)
                var pointer = UnsafeRawPointer(cString)
                while remaining > 0 {
                    let written = write(fd, pointer, remaining)
                    if written <= 0 { return false }
                    remaining -= written
                    pointer = pointer.advanced(by: written)
                }
                return true
            }
            guard wrote else { return nil }

            let deadline = Date().addingTimeInterval(responseTimeout)
            var buffer = [UInt8](repeating: 0, count: 4096)
            var accumulator = ""
            while Date() < deadline {
                var pollDescriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pollDescriptor, 1, 100)
                if ready < 0 {
                    return nil
                }
                if ready == 0 {
                    continue
                }
                let count = read(fd, &buffer, buffer.count)
                if count <= 0 { break }
                if let chunk = String(bytes: buffer[0..<count], encoding: .utf8) {
                    accumulator.append(chunk)
                    if let newline = accumulator.firstIndex(of: "\n") {
                        return String(accumulator[..<newline])
                    }
                }
            }

            return accumulator.isEmpty ? nil : accumulator.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
