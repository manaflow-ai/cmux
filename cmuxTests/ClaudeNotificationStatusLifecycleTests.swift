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

    /// Runs the Claude `notification` hook with a given message and returns the
    /// socket commands it emitted.
    private func runClaudeNotification(
        name: String,
        ttyName: String,
        message: String
    ) throws -> [String] {
        let harness = ClaudeHookSurfaceResolutionSwiftTests()
        let context = try harness.makeClaudeHookContext(name: name)
        defer { context.cleanup() }

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
            storeURL: context.root.appendingPathComponent("claude-hook-sessions.json")
        )
        environment["CMUX_CLAUDE_PID"] = "42424"

        let result = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "notification"],
            environment: environment,
            standardInput: #"{"session_id":"\#(name)-session","cwd":"\#(context.root.path)","hook_event_name":"Notification","message":"\#(message)"}"#,
            timeout: 5
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        harness.assertSuccessfulHook(result)
        return context.state.snapshot()
    }
}
