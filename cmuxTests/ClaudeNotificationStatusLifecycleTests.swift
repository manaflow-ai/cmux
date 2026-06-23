import Dispatch
import Foundation
import Testing

@Suite(.serialized)
struct ClaudeNotificationStatusLifecycleTests {
    @Test func claudeNotificationStatusCarriesPIDForStaleSweep() throws {
        let harness = ClaudeHookSurfaceResolutionSwiftTests()
        let context = try harness.makeClaudeHookContext(name: "claude-notify-pid")
        defer { context.cleanup() }

        let claudePID = 42_424
        let serverHandled = harness.startClaudeSurfaceResolutionServer(
            context: context,
            surfaces: [(context.surfaceId, "surface:1", true)],
            ttyName: "ttys-claude-notify-pid",
            ttySurfaceId: context.surfaceId
        )

        var environment = harness.claudeHookEnvironment(
            context: context,
            surfaceId: context.surfaceId,
            ttyName: "ttys-claude-notify-pid",
            storeURL: context.root.appendingPathComponent("claude-hook-sessions.json")
        )
        environment["CMUX_CLAUDE_PID"] = "\(claudePID)"

        let result = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "notification"],
            environment: environment,
            standardInput: #"{"session_id":"claude-notify-pid-session","cwd":"\#(context.root.path)","hook_event_name":"Notification","message":"Claude needs your input"}"#,
            timeout: 5
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        harness.assertSuccessfulHook(result)

