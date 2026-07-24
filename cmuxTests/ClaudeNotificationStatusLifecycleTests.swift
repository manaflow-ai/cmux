import Dispatch
import Foundation
import Testing

@Suite(.serialized)
struct ClaudeNotificationStatusLifecycleTests {
    @Test func claudePermissionPromptStatusCarriesPIDForStaleSweep() throws {
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
            standardInput: #"{"session_id":"claude-notify-pid-session","cwd":"\#(context.root.path)","hook_event_name":"Notification","message":"Claude needs your permission","notification_type":"permission_prompt"}"#,
            timeout: 5
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        harness.assertSuccessfulHook(result)

        let commands = context.state.snapshot()
        _ = try #require(
            commands.first {
                $0.hasPrefix("set_status claude_code Needs input ")
                    && $0.contains("--tab=\(context.workspaceId)")
                    && $0.contains("--panel=\(context.surfaceId)")
            },
            "Expected Claude notification to set a Needs input status, saw \(commands)"
        )
        #expect(
            commands.contains {
                $0.hasPrefix("set_agent_pid claude_code.claude-notify-pid-session \(claudePID) ")
                    && $0.contains("--tab=\(context.workspaceId)")
                    && $0.contains("--panel=\(context.surfaceId)")
            },
            "Claude notification status must be backed by its exact runtime generation so stale cleanup cannot clear a replacement; commands=\(commands)"
        )
    }
}
