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
        environment["CMUX_AGENT_HOOK_CAPTURED_AT"] = "1700000300.000000"

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
        let notifyCommand = try #require(
            context.state.snapshot().first { $0.hasPrefix("notify_target_async ") }
        )
        #expect(
            notifyCommand.contains(";k=claude_code;t=1700000300.000000"),
            "The notification itself must carry the event watermark so a delayed older clear cannot erase it; command=\(notifyCommand)"
        )
    }

    @Test func claudeClearSessionStartOrdersPIDAndNotificationClear() throws {
        let harness = ClaudeHookSurfaceResolutionSwiftTests()
        let context = try harness.makeClaudeHookContext(name: "claude-ordered-visible-mutations")
        defer { context.cleanup() }
        _ = harness.startClaudeSurfaceResolutionServer(
            context: context,
            surfaces: [(context.surfaceId, "surface:1", true)],
            ttyName: "ttys-claude-ordered-visible-mutations",
            ttySurfaceId: context.surfaceId
        )
        var environment = harness.claudeHookEnvironment(
            context: context,
            surfaceId: context.surfaceId,
            ttyName: "ttys-claude-ordered-visible-mutations",
            storeURL: context.root.appendingPathComponent("claude-hook-sessions.json")
        )
        environment["CMUX_CLAUDE_PID"] = "42424"
        environment["CMUX_AGENT_HOOK_CAPTURED_AT"] = "1700000200.000000"

        let result = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "session-start"],
            environment: environment,
            standardInput: #"{"session_id":"claude-ordered-visible-mutations","source":"clear","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#,
            timeout: 5
        )
        harness.assertSuccessfulHook(result)

        let commands = context.state.snapshot()
        let pidCommand = try #require(commands.first { $0.hasPrefix("set_agent_pid claude_code ") })
        #expect(pidCommand.contains("--agent-event-time=1700000200.000000"))
        let clearCommand = try #require(commands.first { $0.hasPrefix("clear_notifications ") })
        #expect(clearCommand.contains("--agent-status-key=claude_code"))
        #expect(clearCommand.contains("--agent-event-time=1700000200.000000"))
    }

    @Test func staleClaudeNotificationHasNoVisibleMutationSideEffects() throws {
        let harness = ClaudeHookSurfaceResolutionSwiftTests()
        let context = try harness.makeClaudeHookContext(name: "claude-stale-notification")
        defer { context.cleanup() }
        let storeURL = context.root.appendingPathComponent("claude-hook-sessions.json")
        let serverHandled = harness.startClaudeSurfaceResolutionServer(
            context: context,
            surfaces: [(context.surfaceId, "surface:1", true)],
            ttyName: "ttys-claude-stale-notification",
            ttySurfaceId: context.surfaceId
        )
        var environment = harness.claudeHookEnvironment(
            context: context,
            surfaceId: context.surfaceId,
            ttyName: "ttys-claude-stale-notification",
            storeURL: storeURL
        )
        environment["CMUX_AGENT_HOOK_CAPTURED_AT"] = "1700000200.000000"

        let start = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "session-start"],
            environment: environment,
            standardInput: #"{"session_id":"claude-stale-notification-session","source":"clear","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#,
            timeout: 5
        )
        harness.assertSuccessfulHook(start)
        let staleMutationStart = context.state.snapshot().count

        environment["CMUX_AGENT_HOOK_CAPTURED_AT"] = "1700000100.000000"
        let staleNotification = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "notification"],
            environment: environment,
            standardInput: #"{"session_id":"claude-stale-notification-session","cwd":"\#(context.root.path)","hook_event_name":"Notification","message":"Claude needs your input"}"#,
            timeout: 5
        )
        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        harness.assertSuccessfulHook(staleNotification)

        let staleCommands = Array(context.state.snapshot().dropFirst(staleMutationStart))
        #expect(
            !staleCommands.contains {
                $0.hasPrefix("set_agent_lifecycle claude_code ") ||
                    $0.hasPrefix("set_status claude_code ") ||
                    $0.hasPrefix("notify_target") ||
                    $0.contains(#""method":"surface.resume.set""#)
            },
            "A rejected stale store update must not publish lifecycle, status, notification, PID, or resume mutations: \(staleCommands)"
        )

        let state = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any]
        )
        let sessions = try #require(state["sessions"] as? [String: Any])
        let record = try #require(sessions["claude-stale-notification-session"] as? [String: Any])
        #expect(record["agentLifecycle"] as? String == "running")
        #expect(record["runtimeStatusEventTime"] as? Double == 1_700_000_200)
    }

    @Test func staleClaudeSessionEndDoesNotConsumeNewerRunningSession() throws {
        let harness = ClaudeHookSurfaceResolutionSwiftTests()
        let context = try harness.makeClaudeHookContext(name: "claude-stale-session-end")
        defer { context.cleanup() }
        let sessionId = "claude-stale-session-end-session"
        let storeURL = context.root.appendingPathComponent("claude-hook-sessions.json")
        _ = harness.startClaudeSurfaceResolutionServer(
            context: context,
            surfaces: [(context.surfaceId, "surface:1", true)],
            ttyName: "ttys-claude-stale-session-end",
            ttySurfaceId: context.surfaceId
        )
        var environment = harness.claudeHookEnvironment(
            context: context,
            surfaceId: context.surfaceId,
            ttyName: "ttys-claude-stale-session-end",
            storeURL: storeURL
        )
        environment["CMUX_AGENT_HOOK_CAPTURED_AT"] = "1700000200.000000"
        let start = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "session-start"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","source":"clear","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#,
            timeout: 5
        )
        harness.assertSuccessfulHook(start)
        let teardownCommandStart = context.state.snapshot().count

        environment["CMUX_AGENT_HOOK_CAPTURED_AT"] = "1700000100.000000"
        let staleEnd = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "session-end"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionEnd"}"#,
            timeout: 5
        )
        harness.assertSuccessfulHook(staleEnd)

        let commands = Array(context.state.snapshot().dropFirst(teardownCommandStart))
        #expect(!commands.contains { $0.hasPrefix("clear_agent_pid claude_code ") })
        #expect(!commands.contains { $0.contains("surface.resume.clear") })
        let state = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any])
        let sessions = try #require(state["sessions"] as? [String: Any])
        #expect(sessions[sessionId] != nil, "A stale SessionEnd must leave the newer running record intact")
    }

    @Test func farFuturePayloadTimestampDoesNotBecomeOrderingAuthority() throws {
        let harness = ClaudeHookSurfaceResolutionSwiftTests()
        let context = try harness.makeClaudeHookContext(name: "claude-future-payload-time")
        defer { context.cleanup() }
        let sessionId = "claude-future-payload-time-session"
        let storeURL = context.root.appendingPathComponent("claude-hook-sessions.json")
        _ = harness.startClaudeSurfaceResolutionServer(
            context: context,
            surfaces: [(context.surfaceId, "surface:1", true)],
            ttyName: "ttys-claude-future-payload-time",
            ttySurfaceId: context.surfaceId
        )
        let environment = harness.claudeHookEnvironment(
            context: context,
            surfaceId: context.surfaceId,
            ttyName: "ttys-claude-future-payload-time",
            storeURL: storeURL
        )
        let futureTime = Date().timeIntervalSince1970 + 86_400
        let start = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "session-start"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","source":"clear","cwd":"\#(context.root.path)","hook_event_name":"SessionStart","timestamp":\#(futureTime)}"#,
            timeout: 5
        )
        harness.assertSuccessfulHook(start)

        let state = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any])
        let sessions = try #require(state["sessions"] as? [String: Any])
        let record = try #require(sessions[sessionId] as? [String: Any])
        #expect(record["runtimeStatusEventTime"] == nil)
    }
}
