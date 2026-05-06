import XCTest
import Darwin

/// Regression tests for `cmux hooks pi <action>`. Mirrors the OpenCode flavor
/// (cmuxTests/OpenCodeHookRegressionTests.swift) but for the cmux-vault TS
/// extension installed at `~/.pi/agent/extensions/cmux-vault/index.ts`.
///
/// Pi has no `PI_HOME`-style env override, so each test redirects `$HOME` to
/// a unique temporary directory. `cmux hooks pi install` then writes into
/// `<tmpHome>/.pi/agent/extensions/cmux-vault/index.ts`.
final class PiHookRegressionTests: XCTestCase {
    private struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    private static let extensionRelativePath = ".pi/agent/extensions/cmux-vault/index.ts"
    private static let markerString = "cmux-pi-session-extension-marker"

    // MARK: - Cases

    /// `cmux hooks pi install --yes` should write the bridge file with the
    /// cmux marker, and a second invocation should be a no-op ("already up
    /// to date") rather than rewriting the file.
    func testPiInstallIsIdempotent() throws {
        let cliPath = try bundledCLIPath()
        let root = uniqueTempDirectory(prefix: "cmux-pi-hooks-install-")
        defer { try? FileManager.default.removeItem(at: root) }
        let homeDir = root.appendingPathComponent("home", isDirectory: true)
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        // Fake `pi` on PATH so `cmux hooks pi install` doesn't skip with
        // "binary not found on PATH". Content doesn't matter.
        try writeFakeBinary(name: "pi", in: binDir)

        let environment = sandboxedEnvironment(homeDir: homeDir, binDir: binDir)
        let extensionURL = homeDir.appendingPathComponent(Self.extensionRelativePath)

        // First install: writes the file.
        let firstResult = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "pi", "install", "--yes"],
            environment: environment,
            timeout: 5
        )
        XCTAssertFalse(firstResult.timedOut, firstResult.stderr)
        XCTAssertEqual(firstResult.status, 0, firstResult.stderr)
        XCTAssertTrue(
            firstResult.stdout.contains("Pi cmux-vault extension installed at"),
            "Expected install confirmation in stdout, got: \(firstResult.stdout)"
        )

        let installed = try String(contentsOf: extensionURL, encoding: .utf8)
        XCTAssertTrue(installed.contains(Self.markerString), "Marker missing from installed extension")

        // Second install: idempotent.
        let secondResult = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "pi", "install", "--yes"],
            environment: environment,
            timeout: 5
        )
        XCTAssertFalse(secondResult.timedOut, secondResult.stderr)
        XCTAssertEqual(secondResult.status, 0, secondResult.stderr)
        XCTAssertTrue(
            secondResult.stdout.contains("already up to date"),
            "Expected idempotency message, got: \(secondResult.stdout)"
        )

        // File contents unchanged.
        let installedAgain = try String(contentsOf: extensionURL, encoding: .utf8)
        XCTAssertEqual(installed, installedAgain)
    }

    /// `cmux hooks pi install` MUST refuse to overwrite a file at the
    /// extension path that does not contain our marker. Users may have
    /// hand-written a cmux-vault extension; we never clobber it.
    func testPiInstallRefusesToClobberForeignFile() throws {
        let cliPath = try bundledCLIPath()
        let root = uniqueTempDirectory(prefix: "cmux-pi-hooks-foreign-")
        defer { try? FileManager.default.removeItem(at: root) }
        let homeDir = root.appendingPathComponent("home", isDirectory: true)
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try writeFakeBinary(name: "pi", in: binDir)

        let extensionURL = homeDir.appendingPathComponent(Self.extensionRelativePath)
        try FileManager.default.createDirectory(
            at: extensionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let foreignContents = "// user-written extension; nothing cmux-related\nexport default function () {}\n"
        try foreignContents.write(to: extensionURL, atomically: true, encoding: .utf8)

        let environment = sandboxedEnvironment(homeDir: homeDir, binDir: binDir)
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "pi", "install", "--yes"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertNotEqual(result.status, 0, "Install should refuse to overwrite a non-cmux file")
        let combined = result.stdout + result.stderr
        XCTAssertTrue(
            combined.contains("not a cmux extension"),
            "Expected refusal message, got stdout=\(result.stdout) stderr=\(result.stderr)"
        )

        // File was not overwritten.
        let onDisk = try String(contentsOf: extensionURL, encoding: .utf8)
        XCTAssertEqual(onDisk, foreignContents)
    }

    /// `cmux hooks pi install` MUST refuse to overwrite a file at the
    /// extension path when we can't even read it (e.g. binary blob, non-UTF8,
    /// permission denied). The previous implementation collapsed the read
    /// failure into an empty string via `try?`, then bypassed the foreign-
    /// file marker guard and clobbered the file.
    func testPiInstallRefusesToClobberUnreadableFile() throws {
        let cliPath = try bundledCLIPath()
        let root = uniqueTempDirectory(prefix: "cmux-pi-hooks-unreadable-")
        defer { try? FileManager.default.removeItem(at: root) }
        let homeDir = root.appendingPathComponent("home", isDirectory: true)
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try writeFakeBinary(name: "pi", in: binDir)

        let extensionURL = homeDir.appendingPathComponent(Self.extensionRelativePath)
        try FileManager.default.createDirectory(
            at: extensionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Plant a non-UTF8 binary blob. UTF8 decoding will fail (0xFF, 0xFE
        // are invalid UTF8 lead bytes; 0xC0/0xC1 are forbidden), so the
        // installer's String(contentsOfFile:encoding:.utf8) read will throw.
        let binaryContents = Data([0xFF, 0xFE, 0xFD, 0xC0, 0xC1, 0x80, 0x81, 0x82])
        try binaryContents.write(to: extensionURL)

        let environment = sandboxedEnvironment(homeDir: homeDir, binDir: binDir)
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "pi", "install", "--yes"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertNotEqual(
            result.status, 0,
            "Install must fail when the existing file can't be read; got stdout=\(result.stdout) stderr=\(result.stderr)"
        )
        // Error message must surface the path and the underlying cause
        // (uses String(describing: error), not .localizedDescription, so the
        // real Foundation error — not a generic 'operation couldn't be
        // completed' — reaches the user).
        let combined = result.stdout + result.stderr
        XCTAssertTrue(
            combined.contains("exists but could not be read"),
            "Expected a 'could not be read' message, got: \(combined)"
        )

        // Bytes-level comparison: the foreign file must be byte-for-byte
        // unchanged after the failed install.
        let onDisk = try Data(contentsOf: extensionURL)
        XCTAssertEqual(
            onDisk, binaryContents,
            "Install must not overwrite a file it could not verify"
        )
    }

    /// `cmux hooks pi uninstall --yes` should remove only files that contain
    /// the cmux marker. A foreign file at the same path must survive.
    func testPiUninstallRemovesOnlyMarkerTaggedFiles() throws {
        let cliPath = try bundledCLIPath()
        let root = uniqueTempDirectory(prefix: "cmux-pi-hooks-uninstall-")
        defer { try? FileManager.default.removeItem(at: root) }
        let homeDir = root.appendingPathComponent("home", isDirectory: true)
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try writeFakeBinary(name: "pi", in: binDir)

        let environment = sandboxedEnvironment(homeDir: homeDir, binDir: binDir)
        let extensionURL = homeDir.appendingPathComponent(Self.extensionRelativePath)

        // Install, then uninstall: file should be gone.
        let installResult = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "pi", "install", "--yes"],
            environment: environment,
            timeout: 5
        )
        XCTAssertEqual(installResult.status, 0, installResult.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: extensionURL.path))

        let uninstallResult = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "pi", "uninstall", "--yes"],
            environment: environment,
            timeout: 5
        )
        XCTAssertEqual(uninstallResult.status, 0, uninstallResult.stderr)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: extensionURL.path),
            "Uninstall should remove the cmux-vault extension"
        )
        XCTAssertTrue(
            uninstallResult.stdout.contains("Pi cmux-vault extension removed from"),
            "Expected removal confirmation, got: \(uninstallResult.stdout)"
        )

        // Now plant a foreign file and confirm uninstall leaves it alone.
        try FileManager.default.createDirectory(
            at: extensionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let foreignContents = "// not a cmux extension\n"
        try foreignContents.write(to: extensionURL, atomically: true, encoding: .utf8)

        let secondUninstall = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "pi", "uninstall", "--yes"],
            environment: environment,
            timeout: 5
        )
        XCTAssertEqual(secondUninstall.status, 0, secondUninstall.stderr)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: extensionURL.path),
            "Uninstall must NOT remove a file lacking the cmux marker"
        )
        XCTAssertTrue(
            secondUninstall.stdout.contains("no cmux marker"),
            "Expected skip-without-marker message, got: \(secondUninstall.stdout)"
        )
        let onDisk = try String(contentsOf: extensionURL, encoding: .utf8)
        XCTAssertEqual(onDisk, foreignContents)
    }

    /// `cmux hooks setup` (the global installer) should pick up pi when the
    /// pi binary is on PATH, even when ~/.pi has never been created — pi
    /// auto-creates the dir on first run, so requiring it would gate-out
    /// brand-new users from having Vault wiring set up. Mirrors the existing
    /// OpenCode exemption now expressed as `AgentHookDef.requiresConfigDir`.
    func testPiSetupHooksInstallsExtensionWithoutPreExistingConfigDir() throws {
        let cliPath = try bundledCLIPath()
        let root = uniqueTempDirectory(prefix: "cmux-pi-hooks-setup-clean-")
        defer { try? FileManager.default.removeItem(at: root) }
        let homeDir = root.appendingPathComponent("home", isDirectory: true)
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        // Intentionally do NOT pre-create ~/.pi/agent. The setup path must
        // exempt pi from the generic "config dir not found" guard
        // (commit 81d6d00 / requiresConfigDir = false on the pi AgentHookDef).
        try writeFakeBinary(name: "pi", in: binDir)

        let environment = sandboxedEnvironment(homeDir: homeDir, binDir: binDir)
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "setup", "--agent", "pi", "--yes"],
            environment: environment,
            timeout: 5
        )
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        // Setup must NOT skip pi with "config dir not found".
        let combined = result.stdout + result.stderr
        XCTAssertFalse(
            combined.contains("pi: skipped (config dir not found)"),
            "setup must not gate pi behind ~/.pi/agent existing; got: \(combined)"
        )
        let extensionURL = homeDir.appendingPathComponent(Self.extensionRelativePath)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: extensionURL.path),
            "setup must install the cmux-vault extension into a clean home"
        )
        let installed = try String(contentsOf: extensionURL, encoding: .utf8)
        XCTAssertTrue(installed.contains(Self.markerString))
    }

    /// Behavioral regression for the bridge's argv normalization. The bridge
    /// records the launch executable + argv into env vars (`CMUX_AGENT_LAUNCH_*`)
    /// for Vault to replay on resume. If the bridge bakes in `resolveExecutable("pi")`
    /// (an absolute path like `/opt/homebrew/bin/pi`), Vault loses cross-machine
    /// portability — the same launch can't be restored on a peer device with a
    /// different prefix. The bridge must persist the literal token "pi".
    ///
    /// Strategy: install the bridge to a sandbox HOME via `cmux hooks pi install`,
    /// then exec a Node harness that:
    ///   1. spoofs `process.argv = ["/abs/node", "/abs/pi-coding-agent/dist/cli.js", "--model", "..."]`
    ///   2. imports the bridge (renamed `.ts` -> `.mjs` since the bridge is plain ESM
    ///      with no TS-only syntax — confirmed by Swift's literal embedding)
    ///   3. mocks `pi.on(...)` to capture the `session_start` listener
    ///   4. routes `CMUX_PI_CMUX_BIN` at a shell shim that records its env
    ///   5. fires the listener with a fake ctx, then prints the captured env vars
    ///
    /// Skips with XCTSkip if `node` isn't on PATH (CI runners always have it).
    func testBridgePersistsLiteralPiInsteadOfAbsolutePath() throws {
        guard let nodePath = locateNode() else {
            throw XCTSkip("node not found on PATH; bridge harness needs node to run")
        }
        let cliPath = try bundledCLIPath()
        let root = uniqueTempDirectory(prefix: "cmux-pi-bridge-argv-")
        defer { try? FileManager.default.removeItem(at: root) }
        let homeDir = root.appendingPathComponent("home", isDirectory: true)
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try writeFakeBinary(name: "pi", in: binDir)

        // Install bridge.
        let installEnv = sandboxedEnvironment(homeDir: homeDir, binDir: binDir)
        let installResult = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "pi", "install", "--yes"],
            environment: installEnv,
            timeout: 5
        )
        XCTAssertEqual(installResult.status, 0, installResult.stderr)

        // Copy the bridge to .mjs so node can import it directly.
        let bridgeURL = homeDir.appendingPathComponent(Self.extensionRelativePath)
        let bridgeMJS = root.appendingPathComponent("bridge.mjs")
        let bridgeText = try String(contentsOf: bridgeURL, encoding: .utf8)
        try bridgeText.write(to: bridgeMJS, atomically: true, encoding: .utf8)

        // Shim cmux: writes its env to a known file then exits 0.
        let capturedEnvFile = root.appendingPathComponent("captured.env")
        let cmuxShim = root.appendingPathComponent("cmux-shim.sh")
        let shimScript = """
        #!/bin/sh
        env | grep -E '^CMUX_AGENT_LAUNCH_' > \"\(capturedEnvFile.path)\"
        exit 0
        """
        try shimScript.write(to: cmuxShim, atomically: true, encoding: .utf8)
        chmod(cmuxShim.path, 0o755)

        // Harness: spoof argv, import the bridge, fire session_start.
        let harness = root.appendingPathComponent("harness.mjs")
        let bridgeAbsolutePath = bridgeMJS.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let harnessSource = """
        // Spoof a `node /abs/.../pi-coding-agent/dist/cli.js --model claude` invocation.
        process.argv = [
          '/usr/local/bin/node',
          '/Users/test/.nvm/versions/node/v22/lib/node_modules/@mariozechner/pi-coding-agent/dist/cli.js',
          '--model', 'claude-sonnet-4-5',
        ];
        const { default: register } = await import('file://\(bridgeAbsolutePath)');
        const listeners = {};
        const pi = { on(event, cb) { listeners[event] = cb; } };
        await register(pi);
        const fakeCtx = {
          sessionManager: {
            getSessionId: () => 'test-session-uuid',
            getSessionFile: () => '/tmp/fake.jsonl',
            getCwd: () => '/tmp/fake-cwd',
          },
          cwd: '/tmp/fake-cwd',
        };
        await listeners.session_start({ reason: 'test' }, fakeCtx);
        """
        try harnessSource.write(to: harness, atomically: true, encoding: .utf8)

        // Run the harness with shim wired in.
        var harnessEnv = ProcessInfo.processInfo.environment
        harnessEnv["CMUX_PI_CMUX_BIN"] = cmuxShim.path
        harnessEnv["CMUX_SURFACE_ID"] = "test-surface"
        harnessEnv["CMUX_PI_HOOKS_DISABLED"] = ""
        let harnessResult = runProcess(
            executablePath: nodePath,
            arguments: [harness.path],
            environment: harnessEnv,
            timeout: 10
        )
        XCTAssertFalse(harnessResult.timedOut, "node harness timed out: \(harnessResult.stderr)")
        XCTAssertEqual(
            harnessResult.status, 0,
            "node harness failed: stdout=\(harnessResult.stdout) stderr=\(harnessResult.stderr)"
        )

        // Read what the shim captured. The bridge persists CMUX_AGENT_LAUNCH_*
        // env vars; the executable must be the literal string "pi".
        let captured = (try? String(contentsOf: capturedEnvFile, encoding: .utf8)) ?? ""
        XCTAssertTrue(
            captured.contains("CMUX_AGENT_LAUNCH_KIND=pi\n"),
            "Expected CMUX_AGENT_LAUNCH_KIND=pi in captured env, got: \(captured)"
        )
        XCTAssertTrue(
            captured.contains("CMUX_AGENT_LAUNCH_EXECUTABLE=pi\n"),
            "Bridge must record executable as the literal token 'pi', not an absolute path. Captured: \(captured)"
        )
        // Decode the b64-NUL argv and confirm it leads with "pi".
        let argvLine = captured
            .split(separator: "\n")
            .first(where: { $0.hasPrefix("CMUX_AGENT_LAUNCH_ARGV_B64=") })
            .map(String.init) ?? ""
        let b64 = argvLine.dropFirst("CMUX_AGENT_LAUNCH_ARGV_B64=".count)
        guard let decoded = Data(base64Encoded: String(b64)) else {
            return XCTFail("could not base64-decode argv from: \(argvLine)")
        }
        // The bridge encodes argv as <utf8>\0<utf8>\0...; split on NUL.
        let parts = decoded
            .split(separator: 0, omittingEmptySubsequences: false)
            .map { String(data: Data($0), encoding: .utf8) ?? "" }
            .filter { !$0.isEmpty }
        XCTAssertEqual(
            parts.first, "pi",
            "argv[0] in recorded launch must be the literal 'pi'; got parts=\(parts)"
        )
        XCTAssertTrue(
            parts.contains("--model"),
            "argv tail must preserve user-set flags; got parts=\(parts)"
        )
        // No baked-in absolute path leaked through.
        XCTAssertFalse(
            parts.contains(where: { $0.hasPrefix("/") && $0.contains("pi") }),
            "recorded argv must not contain absolute paths to pi; got parts=\(parts)"
        )
    }

    // MARK: - Helpers

    private func locateNode() -> String? {
        let candidates = [
            ProcessInfo.processInfo.environment["NODE_BIN"],
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ].compactMap { $0 }
        let fm = FileManager.default
        for path in candidates where fm.isExecutableFile(atPath: path) { return path }
        // Fall back to PATH search.
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = String(dir) + "/node"
                if fm.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return nil
    }

    private func sandboxedEnvironment(homeDir: URL, binDir: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = homeDir.path
        env["PATH"] = "\(binDir.path):\(env["PATH"] ?? "/usr/bin:/bin")"
        env["CMUX_CLI_SENTRY_DISABLED"] = "1"
        return env
    }

    private func writeFakeBinary(name: String, in dir: URL) throws {
        let url = dir.appendingPathComponent(name, isDirectory: false)
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o755)
    }

    private func uniqueTempDirectory(prefix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(prefix)\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func bundledCLIPath() throws -> String {
        let fileManager = FileManager.default
        let appBundleURL = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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
