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

    func testOpenCodeLifecycleHooksStayOrderedPerSessionWhileOtherSessionsDispatch() throws {
        let fixture = try makeOpenCodePluginFixture(fakeCmuxLines: [
            "payload=\"$(cat)\"",
            "printf '%s|%s\\n' \"$3\" \"$payload\" >> \"$TEST_HOOK_CAPTURE\"",
            "case \"$payload\" in",
            "  *session-ordered*)",
            "    cat \"$TEST_HOOK_RELEASE_FIFO\" >/dev/null",
            "    ;;",
            "esac",
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let capture = fixture.root.appendingPathComponent("hooks.txt", isDirectory: false)
        let releaseFIFO = fixture.root.appendingPathComponent("release.fifo", isDirectory: false)
        XCTAssertEqual(mkfifo(releaseFIFO.path, S_IRUSR | S_IWUSR), 0)
        var environment = fixture.environment
        environment["TEST_HOOK_CAPTURE"] = capture.path
        environment["TEST_HOOK_RELEASE_FIFO"] = releaseFIFO.path

        let harness = fixture.root.appendingPathComponent("ordered.mjs", isDirectory: false)
        try """
        import fs from "node:fs";
        import plugin from \(javaScriptString(fixture.pluginURL.absoluteString));

        const hooks = await plugin({ directory: process.cwd() });
        const orderedInfo = { id: "session-ordered", directory: process.cwd() };
        const otherInfo = { id: "session-other", directory: process.cwd() };
        const captureLines = () => fs.existsSync(process.env.TEST_HOOK_CAPTURE)
          ? fs.readFileSync(process.env.TEST_HOOK_CAPTURE, "utf8").trim().split("\\n").filter(Boolean)
          : [];
        const waitForLineCount = (count) => new Promise((resolve, reject) => {
          const ready = () => captureLines().length >= count;
          if (ready()) return resolve();
          const watcher = fs.watch(\(javaScriptString(fixture.root.path)), () => {
            if (!ready()) return;
            watcher.close();
            clearTimeout(timeout);
            resolve();
          });
          const timeout = setTimeout(() => {
            watcher.close();
            reject(new Error(`hook capture did not reach ${count} lines`));
          }, 2000);
        });
        const records = () => captureLines().map((line) => {
          const separator = line.indexOf("|");
          const payload = JSON.parse(line.slice(separator + 1));
          return { subcommand: line.slice(0, separator), sessionId: payload.session_id };
        });
        const releaseOrderedHook = () => fs.writeFileSync(
          process.env.TEST_HOOK_RELEASE_FIFO,
          "release\\n"
        );

        await hooks.event({ event: { type: "session.created", properties: { info: orderedInfo } } });
        await waitForLineCount(1);

        await hooks.event({ event: { type: "session.idle", properties: { info: orderedInfo } } });
        await hooks.event({ event: { type: "session.idle", properties: { info: orderedInfo } } });
        await hooks.event({ event: { type: "session.deleted", properties: { info: orderedInfo } } });
        await hooks.event({ event: { type: "session.created", properties: { info: orderedInfo } } });
        await hooks.event({ event: { type: "session.created", properties: { info: otherInfo } } });
        await waitForLineCount(2);

        const beforeRelease = records();
        releaseOrderedHook();
        await waitForLineCount(3);
        releaseOrderedHook();
        await waitForLineCount(4);
        releaseOrderedHook();
        await waitForLineCount(5);
        const afterRelease = records();
        releaseOrderedHook();
        console.log(JSON.stringify({ beforeRelease, afterRelease }));
        """.write(to: harness, atomically: true, encoding: .utf8)

        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["node", harness.path],
            environment: environment,
            timeout: 4
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let snapshot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        let beforeRelease = try XCTUnwrap(snapshot["beforeRelease"] as? [[String: String]])
        XCTAssertEqual(beforeRelease.compactMap { $0["sessionId"] }.sorted(), ["session-ordered", "session-other"])
        XCTAssertEqual(beforeRelease.compactMap { $0["subcommand"] }, ["session-start", "session-start"])

        let afterRelease = try XCTUnwrap(snapshot["afterRelease"] as? [[String: String]])
        let orderedCommands = afterRelease
            .filter { $0["sessionId"] == "session-ordered" }
            .compactMap { $0["subcommand"] }
        XCTAssertEqual(orderedCommands, ["session-start", "stop", "session-end", "session-start"])
    }

    func testOpenCodeQueueOverloadPreservesEveryAcceptedStartEndPair() throws {
        let fixture = try makeOpenCodePluginFixture(fakeCmuxLines: [
            "payload=\"$(cat)\"",
            "printf '%s|%s\\n' \"$3\" \"$payload\" >> \"$TEST_HOOK_CAPTURE\"",
            "if [ \"$3\" = \"session-start\" ]; then /usr/bin/nc -U \"$TEST_HOOK_RELEASE_SOCKET\" >/dev/null; fi",
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let capture = fixture.root.appendingPathComponent("hooks.txt", isDirectory: false)
        let releaseSocket = fixture.root.appendingPathComponent("release.sock", isDirectory: false)
        var environment = fixture.environment
        environment["TEST_HOOK_CAPTURE"] = capture.path
        environment["TEST_HOOK_RELEASE_SOCKET"] = releaseSocket.path

        let harness = fixture.root.appendingPathComponent("overload.mjs", isDirectory: false)
        try """
        import fs from "node:fs";
        import net from "node:net";
        import plugin from \(javaScriptString(fixture.pluginURL.absoluteString));

        const hooks = await plugin({ directory: process.cwd() });
        let releaseStarts = false;
        const heldStarts = [];
        const releaseServer = net.createServer((socket) => {
          socket.on("error", () => {});
          if (releaseStarts) {
            socket.end("release\\n");
          } else {
            heldStarts.push(socket);
          }
        });
        await new Promise((resolve, reject) => {
          releaseServer.once("error", reject);
          releaseServer.listen(process.env.TEST_HOOK_RELEASE_SOCKET, resolve);
        });
        const captureLines = () => fs.existsSync(process.env.TEST_HOOK_CAPTURE)
          ? fs.readFileSync(process.env.TEST_HOOK_CAPTURE, "utf8").trim().split("\\n").filter(Boolean)
          : [];
        const records = () => captureLines().map((line) => {
          const separator = line.indexOf("|");
          const payload = JSON.parse(line.slice(separator + 1));
          return { subcommand: line.slice(0, separator), sessionId: payload.session_id };
        });
        const waitFor = (description, predicate) => new Promise((resolve, reject) => {
          if (predicate()) return resolve();
          const watcher = fs.watch(\(javaScriptString(fixture.root.path)), () => {
            if (!predicate()) return;
            watcher.close();
            clearTimeout(timeout);
            resolve();
          });
          const timeout = setTimeout(() => {
            watcher.close();
            reject(new Error(`timed out waiting for ${description}`));
          }, 6000);
        });

        const sessionIds = [
          "session-terminal-reservation",
          ...Array.from({ length: 300 }, (_, index) => `session-overload-${index}`),
        ];
        for (const sessionId of sessionIds) {
          const info = { id: sessionId, directory: process.cwd() };
          await hooks.event({ event: { type: "session.created", properties: { info } } });
        }
        for (const sessionId of sessionIds.slice(1)) {
          const info = { id: sessionId, directory: process.cwd() };
          await hooks.event({ event: { type: "session.deleted", properties: { info } } });
        }
        const terminalInfo = { id: sessionIds[0], directory: process.cwd() };
        await hooks.event({ event: { type: "session.deleted", properties: { info: terminalInfo } } });

        await waitFor("four blocked session starts", () => records().length >= 4);
        releaseStarts = true;
        for (const socket of heldStarts.splice(0)) socket.end("release\\n");
        await waitFor(
          "the terminal hook reserved while the queue was full",
          () => records().some((record) =>
            record.sessionId === "session-terminal-reservation"
              && record.subcommand === "session-end"
          )
        );
        await new Promise((resolve) => releaseServer.close(resolve));
        console.log(JSON.stringify(records()));
        """.write(to: harness, atomically: true, encoding: .utf8)

        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["node", harness.path],
            environment: environment,
            timeout: 10
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let records = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: String]]
        )
        let starts = records.filter { $0["subcommand"] == "session-start" }
        let ends = records.filter { $0["subcommand"] == "session-end" }
        XCTAssertGreaterThan(starts.count, 100, "fixture did not saturate the 256-slot queue")
        XCTAssertLessThan(starts.count, 301, "the bounded queue admitted every overload session")
        XCTAssertEqual(Set(starts.compactMap { $0["sessionId"] }), Set(ends.compactMap { $0["sessionId"] }))
        XCTAssertEqual(starts.count, ends.count)
        XCTAssertTrue(ends.contains { $0["sessionId"] == "session-terminal-reservation" })
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
