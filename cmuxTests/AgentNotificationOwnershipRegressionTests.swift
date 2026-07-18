import Dispatch
import Foundation
import Testing

@Suite(.serialized)
struct AgentNotificationOwnershipRegressionTests {
    @Test func debugEnvironmentCannotPromoteAManagedChild() throws {
        let result = try runManagedCodexHook(
            name: "codex-child-debug-override",
            subcommand: "session-start",
            input: #"{"session_id":"child-debug-override","cwd":"/tmp/x","hook_event_name":"SessionStart"}"#,
            suppressNotifications: nil,
            testRootVisibleMutations: true
        )

        expectNoVisibleOwnership(result.commands)
    }

    @Test func managedCodexStopCanNotifyWithoutTakingVisibleOwnership() throws {
        let result = try runManagedCodexHook(
            name: "codex-child-stop-opt-in",
            subcommand: "stop",
            input: #"{"session_id":"child-stop","cwd":"/tmp/x","hook_event_name":"Stop","last_assistant_message":"child done"}"#,
            suppressNotifications: false
        )

        #expect(result.commands.contains { $0.hasPrefix("notify_target_async \(result.workspaceId) \(result.surfaceId) Codex|") })
        expectNoVisibleOwnership(result.commands)
    }

    @Test func managedCodexNotificationCanDeliverWithoutUpdatingRootState() throws {
        let result = try runManagedCodexHook(
            name: "codex-child-alert-opt-in",
            subcommand: "notification",
            input: #"{"session_id":"child-alert","cwd":"/tmp/x","hook_event_name":"Notification","message":"child needs input","notification_type":"permission_prompt"}"#,
            suppressNotifications: false
        )

        #expect(result.commands.contains { $0.hasPrefix("notify_target_async \(result.workspaceId) \(result.surfaceId) Codex|") })
        expectNoVisibleOwnership(result.commands)
    }

    @Test func managedCodexNotificationIsSuppressedByDefault() throws {
        let result = try runManagedCodexHook(
            name: "codex-child-alert-default",
            subcommand: "notification",
            input: #"{"session_id":"child-alert-default","cwd":"/tmp/x","hook_event_name":"Notification","message":"child needs input","notification_type":"permission_prompt"}"#,
            suppressNotifications: nil
        )

        #expect(!result.commands.contains { $0.hasPrefix("notify_target") })
        expectNoVisibleOwnership(result.commands)
    }

    private func runManagedCodexHook(
        name: String,
        subcommand: String,
        input: String,
        suppressNotifications: Bool?,
        testRootVisibleMutations: Bool = false
    ) throws -> (commands: [String], workspaceId: String, surfaceId: String) {
        let harness = ClaudeHookSurfaceResolutionSwiftTests()
        let context = try harness.makeClaudeHookContext(name: name)
        defer { context.cleanup() }
        let ttyName = "ttys-\(name)"
        let handled = harness.startClaudeSurfaceResolutionServer(
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
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = context.root.path
        environment["CMUX_AGENT_MANAGED_SUBAGENT"] = "1"
        environment["CMUX_CODEX_TEAMS_THREAD_ID"] = "child-thread"
        environment["CMUX_CODEX_TEAMS_PARENT_THREAD_ID"] = "root-thread"
        environment["CMUX_CODEX_TEAMS_DEPTH"] = "1"
        if let suppressNotifications {
            environment["CMUX_SUPPRESS_SUBAGENT_NOTIFICATIONS"] = suppressNotifications ? "1" : "0"
        }
        if testRootVisibleMutations {
            environment["CMUX_TEST_AGENT_ROOT_VISIBLE_MUTATIONS"] = "1"
        }
        let process = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "codex", subcommand],
            environment: environment,
            standardInput: input,
            timeout: 5
        )

        #expect(handled.wait(timeout: .now() + 5) == .success)
        #expect(!process.timedOut, Comment(rawValue: process.stderr))
        #expect(process.status == 0, Comment(rawValue: process.stderr))
        return (context.state.snapshot(), context.workspaceId, context.surfaceId)
    }

    private func expectNoVisibleOwnership(_ commands: [String]) {
        #expect(!commands.contains { command in
            command.hasPrefix("set_status codex ")
                || command.hasPrefix("set_agent_lifecycle codex ")
                || (jsonObject(command)?["method"] as? String) == "surface.resume.set"
        })
    }

    private func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
