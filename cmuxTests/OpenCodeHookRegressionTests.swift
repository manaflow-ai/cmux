import Darwin
import Dispatch
import Foundation
import class XCTest.XCTestCase
import func XCTest.XCTAssertEqual
import func XCTest.XCTAssertFalse
import func XCTest.XCTAssertTrue
import func XCTest.XCTUnwrap

// Intentionally XCTest, not Swift Testing: this suite spawns the real bundled `cmux` CLI as a
// subprocess (process/socket harness). Team guidance keeps CLI/process-harness tests on XCTest and
// reserves Swift Testing for pure unit/decision tests (cmux-reviewer feedback 1c365bbd). Do not
// migrate this file to `@Suite`/`@Test`.
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

    // Regression for https://github.com/manaflow-ai/cmux/issues/7140:
    // `cmux hooks opencode install` rewrote opencode.json through NSJSONSerialization, which
    // escapes every `/` to `\/`. opencode's `{file:...}` template resolver reads the inner path
    // byte-literally, so `{file:./AGENTS.md}` became `{file:.\/AGENTS.md}` and opencode rejected the
    // entire config ("bad file reference"). Verify the written file preserves slashes verbatim.
    func testOpenCodeInstallPreservesFileReferencesWithoutSlashEscaping() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-opencode-slash-\(UUID().uuidString)", isDirectory: true)
        let configDir = root.appendingPathComponent("opencode", isDirectory: true)
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A realistic opencode config: a `{file:./AGENTS.md}` agent prompt, a `./`-prefixed
        // instruction, and an `https://` schema URL — all of which contain slashes.
        let configURL = configDir.appendingPathComponent("opencode.json", isDirectory: false)
        let inputConfig = """
        {
          "$schema": "https://opencode.ai/config.json",
          "agent": { "myagent": { "mode": "primary", "prompt": "{file:./AGENTS.md}" } },
          "instructions": ["./AGENTS.md"]
        }
        """
        try inputConfig.write(to: configURL, atomically: true, encoding: .utf8)
        try "# Agents\n".write(to: configDir.appendingPathComponent("AGENTS.md", isDirectory: false), atomically: true, encoding: .utf8)

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

        // Read the RAW bytes opencode itself would read — do NOT round-trip through a JSON parser,
        // which normalizes `\/` back to `/` and would mask the corruption.
        let rawConfig = try String(contentsOf: configURL, encoding: .utf8)

        XCTAssertFalse(
            rawConfig.contains("\\/"),
            "opencode.json must not contain backslash-escaped slashes; got:\n\(rawConfig)"
        )
        XCTAssertTrue(
            rawConfig.contains("{file:./AGENTS.md}"),
            "The `{file:./AGENTS.md}` reference must survive verbatim; got:\n\(rawConfig)"
        )
        XCTAssertFalse(
            rawConfig.contains("{file:.\\/AGENTS.md}"),
            "The corrupted `{file:.\\/AGENTS.md}` form must never appear; got:\n\(rawConfig)"
        )
        XCTAssertTrue(
            rawConfig.contains("\"./AGENTS.md\""),
            "The `./AGENTS.md` instruction must survive verbatim; got:\n\(rawConfig)"
        )
        XCTAssertTrue(
            rawConfig.contains("https://opencode.ai/config.json"),
            "The schema URL must survive verbatim; got:\n\(rawConfig)"
        )
        // cmux's own injected plugin path must also be unescaped.
        XCTAssertTrue(
            rawConfig.contains("./plugins/cmux-session.js"),
            "The injected plugin spec must be written unescaped; got:\n\(rawConfig)"
        )

        // The re-parsed prompt value must byte-literally equal the natural form — this is the exact
        // invariant opencode's `{file:...}` resolver depends on.
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: try Data(contentsOf: configURL), options: []) as? [String: Any])
        let agent = try XCTUnwrap(parsed["agent"] as? [String: Any])
        let myagent = try XCTUnwrap(agent["myagent"] as? [String: Any])
        XCTAssertEqual(myagent["prompt"] as? String, "{file:./AGENTS.md}")
        XCTAssertEqual(parsed["instructions"] as? [String], ["./AGENTS.md"])
        XCTAssertEqual(try XCTUnwrap(parsed["plugin"] as? [String]), ["./plugins/cmux-session.js"])
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
