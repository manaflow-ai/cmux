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

private let configuredMenuBarDemoDirectoryName = "cmux-configured-menubar-demo"
private let configuredMenuBarDemoBeforeScreenshotName = "cmux-configured-menubar-demo-before.png"
private let configuredMenuBarDemoOpenScreenshotName = "cmux-configured-menubar-demo-open.png"

final class ConfiguredMenuBarDemoUITests: XCTestCase {
    private var app: XCUIApplication?
    private var configURL: URL?
    private var beforeScreenshotURL: URL?
    private var openScreenshotURL: URL?

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
        app.launchEnvironment["CMUX_UI_TEST_CMUX_CONFIG_PATH"] = try XCTUnwrap(configURL?.path)
        launchAndActivate(app)

        XCTAssertTrue(
            configuredMenuBarPollUntil(timeout: 8.0) {
                app.windows.count >= 1
            },
            "Expected a cmux window before opening the configured menu"
        )
        try saveDemoScreenshot(url: XCTUnwrap(beforeScreenshotURL))

        XCTAssertTrue(
            openConfiguredToolsMenu(in: app, timeout: 12.0),
            configuredToolsMenuFailureDetails(app: app)
        )

        XCTAssertTrue(app.menuItems["Run Static Demo Command"].waitForExistence(timeout: 3.0))
        XCTAssertTrue(app.menuItems["Nested Commands"].waitForExistence(timeout: 3.0))
        XCTAssertTrue(app.menuItems["Live Bash Items"].waitForExistence(timeout: 3.0))
        try saveDemoScreenshot(url: XCTUnwrap(openScreenshotURL))

        RunLoop.current.run(until: Date().addingTimeInterval(3.0))
    }

    private func writeConfiguredMenuBarDemoConfig() throws {
        let fileManager = FileManager.default
        let configDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("\(configuredMenuBarDemoDirectoryName)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: configDirectory, withIntermediateDirectories: true)

        let configURL = configDirectory.appendingPathComponent("cmux.json", isDirectory: false)
        self.configURL = configURL
        beforeScreenshotURL = configDirectory.appendingPathComponent(configuredMenuBarDemoBeforeScreenshotName, isDirectory: false)
        openScreenshotURL = configDirectory.appendingPathComponent(configuredMenuBarDemoOpenScreenshotName, isDirectory: false)

        let config = #"""
        {
          "ui": {
            "menuBar": [
              {
                "id": "tools",
                "title": "Tools",
                "before": "notifications",
                "items": [
                  {
                    "title": "Run Static Demo Command",
                    "command": "printf 'static menu action from cmux.json\\\\n'",
                    "target": "currentTerminal",
                    "shortcut": "cmd+shift+y"
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
                      "command": "printf '[]'",
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

    private func openConfiguredToolsMenu(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let labeledCandidates = [
            app.menuBars.menuBarItems["Tools"],
            app.menuBars.menuItems["Tools"],
        ]
        for candidate in labeledCandidates where candidate.waitForExistence(timeout: 0.5) {
            candidate.click()
            if app.menuItems["Run Static Demo Command"].waitForExistence(timeout: 1.0) {
                return true
            }
        }

        let start = ProcessInfo.processInfo.systemUptime
        while (ProcessInfo.processInfo.systemUptime - start) < timeout {
            let items = app.menuBars.menuBarItems.allElementsBoundByIndex
            if items.isEmpty {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                continue
            }
            for item in items where item.exists {
                if item.isHittable {
                    item.click()
                } else {
                    item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
                }
                if app.menuItems["Run Static Demo Command"].waitForExistence(timeout: 0.4) {
                    return true
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    private func configuredToolsMenuFailureDetails(app: XCUIApplication) -> String {
        let items = app.menuBars.menuBarItems.allElementsBoundByIndex
        let titles = items.map(\.label).joined(separator: ", ")
        let frames = items.map { NSStringFromRect($0.frame) }.joined(separator: ", ")
        return "Expected configured Tools menu to open. Visible menu count: \(items.count). Titles: \(titles). Frames: \(frames)"
    }

    private func saveDemoScreenshot(url: URL) throws {
        do {
            try XCUIScreen.main.screenshot().pngRepresentation.write(to: url, options: .atomic)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "Expected demo screenshot to exist at \(url.path)"
            )
            print("Saved configured menu bar demo screenshot: \(url.path)")
        } catch {
            XCTFail("Failed to save configured menu bar demo screenshot at \(url.path): \(error)")
            throw error
        }
    }

    private func restoreOriginalConfig() {
        print("Preserving configured menu bar demo artifacts at \(configURL?.deletingLastPathComponent().path ?? "<missing>")")
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