        let statusCommand = try #require(
            context.state.snapshot().first {
                $0.hasPrefix("set_status claude_code Needs input ")
                    && $0.contains("--tab=\(context.workspaceId)")
                    && $0.contains("--panel=\(context.surfaceId)")
            },
            "Expected Claude notification to set a Needs input status, saw \(context.state.snapshot())"
        )
        #expect(
            statusCommand.contains("--pid=\(claudePID)"),
            "Claude notification status must be PID-backed so the stale PID sweep can clear it after abrupt agent exit; command=\(statusCommand)"
        )
    }

    @Test func plainWaitingNotificationResolvesToIdleLifecycle() throws {
        let snapshot = try runClaudeNotification(
            name: "claude-notify-waiting",
            ttyName: "ttys-claude-notify-waiting",
            message: "Claude is waiting for your input"
        )
        // Regression: a bare "waiting for input" reminder fires after Claude has gone
        // idle. It must report `.idle` so the pane stays hibernation-eligible, not
        // `.needsInput` (which clobbered the Stop hook's idle and blocked hibernation).
        #expect(
            snapshot.contains { $0.hasPrefix("set_agent_lifecycle claude_code idle ") },
            "Expected a plain waiting notification to set idle lifecycle, saw \(snapshot)"
        )
        #expect(
            !snapshot.contains { $0.hasPrefix("set_agent_lifecycle claude_code needsInput") },
            "A plain waiting notification must not set needsInput, saw \(snapshot)"
        )
    }

    @Test func permissionNotificationKeepsNeedsInputLifecycle() throws {
        let snapshot = try runClaudeNotification(
            name: "claude-notify-permission",
            ttyName: "ttys-claude-notify-permission",
            message: "Claude needs your permission to use Bash"
        )
        // A genuine permission / approval prompt is a real blocking state and must
        // stay `.needsInput` so the pane is not hibernated while the user is expected
        // to respond.
        #expect(
            snapshot.contains { $0.hasPrefix("set_agent_lifecycle claude_code needsInput ") },
            "Expected a permission notification to set needsInput lifecycle, saw \(snapshot)"
        )
    }

    @Test func unrecognizedAttentionNotificationFailsClosedToNeedsInput() throws {
        // Fail closed: a notification that is neither a recognized idle/completion
        // reminder nor a permission prompt must keep the pane live, so a blocking
        // prompt phrased without a known cue is never hibernated while Claude waits.
        let snapshot = try runClaudeNotification(
            name: "claude-notify-unrecognized",
            ttyName: "ttys-claude-notify-unrecognized",
            message: "Please confirm to continue"
        )
        #expect(
            snapshot.contains { $0.hasPrefix("set_agent_lifecycle claude_code needsInput ") },
            "Expected an unrecognized attention notification to fail closed to needsInput, saw \(snapshot)"
        )
        #expect(
            !snapshot.contains { $0.hasPrefix("set_agent_lifecycle claude_code idle") },
            "An unrecognized attention notification must not resolve to idle, saw \(snapshot)"
        )
    }

    @Test func deferredBlockingWaitingNotificationDoesNotDowngradeNeedsInput() throws {
        // AskUserQuestion / ExitPlanMode record `.needsInput` in PreToolUse, then defer
        // the bell to a Notification whose text can read "waiting for your response".
        // The "waiting" cue would classify to idle, but the recorded blocking state must
        // win so the pane is not hibernated while the user still owes an answer.
        let snapshot = try runClaudeNotification(
            name: "claude-notify-deferred-block",
            ttyName: "ttys-claude-notify-deferred-block",
            message: "Claude is waiting for your response",
            seededLifecycle: "needsInput",
            seededBody: "Which option do you want?"
        )
        #expect(
            snapshot.contains { $0.hasPrefix("set_agent_lifecycle claude_code needsInput ") },
            "Expected a deferred blocking notification with waiting text to keep needsInput, saw \(snapshot)"
        )
        #expect(
            !snapshot.contains { $0.hasPrefix("set_agent_lifecycle claude_code idle") },
            "A pending blocking prompt must not be downgraded to idle by waiting text, saw \(snapshot)"
        )
    }

    @Test func savedBodyReusePathDoesNotInheritStaleIdle() throws {
        // The saved-body reuse path fires for generic "needs your input/attention"
        // notifications. A session record's `agentLifecycle` is sticky (an earlier
        // Stop/idle can leave it `.idle`), so reusing it here would downgrade a fresh
        // generic blocking notification to idle and hibernate the pane while Claude is
        // waiting. The handler must keep the freshly classified lifecycle, which fails
        // closed to `.needsInput` for this generic text.
        let snapshot = try runClaudeNotification(
            name: "claude-notify-stale-idle",
            ttyName: "ttys-claude-notify-stale-idle",
            message: "Claude needs your input",
            seededLifecycle: "idle",
            seededBody: "Which option do you want?"
        )
        #expect(
            snapshot.contains { $0.hasPrefix("set_agent_lifecycle claude_code needsInput ") },
            "Expected the saved-body reuse path to keep needsInput, not inherit stale idle, saw \(snapshot)"
        )
        #expect(
            !snapshot.contains { $0.hasPrefix("set_agent_lifecycle claude_code idle") },
            "The saved-body reuse path must not downgrade a generic blocking notification to idle, saw \(snapshot)"
        )
    }

    /// Runs the Claude `notification` hook with a given message and returns the
    /// socket commands it emitted. When `seededLifecycle`/`seededBody` are provided,
    /// a prior session record is written first so the handler's saved-body reuse path
    /// is exercised (mirrors a blocking PreToolUse that recorded state then deferred
    /// the notification).
    private func runClaudeNotification(
        name: String,
        ttyName: String,
        message: String,
        seededLifecycle: String? = nil,
        seededBody: String? = nil
    ) throws -> [String] {
        let harness = ClaudeHookSurfaceResolutionSwiftTests()
        let context = try harness.makeClaudeHookContext(name: name)
        defer { context.cleanup() }

        let sessionId = "\(name)-session"
        let storeURL = context.root.appendingPathComponent("claude-hook-sessions.json")
        if let seededLifecycle, let seededBody {
            try seedClaudeSession(
                storeURL: storeURL,
                sessionId: sessionId,
                workspaceId: context.workspaceId,
                surfaceId: context.surfaceId,
                cwd: context.root.path,
                agentLifecycle: seededLifecycle,
                lastBody: seededBody
            )
        }

        let serverHandled = harness.startClaudeSurfaceResolutionServer(
            context: context,
            surfaces: [(context.surfaceId, "surface:1", true)],
            ttyName: ttyName,
            ttySurfaceId: context.surfaceId
        )

        var environment = harness.claudeHookEnvironment(
            context: context,
            surfaceId: context.surfaceId,
            ttyName: ttyName,
            storeURL: storeURL
        )
        environment["CMUX_CLAUDE_PID"] = "42424"

        let result = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "notification"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"Notification","message":"\#(message)"}"#,
            timeout: 5
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        harness.assertSuccessfulHook(result)
        return context.state.snapshot()
    }

    private func seedClaudeSession(
        storeURL: URL,
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        cwd: String,
        agentLifecycle: String,
        lastBody: String
    ) throws {
        let now = Date().timeIntervalSince1970
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": cwd,
                    "isRestorable": true,
                    "startedAt": now,
                    "updatedAt": now,
                    "agentLifecycle": agentLifecycle,
                    "lastSubtitle": "Permission",
                    "lastBody": lastBody,
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: store, options: [.sortedKeys])
        try data.write(to: storeURL)
    }
}
