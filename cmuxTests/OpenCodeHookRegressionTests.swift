import XCTest
import Darwin

final class OpenCodeHookRegressionTests: XCTestCase {
    private struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    func testOpenCodeInstallHooksIsIdempotentForLegacySetupAlias() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-opencode-hooks-\(UUID().uuidString)", isDirectory: true)
        let configDir = root.appendingPathComponent("opencode", isDirectory: true)
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        let configURL = configDir.appendingPathComponent("opencode.json", isDirectory: false)
        try #"{"plugin":["other-plugin","./plugins/cmux-session.js"]}"#.write(to: configURL, atomically: true, encoding: .utf8)
        let fakeOpenCodeURL = binDir.appendingPathComponent("opencode", isDirectory: false)
        try "#!/bin/sh\nexit 0\n".write(to: fakeOpenCodeURL, atomically: true, encoding: .utf8)
        chmod(fakeOpenCodeURL.path, 0o755)

        var environment = ProcessInfo.processInfo.environment
        environment["OPENCODE_CONFIG_DIR"] = configDir.path
        environment["PATH"] = "\(binDir.path):\(environment["PATH"] ?? "/usr/bin")"
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        let result = runProcess(executablePath: cliPath, arguments: ["hooks", "opencode", "install", "--yes"], environment: environment, timeout: 5)

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let pluginURL = configDir.appendingPathComponent("plugins", isDirectory: true).appendingPathComponent("cmux-session.js", isDirectory: false)
        let pluginSource = try String(contentsOf: pluginURL, encoding: .utf8)
        XCTAssertTrue(pluginSource.contains("cmux-opencode-session-plugin-marker"))
        XCTAssertTrue(pluginSource.contains("\"hooks\", \"opencode\""))

