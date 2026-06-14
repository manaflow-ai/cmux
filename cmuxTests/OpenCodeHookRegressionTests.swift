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

    func testBundledOpenCodeWrapperInstallsHooksWhenSocketIsLive() throws {
        let wrapperPath = try bundledOpenCodeWrapperPath()
        let shortId = String(UUID().uuidString.prefix(8))
        let root = URL(fileURLWithPath: "/tmp/cmux-\(shortId)", isDirectory: true)
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let logURL = root.appendingPathComponent("calls.log", isDirectory: false)
        let socketURL = root.appendingPathComponent("cmux.sock", isDirectory: false)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let socketFD = try createUnixSocket(at: socketURL.path)
        defer {
            close(socketFD)
            unlink(socketURL.path)
        }

        let fakeCmuxURL = binDir.appendingPathComponent("cmux", isDirectory: false)
        try """
        #!/bin/sh
        printf 'cmux:%s\\n' "$*" >> "$CMUX_TEST_LOG"
        if [ "$1" = "--socket" ]; then
          shift 2
        fi
        if [ "$1" = "ping" ]; then
          exit 0
        fi
        if [ "$1" = "hooks" ] && [ "$2" = "opencode" ] && [ "$3" = "install" ] && [ "$4" = "--yes" ]; then
          exit 0
        fi
        exit 64
        """.write(to: fakeCmuxURL, atomically: true, encoding: .utf8)
        chmod(fakeCmuxURL.path, 0o755)

        let fakeOpenCodeURL = binDir.appendingPathComponent("opencode", isDirectory: false)
        try """
        #!/bin/sh
        printf 'opencode:%s\\n' "$*" >> "$CMUX_TEST_LOG"
        printf 'cmux-bin:%s\\n' "$CMUX_OPENCODE_CMUX_BIN" >> "$CMUX_TEST_LOG"
        printf 'kind:%s\\n' "$CMUX_AGENT_LAUNCH_KIND" >> "$CMUX_TEST_LOG"
        printf 'pid:%s\\n' "$CMUX_OPENCODE_PID" >> "$CMUX_TEST_LOG"
        exit 23
        """.write(to: fakeOpenCodeURL, atomically: true, encoding: .utf8)
        chmod(fakeOpenCodeURL.path, 0o755)

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(binDir.path):\(environment["PATH"] ?? "/usr/bin")"
        environment["CMUX_BUNDLED_CLI_PATH"] = fakeCmuxURL.path
        environment["CMUX_SOCKET_PATH"] = socketURL.path
        environment["CMUX_SURFACE_ID"] = UUID().uuidString
        environment["CMUX_WORKSPACE_ID"] = UUID().uuidString
        environment["CMUX_TEST_LOG"] = logURL.path

        let result = runProcess(
            executablePath: wrapperPath,
            arguments: ["run", "--model", "anthropic/claude-sonnet-4-6", "fix this"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 23, result.stderr)
        let log = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("cmux:--socket \(socketURL.path) ping"), log)
        XCTAssertTrue(log.contains("cmux:--socket \(socketURL.path) hooks opencode install --yes"), log)
        XCTAssertTrue(log.contains("opencode:run --model anthropic/claude-sonnet-4-6 fix this"), log)
        XCTAssertTrue(log.contains("cmux-bin:\(fakeCmuxURL.path)"), log)
        XCTAssertTrue(log.contains("kind:opencode"), log)
        XCTAssertTrue(log.range(of: #"pid:\d+"#, options: .regularExpression) != nil, log)
    }

    func testBundledOpenCodeWrapperPassesThroughOutsideCmux() throws {
        let wrapperPath = try bundledOpenCodeWrapperPath()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-opencode-wrapper-passthrough-\(UUID().uuidString)", isDirectory: true)
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let logURL = root.appendingPathComponent("calls.log", isDirectory: false)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeOpenCodeURL = binDir.appendingPathComponent("opencode", isDirectory: false)
        try """
        #!/bin/sh
        printf 'opencode:%s\\n' "$*" >> "$CMUX_TEST_LOG"
        printf 'kind:${CMUX_AGENT_LAUNCH_KIND:-unset}\\n' >> "$CMUX_TEST_LOG"
        exit 17
        """.write(to: fakeOpenCodeURL, atomically: true, encoding: .utf8)
        chmod(fakeOpenCodeURL.path, 0o755)

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(binDir.path):\(environment["PATH"] ?? "/usr/bin")"
        environment["CMUX_TEST_LOG"] = logURL.path
        environment.removeValue(forKey: "CMUX_SURFACE_ID")
        environment.removeValue(forKey: "CMUX_SOCKET_PATH")
        environment.removeValue(forKey: "CMUX_AGENT_LAUNCH_KIND")

        let result = runProcess(
            executablePath: wrapperPath,
            arguments: ["--version"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 17, result.stderr)
        let log = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertEqual(log, "opencode:--version\nkind:unset\n")
    }

    func testOpenCodeSessionPluginDeduplicatesRuntimeLifecycleEvents() throws {
        let cliPath = try bundledCLIPath()
        let nodePath = try nodeExecutablePath()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-opencode-plugin-runtime-\(UUID().uuidString)", isDirectory: true)
        let configDir = root.appendingPathComponent("opencode", isDirectory: true)
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let logURL = root.appendingPathComponent("cmux.log", isDirectory: false)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeOpenCodeURL = binDir.appendingPathComponent("opencode", isDirectory: false)
        try "#!/bin/sh\nexit 0\n".write(to: fakeOpenCodeURL, atomically: true, encoding: .utf8)
        chmod(fakeOpenCodeURL.path, 0o755)

        var installEnvironment = ProcessInfo.processInfo.environment
        installEnvironment["OPENCODE_CONFIG_DIR"] = configDir.path
        installEnvironment["PATH"] = "\(binDir.path):\(installEnvironment["PATH"] ?? "/usr/bin")"
        installEnvironment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let installResult = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "opencode", "install", "--yes"],
            environment: installEnvironment,
            timeout: 5
        )
        XCTAssertFalse(installResult.timedOut, installResult.stderr)
        XCTAssertEqual(installResult.status, 0, installResult.stderr)
        try #"{"type":"module"}"#.write(
            to: configDir.appendingPathComponent("package.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let fakeCmuxURL = binDir.appendingPathComponent("cmux", isDirectory: false)
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> "$CMUX_TEST_LOG"
        if [ "$1" = "hooks" ]; then
          cat >/dev/null
        fi
        exit 0
        """.write(to: fakeCmuxURL, atomically: true, encoding: .utf8)
        chmod(fakeCmuxURL.path, 0o755)

        let lifecycleEvictionSessionCount = 12
        let scriptURL = root.appendingPathComponent("drive-opencode-plugin.mjs", isDirectory: false)
        try """
        const plugin = (await import(process.env.CMUX_TEST_PLUGIN_URL)).default;
        const sessionId = "opencode-session-1";
        const cwd = process.env.CMUX_TEST_CWD;
        const restore = await plugin({ directory: cwd });
        const send = async (type, properties = {}) => {
          await restore.event({ event: { type, properties } });
        };
        const info = { id: sessionId, directory: cwd };
        const status = (type) => ({ info: { ...info, status: { type } } });
        await send("session.created", { info });
        await send("session.status", status("error"));
        await send("session.error", { info, error: { message: "upstream quota" } });
        await send("session.status", status("running"));
        await send("session.status", { info: { ...info, status: { type: "error", message: "retry after rate limit" } } });
        await send("session.status", status("running"));
        await send("session.error", { info, error: { message: "upstream quota" } });
        await send("permission.asked", { info, message: "approve" });
        await send("session.updated", { info: { ...info, title: "metadata refresh" } });
        await send("session.idle", { info });
        await send("permission.replied", { sessionID: sessionId });
        await send("session.idle", { info });
        await send("session.status", status("running"));
        await send("session.status", { info: { ...info, status: { type: "queued", message: "done waiting for inactive workbench" } } });
        await send("session.status", status("idle"));
        await send("todo.updated", { info });
        await send("session.idle", { info });
        await send("session.idle", { note: "missing session id" });
        await send("session.status", status("running"));
        await send("session.idle", { info });
        const archivedInfo = { id: "opencode-session-archived", directory: cwd };
        await send("session.created", { info: archivedInfo });
        await send("permission.asked", { info: archivedInfo, message: "approve" });
        await send("session.updated", { info: { ...archivedInfo, time: { archived: true } } });
        await send("session.idle", { info: archivedInfo });
        const protectedInfo = { id: "opencode-session-protected", directory: cwd };
        await send("session.created", { info: protectedInfo });
        await send("permission.asked", { info: protectedInfo, message: "approve" });
        for (let index = 0; index < \(lifecycleEvictionSessionCount); index += 1) {
          const otherInfo = { id: `opencode-session-${index + 2}`, directory: cwd };
          await send("session.created", { info: otherInfo });
          await send("session.status", { info: { ...otherInfo, status: { type: "idle" } } });
        }
        await send("session.idle", { info: protectedInfo });
        await send("permission.replied", { sessionID: protectedInfo.id });
        await send("session.idle", { info: protectedInfo });
        await send("session.idle", { info });
        """.write(to: scriptURL, atomically: true, encoding: .utf8)

        let pluginURL = configDir.appendingPathComponent("plugins/cmux-session.js", isDirectory: false)
        var runtimeEnvironment = installEnvironment
        runtimeEnvironment["CMUX_OPENCODE_CMUX_BIN"] = fakeCmuxURL.path
        runtimeEnvironment["CMUX_OPENCODE_PID"] = "4242"
        runtimeEnvironment["CMUX_SURFACE_ID"] = "surface-test"
        runtimeEnvironment["CMUX_WORKSPACE_ID"] = "workspace-test"
        runtimeEnvironment["CMUX_TEST_CWD"] = root.path
        runtimeEnvironment["CMUX_TEST_LOG"] = logURL.path
        runtimeEnvironment["CMUX_TEST_PLUGIN_URL"] = pluginURL.absoluteString
        runtimeEnvironment["CMUX_OPENCODE_SESSION_LIFECYCLE_LIMIT"] = "8"

        let result = runProcess(
            executablePath: nodePath,
            arguments: [scriptURL.path],
            environment: runtimeEnvironment,
            timeout: 5
        )
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let log = try String(contentsOf: logURL, encoding: .utf8)
        let commands = log.split(separator: "\n").map(String.init)
        let errorNotifications = commands.filter { $0.contains("hooks opencode runtime-notification error") }
        XCTAssertEqual(errorNotifications.count, 3, log)
        let needsInputStatuses = commands.filter { $0.contains("hooks opencode runtime-status needs-input") }
        XCTAssertEqual(needsInputStatuses.count, 3, log)
        let runningStatuses = commands.filter { $0.contains("hooks opencode runtime-status running") }
        XCTAssertEqual(runningStatuses.count, 6, log)
        let retryingStatuses = commands.filter { $0.contains("hooks opencode runtime-status retrying") }
        XCTAssertEqual(retryingStatuses.count, 0, log)
        let idleStatuses = commands.filter { $0.contains("hooks opencode runtime-status idle") }
        XCTAssertEqual(idleStatuses.count, lifecycleEvictionSessionCount + 7, log)
        let stopHooks = commands.filter { $0 == "hooks opencode stop" }
        XCTAssertEqual(stopHooks.count, lifecycleEvictionSessionCount + 6, log)
    }

    private func bundledCLIPath() throws -> String {
        try BundledCLITestSupport.bundledCLIPath(for: Self.self)
    }

    private func bundledOpenCodeWrapperPath() throws -> String {
        let fileManager = FileManager.default
        let appBundleURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let enumerator = fileManager.enumerator(at: appBundleURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        while let item = enumerator?.nextObject() as? URL {
            guard item.lastPathComponent == "opencode", item.path.contains(".app/Contents/Resources/bin/opencode") else { continue }
            return item.path
        }
        throw XCTSkip("Bundled opencode wrapper not found in \(appBundleURL.path)")
    }

    private func nodeExecutablePath() throws -> String {
        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["which", "node"],
            environment: ProcessInfo.processInfo.environment,
            timeout: 5
        )
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.timedOut, result.status == 0, !path.isEmpty else {
            throw XCTSkip("Node executable not found")
        }
        return path
    }

    private func createUnixSocket(at path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        try withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            guard pathBytes.count < buffer.count else {
                throw POSIXError(.ENAMETOOLONG)
            }
            for index in pathBytes.indices {
                buffer[index] = pathBytes[index]
            }
            buffer[pathBytes.count] = 0
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count + 1))
            }
        }
        guard bindResult == 0 else {
            let capturedErrno = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: capturedErrno) ?? .EIO)
        }

        guard listen(fd, 1) == 0 else {
            let capturedErrno = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: capturedErrno) ?? .EIO)
        }
        return fd
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
