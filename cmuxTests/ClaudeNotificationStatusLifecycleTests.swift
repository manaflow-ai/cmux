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

    @Test func plainWaitingNotificationLeavesLifecycleUntouched() throws {
        // Regression for the original bug: the routine "waiting for input" reminder
        // fires after Claude has gone idle. It must NOT clobber the Stop hook's `.idle`
        // back to `.needsInput`. The notification is not an authoritative idle source
        // either, so it emits no lifecycle command at all — the Stop hook's idle stays
        // and the pane hibernates.
        let snapshot = try runClaudeNotification(
            name: "claude-notify-waiting",
            ttyName: "ttys-claude-notify-waiting",
            message: "Claude is waiting for your input"
        )
        #expect(
            !snapshot.contains { $0.hasPrefix("set_agent_lifecycle claude_code") },
            "A plain waiting reminder must not emit any lifecycle command (leave Stop's idle), saw \(snapshot)"
        )
    }

    @Test func permissionNotificationSetsNeedsInput() throws {
        // A genuine permission / approval prompt is a real blocking state the
        // notification owns, so it asserts `.needsInput` to keep the pane live.
        let snapshot = try runClaudeNotification(
            name: "claude-notify-permission",
            ttyName: "ttys-claude-notify-permission",
            message: "Claude needs your permission to use Bash"
        )
        #expect(
            snapshot.contains { $0.hasPrefix("set_agent_lifecycle claude_code needsInput ") },
            "Expected a permission notification to set needsInput lifecycle, saw \(snapshot)"
        )
    }

    @Test func notificationNeverForcesIdleFromText() throws {
        // Single source of truth: idle comes only from the Stop hook, never from
        // ambiguous notification prose. No notification text may resolve to `.idle`.
        for message in [
            "Claude is waiting for your input",
            "Claude is waiting for your response",
            "Please confirm to continue",
            "Task completed",
        ] {
            let snapshot = try runClaudeNotification(
                name: "claude-notify-noidle",
                ttyName: "ttys-claude-notify-noidle",
                message: message
            )
            #expect(
                !snapshot.contains { $0.hasPrefix("set_agent_lifecycle claude_code idle") },
                "Notification text \(message.debugDescription) must never force idle, saw \(snapshot)"
            )
        }
    }

    @Test func deferredBlockingWaitingNotificationDoesNotDowngradeToIdle() throws {
        // AskUserQuestion / ExitPlanMode record `.needsInput` in PreToolUse, then defer
        // the bell to a Notification whose text can read "waiting for your response".
        // Because the notification leaves the lifecycle untouched (it is not blocking
        // text), the recorded `.needsInput` survives; it is never downgraded to idle.
        let snapshot = try runClaudeNotification(
            name: "claude-notify-deferred-block",
            ttyName: "ttys-claude-notify-deferred-block",
            message: "Claude is waiting for your response",
            seededLifecycle: "needsInput",
            seededBody: "Which option do you want?"
        )
        #expect(
            !snapshot.contains { $0.hasPrefix("set_agent_lifecycle claude_code idle") },
            "A pending blocking prompt must not be downgraded to idle by waiting text, saw \(snapshot)"
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
