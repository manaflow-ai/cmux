import Dispatch
import Foundation
import Darwin
import Testing

@Suite(.serialized)
struct ClaudeHookSurfaceResolutionSwiftTests {
    @Test func claudeSessionStartOverridesLeakedEnvSurfaceWithTTYBinding() throws {
        let context = try makeClaudeHookContext(name: "claude-leaked-surface")
        defer { context.cleanup() }

        let leakedSurfaceId = context.surfaceId
        let ttySurfaceId = "33333333-3333-3333-3333-333333333333"
        let ttyName = "ttys-claude-leaked-surface"
        let sessionId = "claude-leaked-surface-session"

        let serverHandled = startClaudeSurfaceResolutionServer(
            context: context,
            surfaces: [
                (leakedSurfaceId, "surface:1", true),
                (ttySurfaceId, "surface:2", false),
            ],
            ttyName: ttyName,
            ttySurfaceId: ttySurfaceId
        )

        let environment = [
            "HOME": context.root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CMUX_SOCKET_PATH": context.socketPath,
            "CMUX_WORKSPACE_ID": context.workspaceId,
            "CMUX_SURFACE_ID": leakedSurfaceId,
            "CMUX_CLI_TTY_NAME": ttyName,
            "CMUX_CLAUDE_PID": "42424",
            "CMUX_CLAUDE_HOOK_STATE_PATH": context.root.appendingPathComponent("claude-hook-sessions.json").path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CMUX_CLAUDE_HOOK_SENTRY_DISABLED": "1",
            "CMUX_AGENT_LAUNCH_KIND": "claude",
            "CMUX_AGENT_LAUNCH_EXECUTABLE": "/usr/local/bin/claude",
            "CMUX_AGENT_LAUNCH_CWD": context.root.path,
            "CMUX_AGENT_LAUNCH_ARGV_B64": base64NULSeparated(["/usr/local/bin/claude"]),
        ]

        let result = runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "session-start"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","source":"clear","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#,
            timeout: 5
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        assertSuccessfulHook(result)

        let request = try #require(
            resumeBindingRequests(in: context).last,
            "Expected Claude SessionStart to publish a resume binding, saw \(context.state.snapshot())"
        )
        #expect(
            request["surface_id"] as? String == ttySurfaceId,
            "Claude must persist the agent TTY surface, not the leaked ambient CMUX_SURFACE_ID; params=\(request)"
        )
        #expect(
            context.state.snapshot().contains {
                $0.hasPrefix("set_status claude_code Running ")
                    && $0.contains("--panel=\(ttySurfaceId)")
            },
            "Claude visible status should also target the TTY surface, saw \(context.state.snapshot())"
        )
        #expect(
            !context.state.snapshot().contains { $0.contains(#""method":"system.top""#) },
            "Claude hooks with a TTY binding must not do a process snapshot; saw \(context.state.snapshot())"
        )
    }

    @Test func claudeSessionStartOverridesLeakedEnvWorkspaceAndSurfaceWithTTYBinding() throws {
        let context = try makeClaudeHookContext(name: "claude-leaked-workspace")
        defer { context.cleanup() }

        let leakedWorkspaceId = context.workspaceId
        let leakedSurfaceId = context.surfaceId
        let ttyWorkspaceId = "77777777-7777-7777-7777-777777777777"
        let ttySurfaceId = "33333333-3333-3333-3333-333333333333"
        let ttyName = "ttys-claude-leaked-workspace"
        let sessionId = "claude-leaked-workspace-session"

        let serverHandled = startClaudeSurfaceResolutionServer(
            context: context,
            surfaces: [(leakedSurfaceId, "surface:1", true)],
            ttyName: ttyName,
            ttySurfaceId: ttySurfaceId,
            ttyWorkspaceId: ttyWorkspaceId,
            surfacesByWorkspace: [
                leakedWorkspaceId: [(leakedSurfaceId, "surface:1", true)],
                ttyWorkspaceId: [(ttySurfaceId, "surface:2", false)],
            ]
        )

        let environment = [
            "HOME": context.root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CMUX_SOCKET_PATH": context.socketPath,
            "CMUX_WORKSPACE_ID": leakedWorkspaceId,
            "CMUX_SURFACE_ID": leakedSurfaceId,
            "CMUX_CLI_TTY_NAME": ttyName,
            "CMUX_CLAUDE_HOOK_STATE_PATH": context.root.appendingPathComponent("claude-hook-sessions.json").path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CMUX_CLAUDE_HOOK_SENTRY_DISABLED": "1",
            "CMUX_AGENT_LAUNCH_KIND": "claude",
            "CMUX_AGENT_LAUNCH_EXECUTABLE": "/usr/local/bin/claude",
            "CMUX_AGENT_LAUNCH_CWD": context.root.path,
            "CMUX_AGENT_LAUNCH_ARGV_B64": base64NULSeparated(["/usr/local/bin/claude"]),
        ]

        let result = runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "session-start"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","source":"clear","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#,
            timeout: 5
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        assertSuccessfulHook(result)

        let request = try #require(
            resumeBindingRequests(in: context).last,
            "Expected Claude SessionStart to publish a resume binding, saw \(context.state.snapshot())"
        )
        #expect(
            request["workspace_id"] as? String == ttyWorkspaceId,
            "Claude must persist the agent TTY workspace, not the leaked ambient CMUX_WORKSPACE_ID; params=\(request)"
        )
        #expect(
            request["surface_id"] as? String == ttySurfaceId,
            "Claude must persist the agent TTY surface, not the leaked ambient CMUX_SURFACE_ID; params=\(request)"
        )
        #expect(
            context.state.snapshot().contains {
                $0.hasPrefix("set_status claude_code Running ")
                    && $0.contains("--tab=\(ttyWorkspaceId)")
                    && $0.contains("--panel=\(ttySurfaceId)")
            },
            "Claude visible status should target the TTY workspace and surface, saw \(context.state.snapshot())"
        )
    }

    @Test func claudeSessionStartOverridesLeakedEnvWithClaudePIDBindingWhenTTYMissing() throws {
        let context = try makeClaudeHookContext(name: "claude-pid-surface")
        defer { context.cleanup() }

        let leakedWorkspaceId = context.workspaceId
        let leakedSurfaceId = context.surfaceId
        let pidWorkspaceId = "77777777-7777-7777-7777-777777777777"
        let pidSurfaceId = "33333333-3333-3333-3333-333333333333"
        let claudePID = 42_424
        let socketPassword = "claude-pid-secret"
        let sessionId = "claude-pid-surface-session"

        let serverHandled = startClaudeSurfaceResolutionServer(
            context: context,
            surfaces: [(leakedSurfaceId, "surface:1", true)],
            ttyName: "ttys-unused-claude-pid-surface",
            ttySurfaceId: leakedSurfaceId,
            surfacesByWorkspace: [
                leakedWorkspaceId: [(leakedSurfaceId, "surface:1", true)],
                pidWorkspaceId: [(pidSurfaceId, "surface:2", false)],
            ],
            agentPID: claudePID,
            agentPIDWorkspaceId: pidWorkspaceId,
            agentPIDSurfaceId: pidSurfaceId,
            requiredSocketPassword: socketPassword
        )

        let environment = [
            "HOME": context.root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CMUX_SOCKET_PATH": context.socketPath,
            "CMUX_SOCKET_PASSWORD": socketPassword,
            "CMUX_WORKSPACE_ID": leakedWorkspaceId,
            "CMUX_SURFACE_ID": leakedSurfaceId,
            "CMUX_CLAUDE_PID": "\(claudePID)",
            "CMUX_CLAUDE_HOOK_STATE_PATH": context.root.appendingPathComponent("claude-hook-sessions.json").path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CMUX_CLAUDE_HOOK_SENTRY_DISABLED": "1",
            "CMUX_AGENT_LAUNCH_KIND": "claude",
            "CMUX_AGENT_LAUNCH_EXECUTABLE": "/usr/local/bin/claude",
            "CMUX_AGENT_LAUNCH_CWD": context.root.path,
            "CMUX_AGENT_LAUNCH_ARGV_B64": base64NULSeparated(["/usr/local/bin/claude"]),
        ]

        let result = runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "session-start"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","source":"clear","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#,
            timeout: 5
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        assertSuccessfulHook(result)

        let request = try #require(
            resumeBindingRequests(in: context).last,
            "Expected Claude SessionStart to publish a resume binding, saw \(context.state.snapshot())"
        )
        #expect(
            request["workspace_id"] as? String == pidWorkspaceId,
            "Claude PID binding must beat leaked ambient CMUX_WORKSPACE_ID when no TTY marker exists; params=\(request)"
        )
        #expect(
            request["surface_id"] as? String == pidSurfaceId,
            "Claude PID binding must beat leaked ambient CMUX_SURFACE_ID when no TTY marker exists; params=\(request)"
        )
        #expect(
            context.state.snapshot().contains("auth \(socketPassword)"),
            "Claude PID probe must authenticate before reading system.top on password-protected sockets"
        )
    }

    @Test func claudeSessionStartFallsBackToClaudePIDWhenTTYBindingIsStale() throws {
        let context = try makeClaudeHookContext(name: "claude-stale-tty-pid")
        defer { context.cleanup() }

        let leakedWorkspaceId = context.workspaceId
        let leakedSurfaceId = context.surfaceId
        let staleTTYWorkspaceId = "66666666-6666-6666-6666-666666666666"
        let staleTTYSurfaceId = "55555555-5555-5555-5555-555555555555"
        let staleTTYWorkspaceFocusedSurfaceId = "44444444-4444-4444-4444-444444444444"
        let pidWorkspaceId = "77777777-7777-7777-7777-777777777777"
        let pidSurfaceId = "33333333-3333-3333-3333-333333333333"
        let ttyName = "ttys-claude-stale-tty-pid"
        let claudePID = 42_425
        let socketPassword = "claude-stale-tty-pid-secret"
        let sessionId = "claude-stale-tty-pid-session"

        let serverHandled = startClaudeSurfaceResolutionServer(
            context: context,
            surfaces: [(leakedSurfaceId, "surface:1", true)],
            ttyName: ttyName,
            ttySurfaceId: staleTTYSurfaceId,
            ttyWorkspaceId: staleTTYWorkspaceId,
            surfacesByWorkspace: [
                leakedWorkspaceId: [(leakedSurfaceId, "surface:1", true)],
                staleTTYWorkspaceId: [(staleTTYWorkspaceFocusedSurfaceId, "surface:2", true)],
                pidWorkspaceId: [(pidSurfaceId, "surface:3", false)],
            ],
            agentPID: claudePID,
            agentPIDWorkspaceId: pidWorkspaceId,
            agentPIDSurfaceId: pidSurfaceId,
            requiredSocketPassword: socketPassword
        )

        let environment = [
            "HOME": context.root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CMUX_SOCKET_PATH": context.socketPath,
            "CMUX_SOCKET_PASSWORD": socketPassword,
            "CMUX_WORKSPACE_ID": leakedWorkspaceId,
            "CMUX_SURFACE_ID": leakedSurfaceId,
            "CMUX_CLI_TTY_NAME": ttyName,
            "CMUX_CLAUDE_PID": "\(claudePID)",
            "CMUX_CLAUDE_HOOK_STATE_PATH": context.root.appendingPathComponent("claude-hook-sessions.json").path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CMUX_CLAUDE_HOOK_SENTRY_DISABLED": "1",
            "CMUX_AGENT_LAUNCH_KIND": "claude",
            "CMUX_AGENT_LAUNCH_EXECUTABLE": "/usr/local/bin/claude",
            "CMUX_AGENT_LAUNCH_CWD": context.root.path,
            "CMUX_AGENT_LAUNCH_ARGV_B64": base64NULSeparated(["/usr/local/bin/claude"]),
        ]

        let result = runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "session-start"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","source":"clear","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#,
            timeout: 5
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        assertSuccessfulHook(result)

        let request = try #require(
            resumeBindingRequests(in: context).last,
            "Expected Claude SessionStart to publish a resume binding, saw \(context.state.snapshot())"
        )
        #expect(
            request["workspace_id"] as? String == pidWorkspaceId,
            "Stale TTY binding must fall through to the Claude PID workspace, not leaked ambient env; params=\(request)"
        )
        #expect(
            request["surface_id"] as? String == pidSurfaceId,
            "Stale TTY binding must fall through to the Claude PID surface, not leaked ambient env; params=\(request)"
        )
        #expect(
            context.state.snapshot().contains { $0.contains(#""method":"system.top""#) },
            "Stale TTY binding must not suppress the Claude PID process lookup; saw \(context.state.snapshot())"
        )
        #expect(
            context.state.snapshot().contains("auth \(socketPassword)"),
            "Claude PID fallback must authenticate before reading system.top on password-protected sockets"
        )
    }

    @Test func claudeSessionStartIgnoresStaleTTYWorkspaceWhenBoundSurfaceIsGone() throws {
        let context = try makeClaudeHookContext(name: "claude-stale-tty-workspace")
        defer { context.cleanup() }

        let ttyWorkspaceId = "77777777-7777-7777-7777-777777777777"
        let staleTTYSurfaceId = "33333333-3333-3333-3333-333333333333"
        let ttyWorkspaceFocusedSurfaceId = "44444444-4444-4444-4444-444444444444"
        let ttyName = "ttys-claude-stale-workspace"
        let sessionId = "claude-stale-tty-workspace-session"

        let serverHandled = startClaudeSurfaceResolutionServer(
            context: context,
            surfaces: [(context.surfaceId, "surface:1", true)],
            ttyName: ttyName,
            ttySurfaceId: staleTTYSurfaceId,
            ttyWorkspaceId: ttyWorkspaceId,
            surfacesByWorkspace: [
                context.workspaceId: [(context.surfaceId, "surface:1", true)],
                ttyWorkspaceId: [(ttyWorkspaceFocusedSurfaceId, "surface:2", true)],
            ]
        )

        let environment = [
            "HOME": context.root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CMUX_SOCKET_PATH": context.socketPath,
            "CMUX_WORKSPACE_ID": context.workspaceId,
            "CMUX_SURFACE_ID": context.surfaceId,
            "CMUX_CLI_TTY_NAME": ttyName,
            "CMUX_CLAUDE_HOOK_STATE_PATH": context.root.appendingPathComponent("claude-hook-sessions.json").path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CMUX_CLAUDE_HOOK_SENTRY_DISABLED": "1",
            "CMUX_AGENT_LAUNCH_KIND": "claude",
            "CMUX_AGENT_LAUNCH_EXECUTABLE": "/usr/local/bin/claude",
            "CMUX_AGENT_LAUNCH_CWD": context.root.path,
            "CMUX_AGENT_LAUNCH_ARGV_B64": base64NULSeparated(["/usr/local/bin/claude"]),
        ]

        let result = runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "session-start"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","source":"clear","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#,
            timeout: 5
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        assertSuccessfulHook(result)

        let request = try #require(
            resumeBindingRequests(in: context).last,
            "Expected Claude SessionStart to publish a resume binding, saw \(context.state.snapshot())"
        )
        #expect(
            request["workspace_id"] as? String == context.workspaceId,
            "Stale TTY workspace must not beat valid ambient CMUX_WORKSPACE_ID; params=\(request)"
        )
        #expect(
            request["surface_id"] as? String == context.surfaceId,
            "Stale TTY workspace must not fall through to its focused surface; params=\(request)"
        )
        #expect(
            context.state.snapshot().contains {
                $0.hasPrefix("set_status claude_code Running ")
                    && $0.contains("--tab=\(context.workspaceId)")
                    && $0.contains("--panel=\(context.surfaceId)")
            },
            "Claude visible status should stay on the valid ambient workspace and surface, saw \(context.state.snapshot())"
        )
    }

    @Test func claudeExplicitSurfaceOverridesMappedSessionAndTTYBinding() throws {
        let explicitSurfaceId = "33333333-3333-3333-3333-333333333333"
        let ttySurfaceId = "44444444-4444-4444-4444-444444444444"
        try assertPromptSubmitRoutes(
            name: "claude-explicit-surface",
            sessionId: "claude-explicit-surface-session",
            explicitSurfaceId: explicitSurfaceId,
            ttyName: "ttys-claude-explicit-surface",
            ttySurfaceId: ttySurfaceId,
            surfaces: { mappedSurfaceId in [
                (mappedSurfaceId, "surface:1", true),
                (explicitSurfaceId, "surface:2", false),
                (ttySurfaceId, "surface:3", false),
            ] },
            expectedSurfaceId: { _ in explicitSurfaceId },
            requestMessage: "Explicit --surface must beat both mapped session state and TTY binding"
        )
    }

    @Test func claudeMappedSessionOverridesTTYBindingWithoutExplicitSurface() throws {
        let ttySurfaceId = "44444444-4444-4444-4444-444444444444"
        try assertPromptSubmitRoutes(
            name: "claude-mapped-session-surface",
            sessionId: "claude-mapped-session-surface-session",
            ttyName: "ttys-claude-mapped-session-surface",
            ttySurfaceId: ttySurfaceId,
            surfaces: { mappedSurfaceId in [
                (mappedSurfaceId, "surface:1", true),
                (ttySurfaceId, "surface:2", false),
            ] },
            expectedSurfaceId: { mappedSurfaceId in mappedSurfaceId },
            requestMessage: "Mapped Claude session state must beat leaked TTY binding when --surface is absent"
        )
    }

    @Test func claudeInvalidExplicitSurfaceFallsBackToMappedSession() throws {
        let staleExplicitSurfaceId = "55555555-5555-5555-5555-555555555555"
        let ttySurfaceId = "44444444-4444-4444-4444-444444444444"
        try assertPromptSubmitRoutes(
            name: "claude-invalid-explicit-surface",
            sessionId: "claude-invalid-explicit-surface-session",
            explicitSurfaceId: staleExplicitSurfaceId,
            ttyName: "ttys-claude-invalid-explicit-surface",
            ttySurfaceId: ttySurfaceId,
            surfaces: { mappedSurfaceId in [
                (mappedSurfaceId, "surface:1", true),
                (ttySurfaceId, "surface:2", false),
            ] },
            expectedSurfaceId: { mappedSurfaceId in mappedSurfaceId },
            requestMessage: "Invalid explicit --surface should fall back to the mapped session, not TTY/default"
        )
    }

    @Test func geminiIdlessAfterAgentMarksOriginalSessionIdle() throws {
        let context = try makeClaudeHookContext(name: "gemini-idless-stop")
        defer { context.cleanup() }

        _ = startGeminiSurfaceResolutionServer(context: context)
        let sessionId = "gemini-session-with-idless-afteragent"
        let environment = geminiHookEnvironment(context: context)

        assertSuccessfulHook(runGeminiHook(
            context: context,
            subcommand: "session-start",
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#,
            environment: environment
        ))
        assertSuccessfulHook(runGeminiHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"cwd":"\#(context.root.path)","hook_event_name":"BeforeAgent","prompt":"fix it"}"#,
            environment: environment
        ))

        let stopCommandStart = context.state.snapshot().count
        assertSuccessfulHook(runGeminiHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"cwd":"\#(context.root.path)","hook_event_name":"AfterAgent","last_assistant_message":"done"}"#,
            environment: environment
        ))

        let stopCommands = Array(context.state.snapshot().dropFirst(stopCommandStart))
        #expect(
            stopCommands.contains {
                $0.hasPrefix("set_agent_lifecycle gemini idle --tab=\(context.workspaceId)")
                    && $0.contains("--panel=\(context.surfaceId)")
            },
            "Gemini AfterAgent must emit idle for hibernation, saw \(stopCommands)"
        )

        let sessions = try readGeminiSessions(context: context)
        let original = try #require(sessions[sessionId])
        #expect(original["agentLifecycle"] as? String == "idle")
        #expect(original["lastNotificationStatus"] as? String == "idle")
        #expect(
            sessions[context.surfaceId] == nil,
            "Id-less Gemini turn hooks must resolve to the original session record instead of creating a surface-id fallback record"
        )
    }

    @Test func geminiIdlessAfterAgentPrefersNewestStartedSessionOverLateOlderWrite() throws {
        let context = try makeClaudeHookContext(name: "gemini-idless-stop-prefers-new-start")
        defer { context.cleanup() }

        _ = startGeminiSurfaceResolutionServer(context: context)
        let olderSessionId = "gemini-older-session"
        let newerSessionId = "gemini-newer-session"
        let environment = geminiHookEnvironment(context: context)

        assertSuccessfulHook(runGeminiHook(
            context: context,
            subcommand: "session-start",
            standardInput: #"{"session_id":"\#(olderSessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#,
            environment: environment
        ))
        assertSuccessfulHook(runGeminiHook(
            context: context,
            subcommand: "session-start",
            standardInput: #"{"session_id":"\#(newerSessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#,
            environment: environment
        ))
        assertSuccessfulHook(runGeminiHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(olderSessionId)","cwd":"\#(context.root.path)","hook_event_name":"AfterAgent","last_assistant_message":"older done"}"#,
            environment: environment
        ))
        assertSuccessfulHook(runGeminiHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"cwd":"\#(context.root.path)","hook_event_name":"AfterAgent","last_assistant_message":"newer done"}"#,
            environment: environment
        ))

        let sessions = try readGeminiSessions(context: context)
        let newer = try #require(sessions[newerSessionId])
        #expect(newer["agentLifecycle"] as? String == "idle")
        #expect(newer["lastNotificationStatus"] as? String == "idle")
        #expect(
            sessions[context.surfaceId] == nil,
            "Late writes from an older Gemini session must not make the new id-less Stop create a surface-id fallback record"
        )
    }

    @Test func geminiIdlessAfterAgentUsesHookPIDInsteadOfNewerActiveSession() throws {
        let context = try makeClaudeHookContext(name: "gemini-idless-stop-pid-bound")
        defer { context.cleanup() }

        _ = startGeminiSurfaceResolutionServer(context: context)
        let olderSessionId = "gemini-older-pid-session"
        let newerSessionId = "gemini-newer-pid-session"
        let olderEnvironment = geminiHookEnvironment(context: context, pid: 44_001)
        let newerEnvironment = geminiHookEnvironment(context: context, pid: Int(getpid()))

        assertSuccessfulHook(runGeminiHook(
            context: context,
            subcommand: "session-start",
            standardInput: #"{"session_id":"\#(olderSessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#,
            environment: olderEnvironment
        ))
        assertSuccessfulHook(runGeminiHook(
            context: context,
            subcommand: "session-start",
            standardInput: #"{"session_id":"\#(newerSessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#,
            environment: newerEnvironment
        ))

        let stopCommandStart = context.state.snapshot().count
        assertHookExitedZero(runGeminiHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"cwd":"\#(context.root.path)","hook_event_name":"AfterAgent","last_assistant_message":"older done"}"#,
            environment: olderEnvironment
        ))

        let stopCommands = Array(context.state.snapshot().dropFirst(stopCommandStart))
        #expect(
            !stopCommands.contains {
                $0.hasPrefix("notify_target") || ($0.hasPrefix("set_status gemini ") && $0.contains(" Idle "))
            },
            "A stale id-less Stop from the older Gemini PID must not notify or mark the active newer process idle, saw \(stopCommands)"
        )
        #expect(
            !stopCommands.contains {
                $0.hasPrefix("set_agent_lifecycle gemini idle --tab=\(context.workspaceId)")
                    && $0.contains("--panel=\(context.surfaceId)")
            },
            "A stale id-less Stop from the older Gemini PID must not set the pane lifecycle idle while the newer PID is running, saw \(stopCommands)"
        )

        let sessions = try readGeminiSessions(context: context)
        let newer = try #require(sessions[newerSessionId])
        #expect(
            newer["agentLifecycle"] as? String != "idle",
            "A stale id-less Stop from the older Gemini PID must not rewrite the newer active session"
        )
        #expect(
            sessions[context.surfaceId] == nil,
            "A PID-matched id-less Stop must not create a surface-id fallback record"
        )
    }

    @Test func geminiIdlessAfterAgentDropsWhenNoAuthoritativeSurface() throws {
        let context = try makeClaudeHookContext(name: "gemini-idless-stop-no-surface")
        defer { context.cleanup() }

        _ = startGeminiSurfaceResolutionServer(context: context)
        let sessionId = "gemini-session-with-stale-surface-env"
        let staleSurfaceId = "33333333-3333-3333-3333-333333333333"
        let environment = geminiHookEnvironment(context: context)

        assertSuccessfulHook(runGeminiHook(
            context: context,
            subcommand: "session-start",
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#,
            environment: environment
        ))

        var staleSurfaceEnvironment = environment
        staleSurfaceEnvironment["CMUX_SURFACE_ID"] = staleSurfaceId
        let stopCommandStart = context.state.snapshot().count
        assertHookExitedZero(runGeminiHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"cwd":"\#(context.root.path)","hook_event_name":"AfterAgent","last_assistant_message":"done"}"#,
            environment: staleSurfaceEnvironment
        ))

        let stopCommands = Array(context.state.snapshot().dropFirst(stopCommandStart))
        #expect(
            !stopCommands.contains {
                $0.hasPrefix("notify_target") || $0.hasPrefix("set_status gemini ") || $0.hasPrefix("set_agent_lifecycle gemini ")
            },
            "An id-less Gemini Stop without an authoritative surface must no-op instead of mutating the default pane, saw \(stopCommands)"
        )

        let sessions = try readGeminiSessions(context: context)
        let original = try #require(sessions[sessionId])
        #expect(
            original["agentLifecycle"] as? String != "idle",
            "A stale ambient surface must not let an id-less Stop mark the original/default pane idle"
        )
        #expect(
            sessions[staleSurfaceId] == nil,
            "A stale ambient surface must not create the surface-id fallback record"
        )
    }

    @Test func geminiIdlessAfterAgentIgnoresStaleDuplicateOlderSessionStart() throws {
        let context = try makeClaudeHookContext(name: "gemini-idless-stop-ignores-stale-start")
        defer { context.cleanup() }

        _ = startGeminiSurfaceResolutionServer(context: context)
        let olderSessionId = "gemini-older-session"
        let newerSessionId = "gemini-newer-session"
        let environment = geminiHookEnvironment(context: context)

        assertSuccessfulHook(runGeminiHook(
            context: context,
            subcommand: "session-start",
            standardInput: #"{"session_id":"\#(olderSessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#,
            environment: environment
        ))
        assertSuccessfulHook(runGeminiHook(
            context: context,
            subcommand: "session-start",
            standardInput: #"{"session_id":"\#(newerSessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#,
            environment: environment
        ))
        let staleStartCommandStart = context.state.snapshot().count
        assertHookExitedZero(runGeminiHook(
            context: context,
            subcommand: "session-start",
            standardInput: #"{"session_id":"\#(olderSessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#,
            environment: environment
        ))
        let staleStartCommands = Array(context.state.snapshot().dropFirst(staleStartCommandStart))
        #expect(
            !staleStartCommands.contains {
                (jsonObject($0)?["method"] as? String) == "surface.resume.set"
                    || $0.hasPrefix("set_agent_pid gemini.")
                    || $0.hasPrefix("set_agent_lifecycle gemini ")
                    || $0.hasPrefix("set_status gemini ")
            },
            "A stale duplicate older Gemini SessionStart must not publish pane-visible state, saw \(staleStartCommands)"
        )

        let activeAfterStaleStart = try activeGeminiSlotSessionIds(context: context)
        #expect(!activeAfterStaleStart.isEmpty, "Gemini SessionStart must populate a pane-scoped active session slot")
        #expect(
            !activeAfterStaleStart.contains(olderSessionId),
            "A stale duplicate older Gemini SessionStart must not steal the active slot from the newer session, saw \(activeAfterStaleStart)"
        )
        #expect(
            activeAfterStaleStart.allSatisfy { $0 == newerSessionId },
            "The active slot must remain the newer session after a stale older SessionStart, saw \(activeAfterStaleStart)"
        )

        assertSuccessfulHook(runGeminiHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"cwd":"\#(context.root.path)","hook_event_name":"AfterAgent","last_assistant_message":"newer done"}"#,
            environment: environment
        ))

        let sessions = try readGeminiSessions(context: context)
        let newer = try #require(sessions[newerSessionId])
        #expect(
            newer["agentLifecycle"] as? String == "idle",
            "Id-less Gemini Stop must resolve to the newest session even after a stale duplicate older SessionStart"
        )
        #expect(newer["lastNotificationStatus"] as? String == "idle")
        let older = try #require(sessions[olderSessionId])
        #expect(
            older["agentLifecycle"] as? String != "idle",
            "A stale duplicate older SessionStart must not capture the id-less Stop meant for the newer session"
        )
        #expect(
            sessions[context.surfaceId] == nil,
            "Id-less Gemini Stop must not create a surface-id fallback record when a stale older SessionStart arrives late"
        )
    }

    struct ProcessRunResult { let status: Int32; let stdout: String; let stderr: String; let timedOut: Bool }
    typealias SurfaceFixture = (id: String, ref: String, focused: Bool)

    struct ClaudeHookContext {
        let cliPath: String
        let socketPath: String
        let listenerFD: Int32
        let state: MockSocketServerState
        let root: URL
        let workspaceId: String
        let surfaceId: String

        func cleanup() {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }
    }

    final class MockSocketServerState: @unchecked Sendable {
        private let lock = NSLock()
        private var commands: [String] = []

        func append(_ command: String) {
            lock.lock()
            commands.append(command)
            lock.unlock()
        }

        func snapshot() -> [String] {
            lock.lock()
            let value = commands
            lock.unlock()
            return value
        }
    }

    func makeClaudeHookContext(name: String) throws -> ClaudeHookContext {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-\(name)-\(UUID().uuidString)", isDirectory: true)
        let socketPath = makeSocketPath(String(name.prefix(6)))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return ClaudeHookContext(
            cliPath: try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self),
            socketPath: socketPath,
            listenerFD: try bindUnixSocket(at: socketPath),
            state: MockSocketServerState(),
            root: root,
            workspaceId: "11111111-1111-1111-1111-111111111111",
            surfaceId: "22222222-2222-2222-2222-222222222222"
        )
    }

    private func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-\(name.prefix(6))-\(shortID).sock")
            .path
    }

    private func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "cmux.tests", code: Int(errno))
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        let utf8 = Array(path.utf8)
        guard utf8.count < maxPathLength else {
            Darwin.close(fd)
            throw NSError(domain: "cmux.tests", code: Int(ENAMETOOLONG))
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { buffer in
                for index in 0..<utf8.count {
                    buffer[index] = CChar(bitPattern: utf8[index])
                }
                buffer[utf8.count] = 0
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(fd, 1) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw NSError(domain: "cmux.tests", code: Int(code))
        }
        return fd
    }

    private func startMockServer(
        listenerFD: Int32,
        state: MockSocketServerState,
        requiredSocketPassword: String? = nil,
        handler: @escaping @Sendable (String) -> String
    ) -> DispatchSemaphore {
        let handled = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            while true {
                var clientAddr = sockaddr_un()
                var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                    }
                }
                guard clientFD >= 0 else {
                    if errno == EINTR { continue }
                    return
                }

                DispatchQueue.global(qos: .userInitiated).async {
                    var authenticated = requiredSocketPassword == nil

                    defer {
                        Darwin.close(clientFD)
                        handled.signal()
                    }

                    func writeResponse(_ response: String) {
                        let line = response + "\n"
                        _ = line.withCString { ptr in
                            Darwin.write(clientFD, ptr, strlen(ptr))
                        }
                    }

                    var pending = Data()
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while true {
                        let count = Darwin.read(clientFD, &buffer, buffer.count)
                        if count < 0 {
                            if errno == EINTR { continue }
                            return
                        }
                        if count == 0 { return }
                        pending.append(buffer, count: count)

                        while let newlineRange = pending.firstRange(of: Data([0x0A])) {
                            let lineData = pending.subdata(in: 0..<newlineRange.lowerBound)
                            pending.removeSubrange(0...newlineRange.lowerBound)
                            guard let line = String(data: lineData, encoding: .utf8) else { continue }
                            state.append(line)
                            if let requiredSocketPassword, line.hasPrefix("auth ") {
                                if line == "auth \(requiredSocketPassword)" {
                                    authenticated = true
                                    writeResponse("OK")
                                } else {
                                    writeResponse("ERROR: Access denied")
                                }
                                continue
                            }
                            guard authenticated else {
                                writeResponse("ERROR: Access denied")
                                continue
                            }
                            writeResponse(handler(line))
                        }
                    }
                }
            }
        }
        return handled
    }

    func startClaudeSurfaceResolutionServer(
        context: ClaudeHookContext,
        surfaces: [SurfaceFixture],
        ttyName: String,
        ttySurfaceId: String,
        ttyWorkspaceId: String? = nil,
        surfacesByWorkspace: [String: [SurfaceFixture]]? = nil,
        agentPID: Int? = nil,
        agentPIDWorkspaceId: String? = nil,
        agentPIDSurfaceId: String? = nil,
        requiredSocketPassword: String? = nil
    ) -> DispatchSemaphore {
        let resolvedTTYWorkspaceId = ttyWorkspaceId ?? context.workspaceId
        return startMockServer(
            listenerFD: context.listenerFD,
            state: context.state,
            requiredSocketPassword: requiredSocketPassword
        ) { line in
            guard let payload = jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return "OK"
            }
            switch method {
            case "surface.list":
                let params = payload["params"] as? [String: Any]
                let workspaceId = params?["workspace_id"] as? String
                let listedSurfaces = workspaceId.flatMap { surfacesByWorkspace?[$0] } ?? surfaces
                let surfacePayload: [[String: Any]] = listedSurfaces.map { ["id": $0.id, "ref": $0.ref, "focused": $0.focused] }
                return v2Response(id: id, ok: true, result: ["surfaces": surfacePayload])
            case "debug.terminals":
                return v2Response(
                    id: id,
                    ok: true,
                    result: ["terminals": [[
                        "tty": ttyName,
                        "workspace_id": resolvedTTYWorkspaceId,
                        "surface_id": ttySurfaceId,
                    ]]]
                )
            case "system.top":
                guard let agentPID else {
                    return v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
                }
                let workspaceId = agentPIDWorkspaceId ?? context.workspaceId
                let surfaceId = agentPIDSurfaceId ?? context.surfaceId
                return v2Response(
                    id: id,
                    ok: true,
                    result: ["windows": [[
                        "workspaces": [[
                            "id": workspaceId,
                            "panes": [[
                                "surfaces": [[
                                    "id": surfaceId,
                                    "top_level_pids": [agentPID],
                                ]],
                            ]],
                        ]],
                    ]]]
                )
            case "feed.push":
                return v2Response(id: id, ok: true, result: [:])
            case "surface.resume.set":
                return v2Response(id: id, ok: true, result: ["resume_binding": [:]])
            default:
                return v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
            }
        }
    }

    func claudeHookEnvironment(context: ClaudeHookContext, surfaceId: String, ttyName: String, storeURL: URL) -> [String: String] {
        [
            "HOME": context.root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CMUX_SOCKET_PATH": context.socketPath,
            "CMUX_WORKSPACE_ID": context.workspaceId,
            "CMUX_SURFACE_ID": surfaceId,
            "CMUX_CLI_TTY_NAME": ttyName,
            "CMUX_CLAUDE_HOOK_STATE_PATH": storeURL.path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CMUX_CLAUDE_HOOK_SENTRY_DISABLED": "1",
        ]
    }

    private func writeClaudeHookStore(to storeURL: URL, sessionId: String, workspaceId: String, surfaceId: String, cwd: String) throws {
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
                    "launchCommand": [
                        "launcher": "claude",
                        "executablePath": "/usr/local/bin/claude",
                        "arguments": ["/usr/local/bin/claude"],
                        "workingDirectory": cwd,
                        "capturedAt": now,
                        "source": "test",
                    ],
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        let storeData = try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
        try storeData.write(to: storeURL)
    }

    private func assertPromptSubmitRoutes(
        name: String,
        sessionId: String,
        explicitSurfaceId: String? = nil,
        ttyName: String,
        ttySurfaceId: String,
        surfaces: (String) -> [SurfaceFixture],
        expectedSurfaceId: (String) -> String,
        requestMessage: String
    ) throws {
        let context = try makeClaudeHookContext(name: name)
        defer { context.cleanup() }

        let mappedSurfaceId = context.surfaceId
        let ambientSurfaceId = "66666666-6666-6666-6666-666666666666"
        let storeURL = context.root.appendingPathComponent("claude-hook-sessions.json")
        try writeClaudeHookStore(
            to: storeURL,
            sessionId: sessionId,
            workspaceId: context.workspaceId,
            surfaceId: mappedSurfaceId,
            cwd: context.root.path
        )
        let serverHandled = startClaudeSurfaceResolutionServer(
            context: context,
            surfaces: surfaces(mappedSurfaceId) + [(ambientSurfaceId, "surface:9", false)],
            ttyName: ttyName,
            ttySurfaceId: ttySurfaceId
        )

        var arguments = ["hooks", "claude", "prompt-submit"]
        if let explicitSurfaceId {
            arguments += ["--surface", explicitSurfaceId]
        }
        let result = runProcess(
            executablePath: context.cliPath,
            arguments: arguments,
            environment: claudeHookEnvironment(
                context: context,
                surfaceId: ambientSurfaceId,
                ttyName: ttyName,
                storeURL: storeURL
            ),
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit"}"#,
            timeout: 5
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        assertSuccessfulHook(result)

        let expected = expectedSurfaceId(mappedSurfaceId)
        let request = try #require(
            resumeBindingRequests(in: context).last,
            "Expected Claude surface resolution to publish a resume binding, saw \(context.state.snapshot())"
        )
        #expect(
            request["surface_id"] as? String == expected,
            "\(requestMessage); params=\(request)"
        )
        #expect(request["surface_id"] as? String != ambientSurfaceId, "Raw ambient CMUX_SURFACE_ID must not win")
        #expect(
            context.state.snapshot().contains {
                $0.hasPrefix("set_status claude_code Running ")
                    && $0.contains("--panel=\(expected)")
            },
            "Claude visible status should target \(expected), saw \(context.state.snapshot())"
        )
    }

    func startGeminiSurfaceResolutionServer(context: ClaudeHookContext) -> DispatchSemaphore {
        startClaudeSurfaceResolutionServer(
            context: context,
            surfaces: [(context.surfaceId, "surface:1", true)],
            ttyName: "ttys-unused-gemini",
            ttySurfaceId: context.surfaceId
        )
    }

    func geminiHookEnvironment(
        context: ClaudeHookContext,
        surfaceId: String? = nil,
        pid: Int? = nil
    ) -> [String: String] {
        var environment = [
            "HOME": context.root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PWD": context.root.path,
            "CMUX_SOCKET_PATH": context.socketPath,
            "CMUX_WORKSPACE_ID": context.workspaceId,
            "CMUX_SURFACE_ID": surfaceId ?? context.surfaceId,
            "CMUX_AGENT_HOOK_STATE_DIR": context.root.path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CMUX_AGENT_LAUNCH_KIND": "gemini",
            "CMUX_AGENT_LAUNCH_EXECUTABLE": "/usr/local/bin/gemini",
            "CMUX_AGENT_LAUNCH_CWD": context.root.path,
            "CMUX_AGENT_LAUNCH_ARGV_B64": base64NULSeparated(["/usr/local/bin/gemini"]),
        ]
        if let pid {
            environment["CMUX_GEMINI_PID"] = "\(pid)"
        }
        return environment
    }

    func runGeminiHook(
        context: ClaudeHookContext,
        subcommand: String,
        standardInput: String,
        environment: [String: String]
    ) -> ProcessRunResult {
        runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "gemini", subcommand],
            environment: environment,
            standardInput: standardInput,
            timeout: 5
        )
    }

    func readGeminiSessions(context: ClaudeHookContext) throws -> [String: [String: Any]] {
        let storeURL = context.root.appendingPathComponent("gemini-hook-sessions.json")
        let data = try Data(contentsOf: storeURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = json["sessions"] as? [String: [String: Any]] else {
            throw NSError(domain: "cmux.tests", code: Int(EINVAL))
        }
        return sessions
    }

    func activeGeminiSlotSessionIds(context: ClaudeHookContext) throws -> [String] {
        let storeURL = context.root.appendingPathComponent("gemini-hook-sessions.json")
        let data = try Data(contentsOf: storeURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "cmux.tests", code: Int(EINVAL))
        }
        var ids: [String] = []
        for key in ["activeSessionsBySurface", "activeSessionsByWorkspace"] {
            guard let map = json[key] as? [String: Any] else { continue }
            for value in map.values {
                if let record = value as? [String: Any],
                   let sessionId = record["sessionId"] as? String {
                    ids.append(sessionId)
                }
            }
        }
        return ids
    }

    func assertSuccessfulHook(_ result: ProcessRunResult) {
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "OK\n")
    }

    func assertHookExitedZero(_ result: ProcessRunResult) {
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
    }

    private func resumeBindingRequests(in context: ClaudeHookContext) -> [[String: Any]] {
        context.state.snapshot().compactMap { command -> [String: Any]? in
            guard let payload = jsonObject(command),
                  payload["method"] as? String == "surface.resume.set" else {
                return nil
            }
            return payload["params"] as? [String: Any]
        }
    }

    private func v2Response(
        id: String,
        ok: Bool,
        result: [String: Any]? = nil,
        error: [String: Any]? = nil
    ) -> String {
        var payload: [String: Any] = ["id": id, "ok": ok]
        if let result { payload["result"] = result }
        if let error { payload["error"] = error }
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [])
        return String(data: data ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }

    private func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    }

    private func base64NULSeparated(_ values: [String]) -> String {
        var data = Data()
        for value in values {
            data.append(contentsOf: value.utf8)
            data.append(0)
        }
        return data.base64EncodedString()
    }

    func runProcess(executablePath: String, arguments: [String], environment: [String: String], standardInput: String? = nil, timeout: TimeInterval) -> ProcessRunResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = standardInput == nil ? nil : Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = stdinPipe ?? FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stdout: "", stderr: String(describing: error), timedOut: false)
        }
        if let standardInput, let stdinPipe {
            stdinPipe.fileHandleForWriting.write(Data(standardInput.utf8))
            try? stdinPipe.fileHandleForWriting.close()
        }

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }

        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if exitSignal.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exitSignal.wait(timeout: .now() + 1)
            }
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessRunResult(
            status: process.isRunning ? SIGKILL : process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
        )
    }
}
