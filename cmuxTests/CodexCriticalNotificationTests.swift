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
                command.contains("notify_target \(workspaceID) \(surfaceID) Codex|Budget reached|Codex stopped because the turn budget was reached|d=codex-critical:")
            },
            "Expected a budget-limit notification, saw \(result.commands)"
        )
    }

    @Test("Canonical session-budget terminal errors use the budget notification")
    func sessionBudgetTerminalErrorNotifies() throws {
        let result = try runMonitor(
            transcript: """
            {"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-session-budget"}}
            {"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-session-budget","last_agent_message":null,"error":{"message":"Session budget exceeded.","codex_error_info":"session_budget_exceeded"}}}
            """,
            sessionID: "session-budget-terminal",
            turnID: "turn-session-budget"
        )

        #expect(!result.process.timedOut, result.process.stderr)
        #expect(result.process.status == 0, result.process.stderr)
        #expect(
            result.commands.contains { command in
                command.contains("notify_target \(workspaceID) \(surfaceID) Codex|Budget reached|Session budget exceeded.")
            },
            "Expected a session-budget notification, saw \(result.commands)"
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

    @Test("Turn context scopes budget aborts without repeated turn IDs")
    func turnContextScopesBudgetAbort() throws {
        let result = try runMonitor(
            transcript: """
            {"type":"turn_context","payload":{"turn_id":"turn-context-budget"}}
            {"type":"event_msg","payload":{"type":"turn_aborted","reason":"budget_limited"}}
            """,
            sessionID: "session-context-budget",
            turnID: "turn-context-budget"
        )

        #expect(!result.process.timedOut, result.process.stderr)
        #expect(result.process.status == 0, result.process.stderr)
        #expect(
            result.commands.contains { $0.contains("Codex|Budget reached|Codex stopped because the turn budget was reached") },
            "Expected a turn-context budget notification, saw \(result.commands)"
        )
    }

    @Test("Intentional abort preserves an earlier fatal error")
    func intentionalAbortPreservesFatalError() throws {
        let result = try runMonitor(
            transcript: """
            {"type":"turn_context","payload":{"turn_id":"turn-error-abort"}}
            {"type":"event_msg","payload":{"type":"error","message":"Selected model is at capacity. Please try a different model.","codex_error_info":"other"}}
            {"type":"event_msg","payload":{"type":"turn_aborted","reason":"interrupted"}}
            """,
            sessionID: "session-error-abort",
            turnID: "turn-error-abort"
        )

        #expect(!result.process.timedOut, result.process.stderr)
        #expect(result.process.status == 0, result.process.stderr)
        #expect(
            result.commands.contains { $0.contains("Selected model is at capacity. Please try a different model.") },
            "Expected the preceding fatal error to survive the abort, saw \(result.commands)"
        )
    }

    @Test("Codex process exit before a terminal event notifies")
    func processExitBeforeTerminalEventNotifies() throws {
        let codexProcess = Process()
        codexProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
        codexProcess.arguments = ["1"]
        try codexProcess.run()
        let processIdentity = try #require(
            CMUXCLI(args: []).sessionsListProcessIdentity(for: Int(codexProcess.processIdentifier))
        )
        defer {
            if codexProcess.isRunning { codexProcess.terminate() }
            codexProcess.waitUntilExit()
        }
        let result = try runMonitor(
            transcript: """
            {"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-exit"}}
            """,
            sessionID: "session-exit",
            turnID: "turn-exit",
            additionalArguments: [
                "--pid", String(codexProcess.processIdentifier),
                "--pid-start", String(processIdentity.startTime),
            ]
        )

        #expect(!result.process.timedOut, result.process.stderr)
        #expect(result.process.status == 0, result.process.stderr)
        #expect(
            result.commands.contains { command in
                command.contains("notify_target \(workspaceID) \(surfaceID) Codex|Error|Codex exited before finishing the turn|d=codex-critical:")
            },
            "Expected a process-exit notification, saw \(result.commands)"
        )
    }

    @Test("Codex exit before monitor registration notifies")
    func processGoneBeforeMonitorRegistrationNotifies() throws {
        let result = try runMonitor(
            transcript: """
            {"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-gone"}}
            """,
            sessionID: "session-gone",
            turnID: "turn-gone",
            additionalArguments: ["--pid-gone"]
        )

        #expect(!result.process.timedOut, result.process.stderr)
        #expect(result.process.status == 0, result.process.stderr)
        #expect(
            result.commands.contains { command in
                command.contains("notify_target \(workspaceID) \(surfaceID) Codex|Error|Codex exited before finishing the turn")
            },
            "Expected a pre-registration process-exit notification, saw \(result.commands)"
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
                command.contains("notify_target \(workspaceID) \(surfaceID) Codex|Network error|Codex lost its connection before finishing. Try again.")
                    && !command.contains("cmux-mac-mini")
                    && !command.contains("http://")
                    && !command.contains("stream disconnected")
            },
            "Expected the terminal stream disconnect to notify, saw \(result.commands)"
        )
    }

    @Test("A model-capacity failure notifies without a Stop hook")
    func modelCapacityFailureNotifiesFromMonitor() throws {
        let result = try runMonitor(
            transcript: """
            {"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-capacity"}}
            {"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-capacity","last_agent_message":null,"error":{"message":"Selected model is at capacity. Please try a different model.","codex_error_info":"other"}}}
            """,
            sessionID: "session-capacity",
            turnID: "turn-capacity"
        )

        #expect(!result.process.timedOut, result.process.stderr)
        #expect(result.process.status == 0, result.process.stderr)
        #expect(
            result.commands.contains { command in
                command.contains("notify_target \(workspaceID) \(surfaceID) Codex|Error|Selected model is at capacity. Please try a different model.")
            },
            "Expected the model-capacity failure to notify, saw \(result.commands)"
        )
    }

    @Test("Critical delivery dedupe follows the live surface")
    func criticalDeliveryDedupeFollowsSurface() {
        let delivery = AgentNotificationDelivery()
        let firstWorkspace = UUID()
        let secondWorkspace = UUID()
        let surface = UUID()
        let secondSurface = UUID()
        let dedupeKey = "codex-critical:\(UUID().uuidString)"

        #expect(delivery.enqueue(
            workspaceID: firstWorkspace,
            surfaceID: surface,
            title: "Codex",
            subtitle: "Error",
            body: "Stopped",
            category: nil,
            pending: false,
            dedupeKey: dedupeKey
        ))
        #expect(!delivery.enqueue(
            workspaceID: secondWorkspace,
            surfaceID: surface,
            title: "Codex",
            subtitle: "Different rendering",
            body: "Try again later",
            category: nil,
            pending: false,
            dedupeKey: dedupeKey
        ))
        #expect(delivery.enqueue(
            workspaceID: secondWorkspace,
            surfaceID: secondSurface,
            title: "Codex",
            subtitle: "Error",
            body: "Stopped",
            category: nil,
            pending: false,
            dedupeKey: dedupeKey
        ))
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
            timeout: 4
        )
        _ = waitForCondition(timeout: 1) {
            !commands.snapshot().isEmpty || process.timedOut
        }
        return (process, commands.snapshot())
    }
}
