import XCTest

final class CmuxHomeWorkspaceCommandStartupUITests: XCTestCase {
    private var dataPath = ""
    private var originalConfigData: Data?
    private var configURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        dataPath = "/tmp/cmux-ui-test-workspace-command-startup-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: dataPath)
        configURL = Self.globalConfigURL()
        originalConfigData = try? Data(contentsOf: configURL)
        try writeCmuxHomeCommandConfig()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dataPath)
        if let originalConfigData {
            try? FileManager.default.createDirectory(
                at: configURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? originalConfigData.write(to: configURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: configURL)
        }
        try super.tearDownWithError()
    }

    func testCmuxHomeCommandPaletteReturnStartsTerminalImmediately() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-menuBarOnly", "false"]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_DISABLE_NOTIFICATION_AUTHORIZATION_PROMPT"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_WORKSPACE_COMMAND_STARTUP_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_WORKSPACE_COMMAND_STARTUP_PATH"] = dataPath
        launchAndActivate(app)
        addTeardownBlock { app.terminate() }

        XCTAssertTrue(
            pollUntil(timeout: 8.0) { app.windows.count >= 1 },
            "Expected the main window to be visible"
        )
        dismissUserNotificationCenterDialogs()
        app.activate()

        app.typeKey("p", modifierFlags: [.command, .shift])
        let searchField = app.textFields["CommandPaletteSearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5.0), "Expected command palette search field")
        dismissUserNotificationCenterDialogs()
        app.activate()
        searchField.click()
        dismissUserNotificationCenterDialogs()
        app.activate()
        searchField.click()
        searchField.typeText("cmux-home")

        let firstRow = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier BEGINSWITH %@",
                "CommandPaletteResultRow."
            ))
            .firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5.0), "Expected command palette results for cmux-home")

        searchField.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(
            pollUntil(timeout: 2.0) { !searchField.exists },
            "Expected command palette to dismiss after pressing Return"
        )

        var latest: [String: String] = [:]
        XCTAssertTrue(
            pollUntil(timeout: 8.0) {
                latest = self.loadData()
                guard latest["selectedWorkspaceTitle"] == "cmux-home",
                      latest["focusedPanelKind"] == "terminal",
                      let attempts = Int(latest["selectedTerminalSurfaceCreateAttempts"] ?? "") else {
                    return false
                }
                return attempts > 0
            },
            "Expected cmux-home Return to start the selected terminal immediately without clicking the workspace. latest=\(latest)"
        )
    }

    private func writeCmuxHomeCommandConfig() throws {
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let config = """
        {
          "commands": [
            {
              "name": "cmux-home",
              "workspace": {
                "name": "cmux-home"
              }
            }
          ]
        }
        """
        try config.write(to: configURL, atomically: true, encoding: .utf8)
    }

    private func launchAndActivate(_ app: XCUIApplication) {
        let launchOptions = XCTExpectedFailure.Options()
        launchOptions.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: launchOptions) {
            app.launch()
        }

        if app.state == .runningForeground { return }

        var reachedForeground = false
        let activateOptions = XCTExpectedFailure.Options()
        activateOptions.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: activateOptions) {
            reachedForeground = pollUntil(timeout: 4.0) {
                if app.state != .runningForeground {
                    app.activate()
                }
                return app.state == .runningForeground
            }
            XCTAssertTrue(reachedForeground, "App did not reach runningForeground before UI interactions")
        }
        if reachedForeground || app.state == .runningBackground {
            return
        }
        XCTFail("App failed to start. state=\(app.state.rawValue)")
    }

    private func loadData() -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: dataPath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }

    private func dismissUserNotificationCenterDialogs() {
        let notificationCenter = XCUIApplication(bundleIdentifier: "com.apple.UserNotificationCenter")
        for _ in 0..<3 {
            let dialog = notificationCenter.dialogs.firstMatch
            guard dialog.waitForExistence(timeout: 0.2) else { return }

            if clickFirstExistingButton(
                in: dialog,
                identifiers: ["Close", "Dismiss", "action-button-3", "action-button-1"]
            ) {
                _ = pollUntil(timeout: 1.0) { !dialog.exists }
                continue
            }

            notificationCenter.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
            _ = pollUntil(timeout: 1.0) { !dialog.exists }
        }
    }

    private func clickFirstExistingButton(in element: XCUIElement, identifiers: [String]) -> Bool {
        for identifier in identifiers {
            let button = element.buttons[identifier]
            if button.exists {
                button.click()
                return true
            }
        }
        return false
    }

    private func pollUntil(
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

    private static func globalConfigURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cmux/cmux.json", isDirectory: false)
    }
}
