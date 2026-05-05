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
        XCTAssertTrue(
            installed.contains("\"hooks\", \"pi\", subcommand"),
            "Bridge body should call `cmux hooks pi <subcommand>`; got:\n\(installed.prefix(800))"
        )

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
    /// pi binary is on PATH and write the same bridge file. Mirrors the
    /// legacy `setup-hooks --agent opencode` shape.
    func testPiSetupHooksInstallsExtension() throws {
        let cliPath = try bundledCLIPath()
        let root = uniqueTempDirectory(prefix: "cmux-pi-hooks-setup-")
        defer { try? FileManager.default.removeItem(at: root) }
        let homeDir = root.appendingPathComponent("home", isDirectory: true)
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        // Pre-create the .pi/agent dir; otherwise the generic "config dir not
        // found" guard skips. Pi auto-creates this on first run; we mimic
        // the post-first-run state.
        try FileManager.default.createDirectory(
            at: homeDir.appendingPathComponent(".pi/agent", isDirectory: true),
            withIntermediateDirectories: true
        )
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
        let extensionURL = homeDir.appendingPathComponent(Self.extensionRelativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: extensionURL.path))
        let installed = try String(contentsOf: extensionURL, encoding: .utf8)
        XCTAssertTrue(installed.contains(Self.markerString))
    }

    // MARK: - Helpers

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
