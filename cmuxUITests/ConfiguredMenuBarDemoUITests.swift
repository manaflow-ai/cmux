import XCTest

private func configuredMenuBarPollUntil(
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

private func configuredMenuBarResetMenuBarOnlyDefault() {
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

private let configuredMenuBarLaunchArguments = [
    "-AppleLanguages", "(en)",
    "-AppleLocale", "en_US",
    "-ApplePersistenceIgnoreState", "YES",
    "-NSQuitAlwaysKeepsWindows", "NO",
    "-menuBarOnly", "false",
]

final class ConfiguredMenuBarDemoUITests: XCTestCase {
    private var app: XCUIApplication?
    private var configURL: URL?
    private var originalConfig: Data?

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        configuredMenuBarResetMenuBarOnlyDefault()
        try writeConfiguredMenuBarDemoConfig()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        restoreOriginalConfig()
        configuredMenuBarResetMenuBarOnlyDefault()
        try super.tearDownWithError()
    }

    func testConfiguredToolsMenuOpensForDemoRecording() throws {
        let app = XCUIApplication()
        self.app = app
        app.launchArguments += configuredMenuBarLaunchArguments
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        launchAndActivate(app)

        XCTAssertTrue(
            configuredMenuBarPollUntil(timeout: 8.0) {
                app.windows.count >= 1
            },
            "Expected a cmux window before opening the configured menu"
        )

        let toolsMenu = requireElement(
            candidates: [
                app.menuBars.menuBarItems["Tools"],
                app.menuBars.menuItems["Tools"],
            ],
            timeout: 4.0,
            description: "configured Tools menu"
        )
        toolsMenu.click()

        XCTAssertTrue(app.menuItems["Run Static Demo Command"].waitForExistence(timeout: 3.0))
        XCTAssertTrue(app.menuItems["Nested Commands"].waitForExistence(timeout: 3.0))
        XCTAssertTrue(app.menuItems["Live Bash Items"].waitForExistence(timeout: 3.0))

        RunLoop.current.run(until: Date().addingTimeInterval(3.0))
    }

    private func writeConfiguredMenuBarDemoConfig() throws {
        let fileManager = FileManager.default
        let configDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cmux", isDirectory: true)
        try fileManager.createDirectory(at: configDirectory, withIntermediateDirectories: true)

        let configURL = configDirectory.appendingPathComponent("cmux.json", isDirectory: false)
        self.configURL = configURL
        originalConfig = try? Data(contentsOf: configURL)

        let config = #"""
        {
          "ui": {
            "menuBar": [
              {
                "id": "tools",
                "title": "Tools",
                "items": [
                  {
                    "title": "Run Static Demo Command",
                    "command": "printf 'static menu action from cmux.json\\\\n'",
                    "target": "currentTerminal"
                  },
                  { "type": "separator" },
                  {
                    "title": "Nested Commands",
                    "items": [
                      {
                        "title": "Nested Echo",
                        "command": "printf 'nested menu action\\\\n'",
                        "target": "currentTerminal"
                      }
                    ]
                  },
                  {
                    "title": "Live Bash Items",
                    "source": {
                      "type": "command",
                      "command": "printf '[{\\"title\\":\\"Generated at demo time\\",\\"command\\":\\"date\\",\\"target\\":\\"currentTerminal\\"}]\\\\n'",
                      "refresh": "manual",
                      "timeoutSeconds": 3
                    }
                  }
                ]
              }
            ]
          }
        }
        """#
        try config.write(to: configURL, atomically: true, encoding: .utf8)
    }

    private func restoreOriginalConfig() {
        guard let configURL else {
            return
        }
        if let originalConfig {
            try? originalConfig.write(to: configURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: configURL)
        }
    }

    private func requireElement(
        candidates: [XCUIElement],
        timeout: TimeInterval,
        description: String
    ) -> XCUIElement {
        var match: XCUIElement?
        let found = configuredMenuBarPollUntil(timeout: timeout) {
            for candidate in candidates where candidate.exists {
                match = candidate
                return true
            }
            return false
        }
        XCTAssertTrue(found, "Expected \(description) to exist")
        return match ?? candidates[0]
    }

    private func launchAndActivate(_ app: XCUIApplication, activateTimeout: TimeInterval = 2.0) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("Headless CI may launch the app without foreground activation", options: options) {
            app.launch()
        }

        XCTAssertTrue(
            configuredMenuBarPollUntil(timeout: 10.0) {
                app.state == .runningForeground || app.state == .runningBackground
            },
            "App failed to launch. state=\(app.state.rawValue)"
        )

        if app.state != .runningForeground {
            let activated = configuredMenuBarPollUntil(timeout: activateTimeout) {
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
            configuredMenuBarPollUntil(timeout: 6.0) {
                app.state == .runningForeground
            },
            "App did not become foreground before menu interactions. state=\(app.state.rawValue)"
        )
    }
}
