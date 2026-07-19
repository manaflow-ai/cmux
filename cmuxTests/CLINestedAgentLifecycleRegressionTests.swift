import Foundation
import Testing

@Suite(.serialized)
struct CLINestedAgentLifecycleRegressionTests {
    @Test func managedCodexSubagentSessionStartDoesNotMutateVisibleLifecycle() throws {
        let harness = ClaudeHookSurfaceResolutionSwiftTests()
        let context = try harness.makeClaudeHookContext(name: "codex-managed-start-lifecycle-guard")
        defer { context.cleanup() }

        let sessionId = "managed-child-session-start"
        let ttyName = "ttys-managed-child"
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
            storeURL: context.root.appendingPathComponent("codex-hook-sessions.json")
        )
        environment.merge([
            "CMUX_AGENT_HOOK_STATE_DIR": context.root.path,
            "CMUX_AGENT_LAUNCH_KIND": "codex",
            "CMUX_AGENT_LAUNCH_EXECUTABLE": "/usr/local/bin/codex",
            "CMUX_AGENT_LAUNCH_CWD": context.root.path,
            "CMUX_AGENT_LAUNCH_ARGV_B64": encodedArguments(["/usr/local/bin/codex", "--model", "gpt-5.4"]),
            "CMUX_AGENT_MANAGED_SUBAGENT": "1",
            "CMUX_CODEX_TEAMS_THREAD_ID": "child-thread",
            "CMUX_CODEX_TEAMS_PARENT_THREAD_ID": "root-thread",
            "CMUX_CODEX_TEAMS_DEPTH": "1",
        ], uniquingKeysWith: { _, new in new })
        let result = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "codex", "session-start"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#,
            timeout: 5
        )

        #expect(handled.wait(timeout: .now() + 5) == .success)
        harness.assertSuccessfulHook(result)
        let commands = context.state.snapshot()
        #expect(
            !commands.contains { $0.hasPrefix("set_agent_lifecycle ") },
            "Managed subagent SessionStart must not overwrite the root lifecycle, saw \(commands)"
        )
        #expect(
            !commands.contains { $0.hasPrefix("set_agent_pid ") },
            "Managed subagent SessionStart must not overwrite the root PID, saw \(commands)"
        )
        #expect(
            !commands.contains { jsonObject($0)?["method"] as? String == "surface.resume.set" },
            "Managed subagent SessionStart must not overwrite the root resume binding, saw \(commands)"
        )
    }

    private func encodedArguments(_ arguments: [String]) -> String {
        arguments.reduce(into: Data()) { data, argument in
            data.append(contentsOf: argument.utf8)
            data.append(0)
        }.base64EncodedString()
    }

    private func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
