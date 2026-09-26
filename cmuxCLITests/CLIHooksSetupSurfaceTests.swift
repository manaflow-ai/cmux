import Foundation
import Testing

private final class CLIHooksSetupSurfaceBundleToken {}

@Suite("Hooks setup discovery", .serialized)
struct CLIHooksSetupSurfaceTests {
    private struct ProcessResult {
        let status: Int32
        let output: String
        let timedOut: Bool
    }

    @Test("Top-level help calls out hook status and setup")
    func topLevelHelpCallsOutHooks() throws {
        let result = try runCLI(arguments: ["help"])

        #expect(!result.timedOut, Comment(rawValue: result.output))
        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(result.output.contains("hooks setup|status|uninstall"), Comment(rawValue: result.output))
    }

    @Test("Hook status is available without a running app")
    func hookStatusIsNoSocket() throws {
        let result = try runCLI(arguments: ["hooks", "status", "--json"])

        #expect(!result.timedOut, Comment(rawValue: result.output))
        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(result.output.contains("\"agents\""), Comment(rawValue: result.output))
        #expect(result.output.contains("\"codex\""), Comment(rawValue: result.output))
        #expect(!result.output.contains("\"config_path\""), Comment(rawValue: result.output))
        #expect(!result.output.contains("PATH"), Comment(rawValue: result.output))
    }

    @Test("Human hook status explains unavailable agent CLIs")
    func humanHookStatusExplainsUnavailableAgents() throws {
        let result = try runCLI(arguments: ["hooks", "status"])

        #expect(!result.timedOut, Comment(rawValue: result.output))
        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(result.output.contains("Agent CLI unavailable"), Comment(rawValue: result.output))
    }

    @Test("Setup explains when no supported agent CLI is available")
    func setupWithoutAgentsDoesNotExposeEnvironmentDetails() throws {
        let result = try runCLI(arguments: ["hooks", "setup", "--yes"])

        #expect(!result.timedOut, Comment(rawValue: result.output))
        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(result.output.contains("No supported agent CLIs were found."), Comment(rawValue: result.output))
        #expect(!result.output.contains("PATH"), Comment(rawValue: result.output))
    }

    @Test("Setup configures a detected CLI before its config directory exists")
    func setupCreatesFreshCodexConfigDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hooks-fresh-codex-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let codex = bin.appendingPathComponent("codex", isDirectory: false)
        try "#!/bin/sh\nexit 0\n".write(to: codex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)

        let result = try runCLI(
            arguments: ["hooks", "setup", "--yes"],
            homeRoot: root,
            path: bin.path
        )

        #expect(!result.timedOut, Comment(rawValue: result.output))
        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(result.output.contains("Detected agent CLIs: Codex"), Comment(rawValue: result.output))
        #expect(result.output.contains("Done: 1 installed, 0 skipped"), Comment(rawValue: result.output))
        let hooks = root.appendingPathComponent(".codex/hooks.json", isDirectory: false)
        #expect(FileManager.default.fileExists(atPath: hooks.path))
        #expect(try String(contentsOf: hooks, encoding: .utf8).contains("cmux hooks codex"))
    }

    @Test("Hook status accepts flag and positional agent filters")
    func hookStatusAgentFilters() throws {
        let flag = try runCLI(arguments: ["hooks", "status", "--agent", "codex", "--json"])
        #expect(flag.status == 0, Comment(rawValue: flag.output))
        #expect(flag.output.contains("\"codex\""), Comment(rawValue: flag.output))
        #expect(!flag.output.contains("\"claude\""), Comment(rawValue: flag.output))

        let positional = try runCLI(arguments: ["hooks", "status", "codex", "--json"])
        #expect(positional.status == 0, Comment(rawValue: positional.output))
        #expect(positional.output.contains("\"codex\""), Comment(rawValue: positional.output))
        #expect(!positional.output.contains("\"gemini\""), Comment(rawValue: positional.output))
    }

    @Test("Hook status rejects invalid and conflicting agent filters")
    func hookStatusRejectsInvalidFilters() throws {
        let invalid = try runCLI(arguments: ["hooks", "status", "--agent", "does-not-exist", "--json"])
        #expect(invalid.status != 0, Comment(rawValue: invalid.output))
        #expect(invalid.output.contains("Unknown hooks target"), Comment(rawValue: invalid.output))

        let conflicting = try runCLI(arguments: ["hooks", "status", "codex", "--agent", "gemini", "--json"])
        #expect(conflicting.status != 0, Comment(rawValue: conflicting.output))
        #expect(conflicting.output.contains("Conflicting hooks target"), Comment(rawValue: conflicting.output))
    }

    private func runCLI(
        arguments: [String],
        homeRoot: URL? = nil,
        path: String? = nil
    ) throws -> ProcessResult {
        let process = Process()
        let output = Pipe()
        let ownsRoot = homeRoot == nil
        let root = homeRoot ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hooks-surface-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if ownsRoot {
            defer { try? FileManager.default.removeItem(at: root) }
        }

        process.executableURL = URL(
            fileURLWithPath: try BundledCLITestSupport.bundledCLIPath(
                for: CLIHooksSetupSurfaceBundleToken.self
            )
        )
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["HOME"] = root.path
        environment["PATH"] = path ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output

        let outputGroup = DispatchGroup()
        outputGroup.enter()
        var outputData = Data()
        DispatchQueue.global(qos: .userInitiated).async {
            outputData = (try? output.fileHandleForReading.readToEnd()) ?? Data()
            outputGroup.leave()
        }

        let exitSignal = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exitSignal.signal() }
        try process.run()
        let timedOut = exitSignal.wait(timeout: .now() + 10) == .timedOut
        if timedOut {
            process.terminate()
            if exitSignal.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exitSignal.wait(timeout: .now() + 1)
            }
        }
        outputGroup.wait()
        return ProcessResult(
            status: process.isRunning ? SIGKILL : process.terminationStatus,
            output: String(data: outputData, encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }
}
