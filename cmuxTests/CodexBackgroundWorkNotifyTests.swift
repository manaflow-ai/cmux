import Dispatch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavioral coverage for Codex native subagent lifecycle events feeding the
/// Stop hook's pending-work decision. The payloads deliberately omit a
/// transcript path so this cannot pass through the transcript relay scan.
@Suite(.serialized)
struct CodexBackgroundWorkNotifyTests {
    private struct Harness {
        let support: ClaudeHookSurfaceResolutionSwiftTests
        let context: ClaudeHookSurfaceResolutionSwiftTests.ClaudeHookContext
        let handled: DispatchSemaphore
        let environment: [String: String]
        let sessionId: String
    }

    @Test func stopWithActiveSubagentTagsPendingAndWhenIdleGateDropsNotification() throws {
        let harness = try makeHarness(name: "codex-bg-gate")
        defer { harness.context.cleanup() }

        try establishActiveSubagent(harness, agentId: "agent-gate")
        let commandsBeforeStop = harness.context.state.snapshot().count
        try runHook(
            harness,
            arguments: ["hooks", "codex", "stop"],
            input: stopPayload(harness, turnId: "turn-1")
        )

        let stopCommands = Array(harness.context.state.snapshot().dropFirst(commandsBeforeStop))
        let notification = try #require(
            stopCommands.first { $0.hasPrefix("notify_target_async ") },
            "Codex Stop must emit a turn-complete notification; saw \(stopCommands)"
        )
        #expect(
            notification.contains("c=turn-complete;p=1"),
            "Stop with an active Codex subagent must tag the notification pending; saw \(notification)"
        )

        let metaText = try #require(notification.split(separator: "|").last.map(String.init))
        let meta = try #require(AgentNotificationMeta(meta: metaText))
        #expect(meta.category == .turnComplete)
        #expect(meta.pending)
        #expect(
            agentNotificationShouldDeliver(
                category: meta.category,
                pending: meta.pending,
                permissionEnabled: true,
                turnMode: .whenIdle,
                idleEnabled: true
            ) == false,
            "The default when-idle gate must drop a pending Codex completion"
        )
    }

    @Test func hasActiveCodexBackgroundWorkUsesSubagentLifecycleWithoutTranscriptScan() throws {
        let harness = try makeHarness(name: "codex-bg-state")
        defer { harness.context.cleanup() }

        try establishActiveSubagent(harness, agentId: "agent-state")
        let commandsBeforePendingStop = harness.context.state.snapshot().count
        try runHook(
            harness,
            arguments: ["hooks", "codex", "stop"],
            input: stopPayload(harness, turnId: "turn-1")
        )

        let pendingStopCommands = Array(
            harness.context.state.snapshot().dropFirst(commandsBeforePendingStop)
        )
        #expect(
            pendingStopCommands.contains { $0.hasPrefix("set_status codex Running ") },
            "An active subagent must keep the Codex status Running; saw \(pendingStopCommands)"
        )
        #expect(
            pendingStopCommands.contains { $0.hasPrefix("set_agent_lifecycle codex running ") },
            "An active subagent must keep the Codex lifecycle running; saw \(pendingStopCommands)"
        )
        #expect(
            pendingStopCommands.contains {
                $0.hasPrefix("notify_target_async ") && $0.contains("c=turn-complete;p=1")
            },
            "Active Codex background work must be detected without transcript output; saw \(pendingStopCommands)"
        )

        try runHook(
            harness,
            arguments: ["hooks", "feed", "--source", "codex", "--event", "SubagentStop"],
            input: subagentPayload(
                harness,
                event: "SubagentStop",
                agentId: "agent-state",
                turnId: "turn-1"
            )
        )
        try runHook(
            harness,
            arguments: ["hooks", "codex", "prompt-submit"],
            input: promptPayload(harness, turnId: "turn-2")
        )

        let commandsBeforeIdleStop = harness.context.state.snapshot().count
        try runHook(
            harness,
            arguments: ["hooks", "codex", "stop"],
            input: stopPayload(harness, turnId: "turn-2")
        )
        let idleStopCommands = Array(harness.context.state.snapshot().dropFirst(commandsBeforeIdleStop))
        #expect(
            idleStopCommands.contains {
                $0.hasPrefix("notify_target_async ") && $0.contains("c=turn-complete;p=0")
            },
            "Once SubagentStop drains the last child, Codex must emit a real idle completion; saw \(idleStopCommands)"
        )
        #expect(
            idleStopCommands.contains { $0.hasPrefix("set_status codex Idle ") },
            "A drained Codex session must return to Idle; saw \(idleStopCommands)"
        )
    }

    private func makeHarness(name: String) throws -> Harness {
        let support = ClaudeHookSurfaceResolutionSwiftTests()
        let context = try support.makeClaudeHookContext(name: name)
        let handled = support.startClaudeSurfaceResolutionServer(
            context: context,
            surfaces: [(context.surfaceId, "surface:1", true)],
            ttyName: "ttys-\(name)",
            ttySurfaceId: context.surfaceId
        )
        let environment: [String: String] = [
            "HOME": context.root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PWD": context.root.path,
            "CMUX_SOCKET_PATH": context.socketPath,
            "CMUX_WORKSPACE_ID": context.workspaceId,
            "CMUX_SURFACE_ID": context.surfaceId,
            "CMUX_CLI_TTY_NAME": "ttys-\(name)",
            "CMUX_CODEX_PID": "42424",
            "CMUX_AGENT_HOOK_STATE_DIR": context.root.path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CMUX_AGENT_LAUNCH_KIND": "codex",
            "CMUX_AGENT_LAUNCH_EXECUTABLE": "/usr/local/bin/codex",
            "CMUX_AGENT_LAUNCH_CWD": context.root.path,
        ]
        return Harness(
            support: support,
            context: context,
            handled: handled,
            environment: environment,
            sessionId: "session-\(name)"
        )
    }

    private func establishActiveSubagent(_ harness: Harness, agentId: String) throws {
        try runHook(
            harness,
            arguments: ["hooks", "codex", "session-start"],
            input: sessionStartPayload(harness)
        )
        try runHook(
            harness,
            arguments: ["hooks", "codex", "prompt-submit"],
            input: promptPayload(harness, turnId: "turn-1")
        )
        try runHook(
            harness,
            arguments: ["hooks", "feed", "--source", "codex", "--event", "SubagentStart"],
            input: subagentPayload(
                harness,
                event: "SubagentStart",
                agentId: agentId,
                turnId: "turn-1"
            )
        )
    }

    private func runHook(
        _ harness: Harness,
        arguments: [String],
        input: String
    ) throws {
        let result = harness.support.runProcess(
            executablePath: harness.context.cliPath,
            arguments: arguments,
            environment: harness.environment,
            standardInput: input,
            timeout: 5
        )
        #expect(harness.handled.wait(timeout: .now() + 5) == .success)
        harness.support.assertSuccessfulHook(result)
    }

    private func sessionStartPayload(_ harness: Harness) -> String {
        #"""
        {"session_id":"\#(harness.sessionId)","cwd":"\#(harness.context.root.path)","hook_event_name":"SessionStart"}
        """#
    }

    private func promptPayload(_ harness: Harness, turnId: String) -> String {
        #"""
        {"session_id":"\#(harness.sessionId)","turn_id":"\#(turnId)","cwd":"\#(harness.context.root.path)","hook_event_name":"UserPromptSubmit"}
        """#
    }

    private func stopPayload(_ harness: Harness, turnId: String) -> String {
        #"""
        {"session_id":"\#(harness.sessionId)","turn_id":"\#(turnId)","cwd":"\#(harness.context.root.path)","hook_event_name":"Stop","last_assistant_message":"done"}
        """#
    }

    private func subagentPayload(
        _ harness: Harness,
        event: String,
        agentId: String,
        turnId: String
    ) -> String {
        #"""
        {"session_id":"\#(harness.sessionId)","turn_id":"\#(turnId)","cwd":"\#(harness.context.root.path)","hook_event_name":"\#(event)","agent_id":"\#(agentId)","agent_type":"default"}
        """#
    }
}
