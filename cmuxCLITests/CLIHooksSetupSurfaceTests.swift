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

    private func runCLI(arguments: [String]) throws -> ProcessResult {
        let process = Process()
        let output = Pipe()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hooks-surface-(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

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
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output

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
        let data = try output.fileHandleForReading.readToEnd() ?? Data()
        return ProcessResult(
            status: process.isRunning ? SIGKILL : process.terminationStatus,
            output: String(data: data, encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }
}
