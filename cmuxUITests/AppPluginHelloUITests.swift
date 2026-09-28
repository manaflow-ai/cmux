import XCTest

/// Links and enables the Examples/cmux-plugin-hello plugin from the app's own
/// terminal, runs its "Say Hello" action from the command palette, and checks
/// that its `workspace.created` hook fired. Every step keeps a screenshot.
///
/// The app runs with `CFFIXED_USER_HOME` pointed at a throwaway directory, so
/// the plugin install root, `plugins.json`, and the plugin's state directory
/// never touch the real home of the machine running the test.
final class AppPluginHelloUITests: SettingsUITestCase {
    func testLinkEnableAndRunHelloPlugin() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-plugin-hello-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        // The repository copy is used when this machine has the checkout the
        // test was built from; otherwise the shell falls back to this copy.
        try writeFallbackExample(under: home.appendingPathComponent("src"))

        let app = XCUIApplication.cmuxTestApplication()
        app.launchArguments += settingsLaunchArguments
        app.launchEnvironment["CFFIXED_USER_HOME"] = home.path
        app.launchEnvironment["XDG_CONFIG_HOME"] = home.appendingPathComponent(".config").path
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = "ui-tests-plugin-\(UUID().uuidString.prefix(8))"
        launchAndActivate(app)
        defer { app.terminate() }

        let terminal = app.textViews.firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 15), "The workspace must contain a live terminal")
        terminal.click()

        // Refuse to run the CLI unless the shell sees the isolated home.
        let homeCheck = home.appendingPathComponent("home-check")
        app.typeText("printf %s \"$CFFIXED_USER_HOME\" > \"$CFFIXED_USER_HOME/home-check\"\n")
        XCTAssertTrue(
            poll(timeout: 10) { (try? String(contentsOf: homeCheck, encoding: .utf8)) == home.path },
            "The terminal shell must inherit the isolated CFFIXED_USER_HOME"
        )

        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().path
        app.typeText("cd '\(repoRoot)' 2>/dev/null || cd \"$CFFIXED_USER_HOME/src\"; clear\n")
        app.typeText("cmux plugin link Examples/cmux-plugin-hello\n")
        let installed = home.appendingPathComponent(".local/share/cmux/mux-plugins/extension/hello")
        XCTAssertTrue(
            poll(timeout: 10) { FileManager.default.fileExists(atPath: installed.path) },
            "cmux plugin link must install hello"
        )
        attachScreenshot(name: "1 cmux plugin link")

        app.typeText("cmux plugin enable hello\n")
        waitForTerminalText("[y/N]", in: terminal)
        attachScreenshot(name: "2 cmux plugin enable lists the commands and asks y/N")
        app.typeText("y\n")
        let enablement = home.appendingPathComponent(".config/cmux/plugins.json")
        XCTAssertTrue(
            poll(timeout: 10) {
                (try? String(contentsOf: enablement, encoding: .utf8))?.contains("hello") == true
            },
            "cmux plugin enable must record hello in plugins.json"
        )
        waitForTerminalText("Enabled hello.", in: terminal)
        attachScreenshot(name: "3 hello enabled")
        let firstTranscript = home.appendingPathComponent("transcript-1.txt")
        app.typeText("cmux read-screen --scrollback > \"$CFFIXED_USER_HOME/transcript-1.txt\"; clear\n")
        attachText(file: firstTranscript, name: "CLI transcript (link + enable)")

        app.typeKey("p", modifierFlags: [.command, .shift])
        let searchField = app.textFields["CommandPaletteSearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Expected the command palette")
        searchField.click()
        searchField.typeText("Say Hello")
        let row = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND identifier CONTAINS %@",
            "CommandPaletteResultRow.",
            "plugin.hello.say-hello"
        )).firstMatch
        let rowAppeared = row.waitForExistence(timeout: 5)
        attachScreenshot(name: "4 palette shows the plugin action")
        XCTAssertTrue(rowAppeared, "The palette must list plugin.hello.say-hello")
        row.click()

        let notification = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", "Hello from hello", "Hello from hello"
        )).firstMatch
        let notified = notification.waitForExistence(timeout: 10)
        attachScreenshot(name: "5 after Say Hello: notification from the plugin")
        XCTAssertTrue(notified, "Say Hello must post a cmux notification")

        let eventsLog = home.appendingPathComponent(".local/state/cmux/plugins/hello/events.log")
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(
            poll(timeout: 15) {
                (try? String(contentsOf: eventsLog, encoding: .utf8))?.contains("workspace.created") == true
            },
            "The workspace.created hook must append to events.log"
        )
        let newTerminal = app.textViews.firstMatch
        XCTAssertTrue(newTerminal.waitForExistence(timeout: 10))
        newTerminal.click()
        app.typeText("clear; tail -n 1 \"$CFFIXED_USER_HOME/.local/state/cmux/plugins/hello/events.log\"\n")
        waitForTerminalText("\"workspace.created\"", in: newTerminal)
        attachScreenshot(name: "6 new workspace: workspace.created hook wrote events.log")
        attachText(file: eventsLog, name: "events.log")
    }

    /// Best effort: the terminal's accessibility value mirrors its screen when
    /// available; otherwise this only paces the next screenshot.
    private func waitForTerminalText(_ text: String, in terminal: XCUIElement) {
        _ = poll(timeout: 5, interval: 0.2) { (terminal.value as? String)?.contains(text) == true }
    }

    private func attachScreenshot(name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func attachText(file: URL, name: String) {
        var text: String?
        _ = poll(timeout: 5) {
            text = try? String(contentsOf: file, encoding: .utf8)
            return text?.isEmpty == false
        }
        let attachment = XCTAttachment(string: text ?? "missing \(file.lastPathComponent)")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Same files as Examples/cmux-plugin-hello.
    private func writeFallbackExample(under root: URL) throws {
        let plugin = root.appendingPathComponent("Examples/cmux-plugin-hello")
        let bin = plugin.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let files = [
            "cmux-plugin.toml": """
            [plugin]
            name = "hello"
            kind = "extension"
            version = "0.1.0"
            description = "Posts a notification from the palette and logs new workspaces"
            platforms = ["macos"]

            [[actions]]
            id = "say-hello"
            title = "Say Hello"
            subtitle = "Hello plugin"
            keywords = ["example"]
            argv = ["./bin/say-hello"]
            shortcut = "cmd+ctrl+h"

            [[events]]
            event = "workspace.created"
            argv = ["./bin/log-event"]
            timeout_seconds = 10

            """,
            "bin/say-hello": """
            #!/bin/sh
            exec cmux notify --title "Hello from $CMUX_PLUGIN_ID" --body "Workspace $CMUX_WORKSPACE_ID"

            """,
            "bin/log-event": """
            #!/bin/sh
            printf '%s\\n' "$CMUX_EVENT_JSON" >> "$CMUX_PLUGIN_STATE_DIR/events.log"

            """,
        ]
        for (path, contents) in files {
            let url = plugin.appendingPathComponent(path)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            if path.hasPrefix("bin/") {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
        }
    }
}
