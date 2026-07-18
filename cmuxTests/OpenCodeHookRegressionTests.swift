import XCTest
import Darwin

final class OpenCodeHookRegressionTests: XCTestCase {
    private struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    func testOpenCodeLifecycleHookDeliveryDoesNotBlockOnCmuxProcessExit() throws {
        let fixture = try makeOpenCodePluginFixture(fakeCmuxLines: [
            "sleep 1",
            "cat >/dev/null",
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let harness = fixture.root.appendingPathComponent("nonblocking.mjs", isDirectory: false)
        try """
        import plugin from \(javaScriptString(fixture.pluginURL.absoluteString));
        const hooks = await plugin({ directory: process.cwd() });
        const startedAt = performance.now();
        await hooks.event({ event: {
          type: "session.created",
          properties: { info: { id: "session-nonblocking", directory: process.cwd() } },
        } });
        console.log(String(performance.now() - startedAt));
        """.write(to: harness, atomically: true, encoding: .utf8)

        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["node", harness.path],
            environment: fixture.environment,
            timeout: 3
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let elapsedMilliseconds = try XCTUnwrap(Double(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertLessThan(elapsedMilliseconds, 250, "OpenCode event callback blocked for \(elapsedMilliseconds) ms")
    }

    func testOpenCodeSessionUpdatedDoesNotRepeatSessionStartHook() throws {
        let fixture = try makeOpenCodePluginFixture(fakeCmuxLines: [
            "printf '%s\\n' \"$*\" >> \"$TEST_HOOK_CAPTURE\"",
            "cat >/dev/null",
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let capture = fixture.root.appendingPathComponent("hooks.txt", isDirectory: false)
        var environment = fixture.environment
        environment["TEST_HOOK_CAPTURE"] = capture.path

        let harness = fixture.root.appendingPathComponent("dedupe.mjs", isDirectory: false)
        try """
        import fs from "node:fs";
        import plugin from \(javaScriptString(fixture.pluginURL.absoluteString));
        const hooks = await plugin({ directory: process.cwd() });
        const info = { id: "session-dedupe", directory: process.cwd() };
        await hooks.event({ event: { type: "session.created", properties: { info } } });
        await hooks.event({ event: { type: "session.updated", properties: { info } } });
        await hooks.event({ event: { type: "session.updated", properties: { info } } });
        await hooks.event({ event: { type: "session.updated", properties: { info } } });
        await new Promise((resolve, reject) => {
          if (fs.existsSync(process.env.TEST_HOOK_CAPTURE)) return resolve();
          const watcher = fs.watch(\(javaScriptString(fixture.root.path)), () => {
            if (!fs.existsSync(process.env.TEST_HOOK_CAPTURE)) return;
            watcher.close();
            clearTimeout(timeout);
            resolve();
          });
          const timeout = setTimeout(() => {
            watcher.close();
            reject(new Error("hook capture was not created"));
          }, 2000);
        });
        """.write(to: harness, atomically: true, encoding: .utf8)

        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["node", harness.path],
            environment: environment,
            timeout: 3
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let invocations = try String(contentsOf: capture, encoding: .utf8)
            .split(separator: "\n")
            .filter { $0.contains("hooks opencode session-start") }
        XCTAssertEqual(invocations.count, 1, "session.updated repeated session-start: \(invocations)")
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

    private func bundledCLIPath() throws -> String {
        try BundledCLITestSupport.bundledCLIPath(for: Self.self)
    }

    private struct OpenCodePluginFixture {
        let root: URL
        let pluginURL: URL
        let environment: [String: String]
    }

    private func makeOpenCodePluginFixture(fakeCmuxLines: [String]) throws -> OpenCodePluginFixture {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-opencode-plugin-runtime-\(UUID().uuidString)", isDirectory: true)
        let configDir = root.appendingPathComponent("opencode", isDirectory: true)
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try #"{"type":"module"}"#.write(
            to: configDir.appendingPathComponent("package.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let fakeOpenCodeURL = binDir.appendingPathComponent("opencode", isDirectory: false)
        try "#!/bin/sh\nexit 0\n".write(to: fakeOpenCodeURL, atomically: true, encoding: .utf8)
        chmod(fakeOpenCodeURL.path, 0o755)
        let fakeCmuxURL = binDir.appendingPathComponent("cmux-hook", isDirectory: false)
        try (["#!/bin/sh"] + fakeCmuxLines + ["exit 0"]).joined(separator: "\n")
            .appending("\n")
            .write(to: fakeCmuxURL, atomically: true, encoding: .utf8)
        chmod(fakeCmuxURL.path, 0o755)

        var environment = ProcessInfo.processInfo.environment
        environment["OPENCODE_CONFIG_DIR"] = configDir.path
        environment["PATH"] = "\(binDir.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        let install = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "opencode", "install", "--yes"],
            environment: environment,
            timeout: 5
        )
        guard !install.timedOut, install.status == 0 else {
            XCTFail("OpenCode hook install failed: \(install.stderr)")
            throw NSError(domain: "OpenCodeHookRegressionTests", code: Int(install.status))
        }
        environment["CMUX_SURFACE_ID"] = "surface-opencode-runtime"
        environment["CMUX_OPENCODE_CMUX_BIN"] = fakeCmuxURL.path
        return OpenCodePluginFixture(
            root: root,
            pluginURL: configDir.appendingPathComponent("plugins/cmux-session.js", isDirectory: false),
            environment: environment
        )
    }

    private func javaScriptString(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [value], options: [])
        let array = try XCTUnwrap(String(data: data, encoding: .utf8))
        return String(array.dropFirst().dropLast())
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
