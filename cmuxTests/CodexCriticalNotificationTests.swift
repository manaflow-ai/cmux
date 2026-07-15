import Darwin
import Foundation
import Testing

private final class CodexCriticalNotificationBundleMarker: NSObject {}

@Suite("Codex critical notifications", .serialized)
struct CodexCriticalNotificationTests {
    private let workspaceID = "11111111-1111-1111-1111-111111111111"
    private let surfaceID = "22222222-2222-2222-2222-222222222222"

    @Test("Budget-limited turns notify as a blocking failure")
    func budgetLimitedTurnNotifies() throws {
        let result = try runMonitor(
            transcript: """
            {"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-budget"}}
            {"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn-budget","reason":"budget_limited"}}
            """,
            sessionID: "session-budget",
            turnID: "turn-budget"
        )

        #expect(!result.process.timedOut, result.process.stderr)
        #expect(result.process.status == 0, result.process.stderr)
        #expect(
            result.commands.contains { command in
                command.contains("notify_target \(workspaceID) \(surfaceID) Codex|Budget reached|Codex stopped because the turn budget was reached")
            },
            "Expected a budget-limit notification, saw \(result.commands)"
        )
    }

    @Test("Intentional turn interruption does not notify")
    func interruptedTurnDoesNotNotify() throws {
        let result = try runMonitor(
            transcript: """
            {"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-interrupted"}}
            {"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn-interrupted","reason":"interrupted"}}
            """,
            sessionID: "session-interrupted",
            turnID: "turn-interrupted"
        )

        #expect(!result.process.timedOut, result.process.stderr)
        #expect(result.process.status == 0, result.process.stderr)
        #expect(!result.commands.contains { $0.contains("notify_target") }, "Unexpected notification: \(result.commands)")
    }

    @Test("Codex process exit before a terminal event notifies")
    func processExitBeforeTerminalEventNotifies() throws {
        let result = try runMonitor(
            transcript: """
            {"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-exit"}}
            """,
            sessionID: "session-exit",
            turnID: "turn-exit",
            additionalArguments: ["--pid", "999999", "--pid-start", "1"]
        )

        #expect(!result.process.timedOut, result.process.stderr)
        #expect(result.process.status == 0, result.process.stderr)
        #expect(
            result.commands.contains { command in
                command.contains("notify_target \(workspaceID) \(surfaceID) Codex|Error|Codex exited before finishing the turn")
            },
            "Expected a process-exit notification, saw \(result.commands)"
        )
    }

    private func runMonitor(
        transcript: String,
        sessionID: String,
        turnID: String,
        additionalArguments: [String] = []
    ) throws -> (process: CodexHookProcessRunResult, commands: [String]) {
        let root = URL(fileURLWithPath: "/tmp/cmux-codex-critical-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let transcriptURL = root.appendingPathComponent("rollout.jsonl")
        let socketPath = makeCodexHookSocketPath("critical")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try transcript.appending("\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let commands = CodexHookCapturedSocketCommands()
        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: commands,
            surfaceId: surfaceID,
            connectionLimit: 1
        )
        defer {
            Darwin.shutdown(listenerFD, SHUT_RDWR)
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: CodexCriticalNotificationBundleMarker.self)
        let process = runCodexHookProcess(
            executablePath: cliPath,
            arguments: [
                "hooks", "codex", "monitor",
                "--workspace", workspaceID,
                "--surface", surfaceID,
                "--session", sessionID,
                "--turn", turnID,
                "--transcript", transcriptURL.path,
            ] + additionalArguments,
            environment: environment,
            timeout: 2
        )
        _ = waitForCondition(timeout: 1) {
            !commands.snapshot().isEmpty || process.timedOut
        }
        return (process, commands.snapshot())
    }
}
