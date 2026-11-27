import XCTest

extension CLINotifyProcessIntegrationRegressionTests {
    private func museHookCommands(in hooks: [String: Any], event: String) -> [[String: Any]] {
        (hooks[event] as? [[String: Any]] ?? [])
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap { $0 }
    }

    func testMuseHookInstallMergesPinnedHooksIntoUserSettings() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-muse-hook-install-\(UUID().uuidString)", isDirectory: true)
        let settingsURL = root
            .appendingPathComponent(".config/muse", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let userSettings: [String: Any] = [
            "schema_version": 1,
            "tui": ["foreign_context_notice_shown": true],
            "contributor_mode_enabled": true,
        ]
        try JSONSerialization.data(withJSONObject: userSettings, options: [.prettyPrinted, .sortedKeys])
            .write(to: settingsURL, options: .atomic)

        let socketPath = makeSocketPath("muse-install")
        let environment = [
            "HOME": root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CMUX_SOCKET_PATH": socketPath,
            "CMUX_CLI_SENTRY_DISABLED": "1",
        ]
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "muse", "install", "--yes"],
            environment: environment,
            timeout: 5
        )
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
        XCTAssertEqual(json["schema_version"] as? Int, 1)
        XCTAssertEqual(json["contributor_mode_enabled"] as? Bool, true)
        XCTAssertEqual((json["tui"] as? [String: Any])?["foreign_context_notice_shown"] as? Bool, true)
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])

        let expected: [(event: String, subcommand: String)] = [
            ("SessionStart", "session-start"),
            ("UserPromptSubmit", "prompt-submit"),
            ("Stop", "stop"),
            ("StopFailure", "notification"),
            ("Notification", "notification"),
            ("SessionEnd", "session-end"),
        ]
        for (event, subcommand) in expected {
            let commands = museHookCommands(in: hooks, event: event)
            XCTAssertEqual(commands.count, 1, "\(event): \(commands)")
            let command = try XCTUnwrap(commands.first?["command"] as? String)
            // Muse runs hooks with the user's login shell, so the installed
            // command is only a quoted script path that fish and nushell parse too.
            XCTAssertTrue(command.hasPrefix("'/"), "\(event): \(command)")
            XCTAssertTrue(command.hasSuffix("' cmux-muse-hook-v1 \(subcommand)"), "\(event): \(command)")
            let scriptPath = String(command.dropFirst().prefix { $0 != "'" })
            XCTAssertTrue(scriptPath.contains("/.cmux/hooks/muse/"), "\(event): \(scriptPath)")
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: scriptPath), scriptPath)
            let script = try String(contentsOfFile: scriptPath, encoding: .utf8)
            XCTAssertTrue(script.hasPrefix("#!/bin/sh\n"), script)
            XCTAssertTrue(script.contains("hooks enqueue muse \(subcommand)"), "\(event): \(script)")
            XCTAssertTrue(script.contains("cmux-muse-hook-v1"), "\(event): \(script)")
            XCTAssertTrue(script.contains("--socket '\(socketPath)'"), "\(event): \(script)")
            XCTAssertFalse(script.contains("[ -n \"$CMUX_SURFACE_ID\" ]"), "Muse clears CMUX_* from hooks: \(script)")
            XCTAssertEqual(commands.first?["type"] as? String, "command")
            // Muse follows the Claude Code hook contract, which counts timeouts in seconds.
            XCTAssertEqual(commands.first?["timeout"] as? Int, 10, event)
        }

        let reinstall = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "muse", "install", "--yes"],
            environment: environment,
            timeout: 5
        )
        XCTAssertEqual(reinstall.status, 0, reinstall.stderr)
        let reinstalled = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
        let reinstalledHooks = try XCTUnwrap(reinstalled["hooks"] as? [String: Any])
        XCTAssertEqual(museHookCommands(in: reinstalledHooks, event: "Stop").count, 1, "Reinstall must not duplicate hooks")

        let uninstall = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "muse", "uninstall", "--yes"],
            environment: environment,
            timeout: 5
        )
        XCTAssertEqual(uninstall.status, 0, uninstall.stderr)
        let removed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
        XCTAssertEqual(removed["schema_version"] as? Int, 1)
        XCTAssertEqual(removed["contributor_mode_enabled"] as? Bool, true)
        let remainingCommands = (removed["hooks"] as? [String: Any] ?? [:]).keys.flatMap { event in
            museHookCommands(in: removed["hooks"] as? [String: Any] ?? [:], event: event)
        }
        XCTAssertTrue(remainingCommands.isEmpty, "Uninstall left cmux Muse hooks: \(remainingCommands)")
    }

    func testMuseHookInstallCreatesVersionedSettingsUnderXDGConfigHome() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-muse-hook-xdg-\(UUID().uuidString)", isDirectory: true)
        let xdgConfig = root.appendingPathComponent("xdg config", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "muse", "install", "--yes"],
            environment: [
                "HOME": root.path,
                "XDG_CONFIG_HOME": xdgConfig.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SOCKET_PATH": makeSocketPath("muse-xdg"),
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            timeout: 5
        )
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let settingsURL = xdgConfig
            .appendingPathComponent("muse", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
        // Muse rejects a settings file without a schema version.
        XCTAssertEqual(json["schema_version"] as? Int, 1)
        XCTAssertNotNil((json["hooks"] as? [String: Any])?["Stop"])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent(".config/muse/settings.json").path)
        )
    }
}