        let secondResult = runProcess(executablePath: cliPath, arguments: ["setup-hooks", "--agent", "opencode"], environment: environment, timeout: 5)
        XCTAssertFalse(secondResult.timedOut, secondResult.stderr)
        XCTAssertEqual(secondResult.status, 0, secondResult.stderr)
        XCTAssertFalse(secondResult.stdout.contains("Will write OpenCode cmux plugin"), secondResult.stdout)
        XCTAssertTrue(secondResult.stdout.contains("OpenCode hooks already up to date"), secondResult.stdout)
        XCTAssertTrue(try String(contentsOf: configDir.appendingPathComponent("plugins/cmux-feed.js"), encoding: .utf8).contains("cmux-feed-plugin-marker"))

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try Data(contentsOf: configURL), options: []) as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(json["plugin"] as? [String]), ["other-plugin", "./plugins/cmux-session.js"])
    }

    func testLegacyHookAliasesAreHiddenFromHelp() throws {
        let cliPath = try bundledCLIPath()
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(executablePath: cliPath, arguments: ["help"], environment: environment, timeout: 5)

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertFalse(result.stdout.contains("codex <install-hooks|uninstall-hooks>"), result.stdout)
        XCTAssertFalse(result.stdout.contains("claude-hook <session-start|stop|notification>"), result.stdout)
        XCTAssertFalse(result.stdout.contains("codex-hook"), result.stdout)
        XCTAssertFalse(result.stdout.contains("feed-hook"), result.stdout)
        XCTAssertFalse(result.stdout.contains("setup-hooks"), result.stdout)
        XCTAssertFalse(result.stdout.contains("uninstall-hooks"), result.stdout)
    }

    func testOMOModelArgumentConfiguresOhMyOpenCodeAgents() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-omo-model-\(UUID().uuidString)", isDirectory: true)
        let configDir = root.appendingPathComponent(".config/opencode", isDirectory: true)
        let nodeModulesDir = configDir.appendingPathComponent("node_modules/oh-my-opencode", isDirectory: true)
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let capturedArgvURL = root.appendingPathComponent("opencode-argv.txt", isDirectory: false)
        let requestedModel = "deepinfra/zai-org/GLM-4.7-Flash"

        try FileManager.default.createDirectory(at: nodeModulesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try #"{"plugin":[]}"#.write(
            to: configDir.appendingPathComponent("opencode.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        let fakeOpenCodeURL = binDir.appendingPathComponent("opencode", isDirectory: false)
        try """
        #!/bin/sh
        printf '%s\\n' "$@" > "$HOME/opencode-argv.txt"
        exit 0
        """.write(to: fakeOpenCodeURL, atomically: true, encoding: .utf8)
        chmod(fakeOpenCodeURL.path, 0o755)

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = root.path
        environment["PATH"] = "\(binDir.path):\(environment["PATH"] ?? "/usr/bin")"
        environment["PWD"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["omo", "--model", requestedModel, "run", "hello"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let capturedArgv = try String(contentsOf: capturedArgvURL, encoding: .utf8)
        XCTAssertTrue(capturedArgv.contains("--model\n\(requestedModel)\n"), capturedArgv)

        let expectedAgentKeys = [
            "build",
            "plan",
            "sisyphus",
            "hephaestus",
            "sisyphus-junior",
            "OpenCode-Builder",
            "prometheus",
            "metis",
            "momus",
            "oracle",
            "librarian",
            "explore",
            "multimodal-looker",
            "atlas",
        ]
        let expectedCategoryKeys = [
            "quick",
            "deep",
            "ultrabrain",
            "unspecified-low",
            "unspecified-high",
            "visual-engineering",
            "artistry",
            "writing",
        ]
        let omoConfigURL = root
            .appendingPathComponent(".cmuxterm/omo-config", isDirectory: true)
            .appendingPathComponent("oh-my-opencode.json", isDirectory: false)
        let omoConfig = try XCTUnwrap(JSONSerialization.jsonObject(with: try Data(contentsOf: omoConfigURL), options: []) as? [String: Any])

        let agents = try XCTUnwrap(omoConfig["agents"] as? [String: Any])
        for agent in expectedAgentKeys {
            let config = try XCTUnwrap(agents[agent] as? [String: Any], "missing agent override for \(agent)")
            XCTAssertEqual(config["model"] as? String, requestedModel, "agent \(agent)")
        }

        let categories = try XCTUnwrap(omoConfig["categories"] as? [String: Any])
        for category in expectedCategoryKeys {
            let config = try XCTUnwrap(categories[category] as? [String: Any], "missing category override for \(category)")
            XCTAssertEqual(config["model"] as? String, requestedModel, "category \(category)")
        }

        let resetResult = runProcess(
            executablePath: cliPath,
            arguments: ["omo", "run", "hello"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(resetResult.timedOut, resetResult.stderr)
        XCTAssertEqual(resetResult.status, 0, resetResult.stderr)
        let resetConfig = try XCTUnwrap(JSONSerialization.jsonObject(with: try Data(contentsOf: omoConfigURL), options: []) as? [String: Any])
        let resetAgents = resetConfig["agents"] as? [String: Any]
        for agent in expectedAgentKeys {
            let config = resetAgents?[agent] as? [String: Any]
            XCTAssertNil(config?["model"], "agent \(agent) should not keep the previous model")
        }
        let resetCategories = resetConfig["categories"] as? [String: Any]
        for category in expectedCategoryKeys {
            let config = resetCategories?[category] as? [String: Any]
            XCTAssertNil(config?["model"], "category \(category) should not keep the previous model")
        }

        let terminatorResult = runProcess(
            executablePath: cliPath,
            arguments: ["omo", "--model", "--", "run", "hello"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(terminatorResult.timedOut, terminatorResult.stderr)
        XCTAssertEqual(terminatorResult.status, 0, terminatorResult.stderr)
        let terminatorConfig = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: omoConfigURL), options: []) as? [String: Any]
        )
        let terminatorAgents = terminatorConfig["agents"] as? [String: Any]
        for agent in expectedAgentKeys {
            let config = terminatorAgents?[agent] as? [String: Any]
            XCTAssertNil(config?["model"], "agent \(agent) should not treat -- as a model")
        }
        let terminatorCategories = terminatorConfig["categories"] as? [String: Any]
        for category in expectedCategoryKeys {
            let config = terminatorCategories?[category] as? [String: Any]
            XCTAssertNil(config?["model"], "category \(category) should not treat -- as a model")
        }
    }

    func testOMORejectsInvalidOhMyOpenCodeConfig() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-omo-invalid-config-\(UUID().uuidString)", isDirectory: true)
        let configDir = root.appendingPathComponent(".config/opencode", isDirectory: true)
        let nodeModulesDir = configDir.appendingPathComponent("node_modules/oh-my-opencode", isDirectory: true)
        let binDir = root.appendingPathComponent("bin", isDirectory: true)

        try FileManager.default.createDirectory(at: nodeModulesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try #"{"plugin":[]}"#.write(
            to: configDir.appendingPathComponent("opencode.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try "{".write(
            to: configDir.appendingPathComponent("oh-my-opencode.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        let fakeOpenCodeURL = binDir.appendingPathComponent("opencode", isDirectory: false)
        try "#!/bin/sh\nexit 0\n".write(to: fakeOpenCodeURL, atomically: true, encoding: .utf8)
        chmod(fakeOpenCodeURL.path, 0o755)

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = root.path
        environment["PATH"] = "\(binDir.path):\(environment["PATH"] ?? "/usr/bin")"
        environment["PWD"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["omo", "run", "hello"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertNotEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.contains("Failed to parse"), result.stderr)
        XCTAssertTrue(result.stderr.contains("oh-my-opencode.json"), result.stderr)
        XCTAssertFalse(result.stderr.contains(root.path), result.stderr)
        let shadowOmoConfig = root
            .appendingPathComponent(".cmuxterm/omo-config", isDirectory: true)
            .appendingPathComponent("oh-my-opencode.json", isDirectory: false)
        if FileManager.default.fileExists(atPath: shadowOmoConfig.path) {
            let shadowContents = try String(contentsOf: shadowOmoConfig, encoding: .utf8)
            XCTAssertEqual(shadowContents, "{")
        }
    }

    private func bundledCLIPath() throws -> String {
        let fileManager = FileManager.default
        let appBundleURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let enumerator = fileManager.enumerator(at: appBundleURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        while let item = enumerator?.nextObject() as? URL {
            guard item.lastPathComponent == "cmux", item.path.contains(".app/Contents/Resources/bin/cmux") else { continue }
            return item.path
        }
        throw XCTSkip("Bundled cmux CLI not found in \(appBundleURL.path)")
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) -> ProcessRunResult {
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
        } catch {
            return ProcessRunResult(status: -1, stdout: "", stderr: String(describing: error), timedOut: false)
        }
        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }
        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            _ = exitSignal.wait(timeout: .now() + 1)
        }
        return ProcessRunResult(
            status: process.terminationStatus,
            stdout: String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }
}
