import XCTest

extension CLINotifyProcessIntegrationRegressionTests {
    func testManagedCodexSubagentSessionStartDoesNotMutateVisibleLifecycle() throws {
        let context = try makeClaudeHookContext(name: "codex-managed-start-lifecycle-guard")
        defer { context.cleanup() }

        let sessionId = "managed-child-session-start"
        startAgentHookMockServerAccepting(context: context, connectionLimit: 16)
        let result = runCodexHook(
            context: context,
            subcommand: "session-start",
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#,
            extraEnvironment: codexLaunchEnvironment(context: context, sessionId: sessionId).merging([
                "CMUX_AGENT_MANAGED_SUBAGENT": "1",
                "CMUX_CODEX_TEAMS_THREAD_ID": "child-thread",
                "CMUX_CODEX_TEAMS_PARENT_THREAD_ID": "root-thread",
                "CMUX_CODEX_TEAMS_DEPTH": "1",
            ], uniquingKeysWith: { _, new in new })
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertFalse(
            context.state.commands.contains { $0.hasPrefix("set_agent_lifecycle ") },
            "Managed subagent SessionStart must not overwrite the root lifecycle, saw \(context.state.commands)"
        )
        XCTAssertFalse(
            context.state.commands.contains { $0.hasPrefix("set_agent_pid ") },
            "Managed subagent SessionStart must not overwrite the root PID, saw \(context.state.commands)"
        )
        XCTAssertFalse(
            context.state.commands.contains { self.jsonObject($0)?["method"] as? String == "surface.resume.set" },
            "Managed subagent SessionStart must not overwrite the root resume binding, saw \(context.state.commands)"
        )
    }
}
