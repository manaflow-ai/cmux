import Darwin
import Foundation
import Testing

private final class CodexCriticalNotificationBundleMarker: NSObject {}

private final class CodexCriticalClaimCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.withLock { value += 1 }
    }

    var count: Int {
        lock.withLock { value }
    }
}

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

    @Test("A terminal stream disconnect notifies without a Stop hook")
    func streamDisconnectNotifiesFromMonitor() throws {
        let result = try runMonitor(
            transcript: """
            {"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-stream"}}
            {"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-stream","last_agent_message":null,"error":{"message":"stream disconnected before completion: error sending request for url (http://cmux-mac-mini:31415/v1/responses)","codex_error_info":"response_stream_disconnected"}}}
            """,
            sessionID: "session-stream",
            turnID: "turn-stream"
        )

        #expect(!result.process.timedOut, result.process.stderr)
        #expect(result.process.status == 0, result.process.stderr)
        #expect(
            result.commands.contains { command in
                command.contains("notify_target \(workspaceID) \(surfaceID) Codex|Network error|stream disconnected before completion: error sending request for url")
            },
            "Expected the terminal stream disconnect to notify, saw \(result.commands)"
        )
    }

    @Test("Critical notification claims are atomic across hook processes")
    func criticalNotificationClaimIsAtomic() throws {
        let root = URL(fileURLWithPath: "/tmp/cmux-codex-claim-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        let claimEnvironment = environment
        let seedStore = ClaudeHookSessionStore(processEnv: claimEnvironment)
        _ = try seedStore.upsertCodexPromptRunningIfFresh(
            sessionId: "session-claim",
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            cwd: root.path,
            turnId: "turn-claim"
        )

        let claims = CodexCriticalClaimCounter()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            let claimedAt = try? ClaudeHookSessionStore(processEnv: claimEnvironment).claimNotificationEmission(
                sessionId: "session-claim",
                fingerprint: "critical-fingerprint"
            )
            if claimedAt != nil {
                claims.increment()
            }
        }

        #expect(claims.count == 1)
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
        _ = try ClaudeHookSessionStore(processEnv: environment).upsertCodexPromptRunningIfFresh(
            sessionId: sessionID,
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            cwd: root.path,
            transcriptPath: transcriptURL.path,
            turnId: turnID
        )
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
