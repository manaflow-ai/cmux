import Dispatch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior-level coverage for Codex completion ownership and native child
/// lifecycle. The tests drive the real hook executable against the existing
/// socket harness, so a passing result proves the visible mutation path rather
/// than a source-text or hook-shape convention.
@Suite(.serialized)
struct CodexTurnCompletionOwnershipTests {
    private struct Harness {
        let support: ClaudeHookSurfaceResolutionSwiftTests
        let context: ClaudeHookSurfaceResolutionSwiftTests.ClaudeHookContext
        let handled: DispatchSemaphore
        let environment: [String: String]
        let sessionId: String
        let token: String
    }

    @Test
    func inheritedOuterPIDCannotLetNestedCodexStopSettleForegroundPane() throws {
        let harness = try makeHarness(name: "codex-nested-inherited-pid")
        defer { harness.context.cleanup() }

        try runHook(
            harness,
            subcommand: "session-start",
            input: sessionStartPayload(harness)
        )
        try runHook(
            harness,
            subcommand: "prompt-submit",
            input: promptPayload(harness, turnId: "outer-turn")
        )

        let beforeNestedStop = harness.context.state.snapshot().count
        var nestedEnvironment = harness.environment
        // This is the exact failure mode from #7520: the child process keeps
        // the outer CMUX_CODEX_PID, while the hook's observed process is new.
        nestedEnvironment["CMUX_CODEX_HOOK_PID"] = "4243"
        let nestedResult = runProcess(
            harness,
            subcommand: "stop",
            input: #"{"session_id":"inner-autoreview","turn_id":"review-turn","cwd":"/tmp/review","hook_event_name":"Stop","last_assistant_message":"{\"findings\":[]}"}"#,
            environment: nestedEnvironment
        )
        harness.support.assertSuccessfulHook(nestedResult)
        #expect(harness.handled.wait(timeout: .now() + 5) == .success)

        let nestedCommands = Array(
            harness.context.state.snapshot().dropFirst(beforeNestedStop)
        )
        #expect(
            !nestedCommands.contains { $0.hasPrefix("notify_target_async ") },
            "A nested reviewer Stop must never publish foreground completion: \(nestedCommands)"
        )
        #expect(
            !nestedCommands.contains { $0.hasPrefix("set_status codex Idle ") },
            "A nested reviewer Stop must not make the foreground pane idle: \(nestedCommands)"
        )
        #expect(
            !nestedCommands.contains { $0.contains("surface.resume.set") },
            "A nested reviewer Stop must not replace the foreground resume identity: \(nestedCommands)"
        )
    }

    @Test
    func nativeChildrenKeepParentRunningUntilAllChildrenDrainThenNotifyOnce() throws {
        let harness = try makeHarness(name: "codex-native-child-settlement")
        defer { harness.context.cleanup() }

        try runHook(
            harness,
            subcommand: "session-start",
            input: sessionStartPayload(harness)
        )
        try runHook(
            harness,
            subcommand: "prompt-submit",
            input: promptPayload(harness, turnId: "turn-1")
        )
        try runFeedLifecycle(harness, event: "SubagentStart", id: "child-a")
        try runFeedLifecycle(harness, event: "SubagentStart", id: "child-b")

        let beforePendingStop = harness.context.state.snapshot().count
        try runHook(
            harness,
            subcommand: "stop",
            input: stopPayload(harness, turnId: "turn-1")
        )
        let pendingCommands = Array(
            harness.context.state.snapshot().dropFirst(beforePendingStop)
        )
        #expect(
            !pendingCommands.contains { $0.hasPrefix("notify_target_async ") },
            "A parent Stop with live children must not notify, even under an always-capable hook path: \(pendingCommands)"
        )
        #expect(
            pendingCommands.contains { $0.hasPrefix("set_status codex Running ") },
            "A parent Stop with live children must remain Running: \(pendingCommands)"
        )
        #expect(
            pendingCommands.contains { $0.hasPrefix("set_agent_lifecycle codex running ") },
            "The pending parent boundary must be recorded as running: \(pendingCommands)"
        )

        try runFeedLifecycle(harness, event: "SubagentStop", id: "child-a")
        let beforePartiallyDrainedStop = harness.context.state.snapshot().count
        try runHook(
            harness,
            subcommand: "stop",
            input: stopPayload(harness, turnId: "turn-1")
        )
        let partiallyDrainedCommands = Array(
            harness.context.state.snapshot().dropFirst(beforePartiallyDrainedStop)
        )
        #expect(
            !partiallyDrainedCommands.contains { $0.hasPrefix("notify_target_async ") },
            "One remaining child must continue to suppress completion: \(partiallyDrainedCommands)"
        )
        #expect(
            partiallyDrainedCommands.contains { $0.hasPrefix("set_status codex Running ") },
            "One remaining child must keep the pane Running: \(partiallyDrainedCommands)"
        )

        try runFeedLifecycle(harness, event: "SubagentStop", id: "child-b")
        let beforeFinalStop = harness.context.state.snapshot().count
        try runHook(
            harness,
            subcommand: "stop",
            input: stopPayload(harness, turnId: "turn-1")
        )
        let finalCommands = Array(
            harness.context.state.snapshot().dropFirst(beforeFinalStop)
        )
        let finalNotifications = finalCommands.filter {
            $0.hasPrefix("notify_target_async ")
        }
        #expect(
            finalNotifications.count == 1,
            "The settled foreground turn must produce exactly one completion: \(finalCommands)"
        )
        #expect(
            finalCommands.contains { $0.hasPrefix("set_status codex Idle ") },
            "The settled foreground turn must become idle: \(finalCommands)"
        )
    }

    @Test
    func normalTopLevelStopStillNotifiesAndBecomesIdle() throws {
        let harness = try makeHarness(name: "codex-normal-top-level-stop")
        defer { harness.context.cleanup() }

        try runHook(
            harness,
            subcommand: "session-start",
            input: sessionStartPayload(harness)
        )
        try runHook(
            harness,
            subcommand: "prompt-submit",
            input: promptPayload(harness, turnId: "normal-turn")
        )
        let beforeStop = harness.context.state.snapshot().count
        try runHook(
            harness,
            subcommand: "stop",
            input: stopPayload(harness, turnId: "normal-turn")
        )
        let commands = Array(harness.context.state.snapshot().dropFirst(beforeStop))
        #expect(commands.filter { $0.hasPrefix("notify_target_async ") }.count == 1)
        #expect(commands.contains { $0.hasPrefix("set_status codex Idle ") })
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
        let token = "codex-owner-\(name)"
        let environment = [
            "HOME": context.root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PWD": context.root.path,
            "CMUX_SOCKET_PATH": context.socketPath,
            "CMUX_WORKSPACE_ID": context.workspaceId,
            "CMUX_SURFACE_ID": context.surfaceId,
            "CMUX_CLI_TTY_NAME": "ttys-\(name)",
            "CMUX_CODEX_PID": "4242",
            "CMUX_CODEX_HOOK_PID": "4242",
            "CMUX_CODEX_INVOCATION_ID": token,
            "CMUX_AGENT_HOOK_STATE_DIR": context.root.path,
            "CMUX_CODEX_TURN_LEDGER_PATH": context.root.appendingPathComponent("codex-turn-ledger.json").path,
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
            sessionId: "session-\(name)",
            token: token
        )
    }

    private func runHook(
        _ harness: Harness,
        subcommand: String,
        input: String,
        environment: [String: String]? = nil
    ) throws {
        let result = runProcess(
            harness,
            subcommand: subcommand,
            input: input,
            environment: environment ?? harness.environment
        )
        #expect(harness.handled.wait(timeout: .now() + 5) == .success)
        harness.support.assertSuccessfulHook(result)
    }

    private func runFeedLifecycle(
        _ harness: Harness,
        event: String,
        id: String
    ) throws {
        try runHook(
            harness,
            subcommand: "feed --source codex --event \(event)",
            input: #"{"session_id":"\#(harness.sessionId)","turn_id":"turn-1","agent_id":"\#(id)","cwd":"\#(harness.context.root.path)","hook_event_name":"\#(event)"}"#
        )
    }

    private func runProcess(
        _ harness: Harness,
        subcommand: String,
        input: String,
        environment: [String: String]
    ) -> ClaudeHookSurfaceResolutionSwiftTests.ProcessRunResult {
        let command = subcommand.split(separator: " ").map(String.init)
        let arguments = command.first == "feed"
            ? ["hooks"] + command
            : ["hooks", "codex"] + command
        harness.support.runProcess(
            executablePath: harness.context.cliPath,
            arguments: arguments,
            environment: environment,
            standardInput: input,
            timeout: 5
        )
    }

    private func sessionStartPayload(_ harness: Harness) -> String {
        #"{"session_id":"\#(harness.sessionId)","cwd":"\#(harness.context.root.path)","hook_event_name":"SessionStart"}"#
    }

    private func promptPayload(_ harness: Harness, turnId: String) -> String {
        #"{"session_id":"\#(harness.sessionId)","turn_id":"\#(turnId)","cwd":"\#(harness.context.root.path)","hook_event_name":"UserPromptSubmit"}"#
    }

    private func stopPayload(_ harness: Harness, turnId: String) -> String {
        #"{"session_id":"\#(harness.sessionId)","turn_id":"\#(turnId)","cwd":"\#(harness.context.root.path)","hook_event_name":"Stop","last_assistant_message":"done"}"#
    }
}
