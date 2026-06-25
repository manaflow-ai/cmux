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

    private func bundledCLIPath() throws -> String {
        try BundledCLITestSupport.bundledCLIPath(for: Self.self)
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

extension CLINotifyProcessIntegrationRegressionTests {
    func testOpenCodeAutoNameSkipsEmptyCacheWithoutReportingExtractionFailure() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("opencode-auto-name-empty")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-opencode-auto-name-empty-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "opencode-empty-cache-session"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let now = Date().timeIntervalSince1970
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": root.path,
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        let storeURL = root.appendingPathComponent("opencode-hook-sessions.json", isDirectory: false)
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
            .write(to: storeURL, options: .atomic)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line) else { return "OK" }
            guard let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            guard method == "workspace.set_auto_title" else {
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"]
                )
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            if params["probe"] as? Bool == true {
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "enabled": true,
                        "workspace_user_owned": false,
                        "summarizer_agent": "auto",
                        "auto_naming_language_name": "English",
                        "auto_naming_language_tag": "en",
                    ]
                )
            }
            return self.v2Response(id: id, ok: true, result: ["ok": true])
        }

        let environment: [String: String] = [
            "HOME": root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PWD": root.path,
            "CMUX_SOCKET_PATH": socketPath,
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_CLAUDE_HOOK_STATE_PATH": storeURL.path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
        ]
        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "hooks", "opencode", "auto-name",
                "--session", sessionId,
                "--workspace", workspaceId,
                "--surface", surfaceId,
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")

        let autoTitleRequests = state.snapshot().compactMap { command -> [String: Any]? in
            guard let payload = self.jsonObject(command),
                  payload["method"] as? String == "workspace.set_auto_title" else { return nil }
            return payload["params"] as? [String: Any]
        }
        XCTAssertEqual(
            autoTitleRequests.filter { $0["probe"] as? Bool == true }.count,
            1,
            "expected exactly one auto-name probe, saw \(state.snapshot())"
        )
        XCTAssertFalse(
            autoTitleRequests.contains { $0["failure"] as? String == "extraction_failed" },
            "an empty hook-message cache is an expected no-op and must not surface as a Settings error: \(state.snapshot())"
        )
    }
}
