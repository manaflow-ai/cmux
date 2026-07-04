import Dispatch
import Foundation
import Testing

extension ClaudeHookSurfaceResolutionSwiftTests {
    @Test func claudeNoFlickerSessionStartMarksWorkspaceRunning() throws {
        let context = try makeClaudeHookContext(name: "claude-noflicker-running")
        defer { context.cleanup() }

        let serverHandled = startClaudeNoFlickerServer(context: context, name: "running")
        let result = runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "session-start"],
            environment: claudeNoFlickerEnvironment(context: context),
            standardInput: #"{"session_id":"fullscreen-session","source":"startup","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#,
            timeout: 5
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        assertSuccessfulHook(result)

        let commands = context.state.snapshot()
        #expect(
            commands.contains {
                $0.hasPrefix("set_status claude_code Running --icon=bolt.fill --color=#4C8DFF --tab=\(context.workspaceId)")
                    && $0.contains("--panel=\(context.surfaceId)")
            },
            "Expected CLAUDE_CODE_NO_FLICKER startup SessionStart to mark Claude running, saw \(commands)"
        )
        #expect(
            !commands.contains { $0.contains(#""method":"surface.resume.set""#) },
            "CLAUDE_CODE_NO_FLICKER startup SessionStart must not publish a resume binding before the first prompt, saw \(commands)"
        )

        let record = try readClaudeNoFlickerHookSession("fullscreen-session", context: context)
        #expect(record["isRestorable"] as? Bool == false)
        #expect(record["agentLifecycle"] as? String == "running")
    }

    @Test func claudeNoFlickerSessionStartIgnoresNonStartupSources() throws {
        let scenarios = [
            (
                name: "resume",
                sessionId: "noflicker-resume-session",
                sourceJSON: #""source":"resume","#
            ),
            (
                name: "missing-source",
                sessionId: "noflicker-missing-source-session",
                sourceJSON: ""
            ),
        ]

        for scenario in scenarios {
            let context = try makeClaudeHookContext(name: "claude-noflicker-\(scenario.name)")
            defer { context.cleanup() }

            let serverHandled = startClaudeNoFlickerServer(context: context, name: scenario.name)
            let result = runProcess(
                executablePath: context.cliPath,
                arguments: ["hooks", "claude", "session-start"],
                environment: claudeNoFlickerEnvironment(context: context),
                standardInput: #"{"session_id":"\#(scenario.sessionId)",\#(scenario.sourceJSON)"cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#,
                timeout: 5
            )

            #expect(serverHandled.wait(timeout: .now() + 5) == .success)
            assertSuccessfulHook(result)

            let commands = context.state.snapshot()
            #expect(
                !commands.contains { $0.hasPrefix("set_status claude_code Running ") },
                "Expected \(scenario.name) SessionStart not to mark Claude running, saw \(commands)"
            )
            #expect(
                !commands.contains { $0 == "clear_notifications --tab=\(context.workspaceId)" },
                "Expected \(scenario.name) SessionStart not to clear notifications, saw \(commands)"
            )
            #expect(
                !commands.contains { $0.contains(#""method":"surface.resume.set""#) },
                "Expected \(scenario.name) SessionStart not to publish a resume binding before the first prompt, saw \(commands)"
            )

            let record = try readClaudeNoFlickerHookSession(scenario.sessionId, context: context)
            #expect(record["isRestorable"] as? Bool == false)
            #expect(record["agentLifecycle"] as? String != "running")
        }
    }

    private func startClaudeNoFlickerServer(
        context: ClaudeHookContext,
        name: String
    ) -> DispatchSemaphore {
        startClaudeSurfaceResolutionServer(
            context: context,
            surfaces: [(context.surfaceId, "surface:1", true)],
            ttyName: "ttys-claude-noflicker-\(name)",
            ttySurfaceId: context.surfaceId
        )
    }

    private func claudeNoFlickerEnvironment(context: ClaudeHookContext) -> [String: String] {
        [
            "HOME": context.root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CMUX_SOCKET_PATH": context.socketPath,
            "CMUX_WORKSPACE_ID": context.workspaceId,
            "CMUX_SURFACE_ID": context.surfaceId,
            "CMUX_CLAUDE_HOOK_STATE_PATH": context.root.appendingPathComponent("claude-hook-sessions.json").path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CMUX_CLAUDE_HOOK_SENTRY_DISABLED": "1",
            "CLAUDE_CODE_NO_FLICKER": "1",
        ]
    }

    private func readClaudeNoFlickerHookSession(
        _ sessionId: String,
        context: ClaudeHookContext
    ) throws -> [String: Any] {
        let stateURL = context.root.appendingPathComponent("claude-hook-sessions.json")
        let state = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        )
        let sessions = try #require(state["sessions"] as? [String: Any])
        return try #require(sessions[sessionId] as? [String: Any])
    }
}
