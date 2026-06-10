import XCTest
import Darwin
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Generic agent lifecycle
extension CLINotifyProcessIntegrationRegressionTests {
    func testGenericAgentNotificationUpdatesLifecycleForNeedsInput() throws {
        let context = try makeClaudeHookContext(name: "codex-notification-lifecycle")
        defer { context.cleanup() }

        let sessionId = "notification-lifecycle-session"
        let launchEnvironment = codexLaunchEnvironment(context: context, sessionId: sessionId)
        startAgentHookMockServerAccepting(context: context, connectionLimit: 64)

        let prompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"continue"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(prompt.timedOut, prompt.stderr)
        XCTAssertEqual(prompt.status, 0, prompt.stderr)

        let stop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"done"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(stop.timedOut, stop.stderr)
        XCTAssertEqual(stop.status, 0, stop.stderr)

        let stateURL = context.root.appendingPathComponent("codex-hook-sessions.json")
        var state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        var sessions = try XCTUnwrap(state["sessions"] as? [String: Any])
        var record = try XCTUnwrap(sessions[sessionId] as? [String: Any])
        XCTAssertEqual(record["agentLifecycle"] as? String, "idle")

        let notificationStart = context.state.commands.count
        let notification = runCodexHook(
            context: context,
            subcommand: "notification",
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"Notification","message":"permission approval required"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(notification.timedOut, notification.stderr)
        XCTAssertEqual(notification.status, 0, notification.stderr)

        let notificationCommands = Array(context.state.commands.dropFirst(notificationStart))
        XCTAssertTrue(
            notificationCommands.contains {
                $0.hasPrefix("set_agent_lifecycle codex needsInput --tab=\(context.workspaceId)")
                    && $0.contains("--panel=\(context.surfaceId)")
            },
            "Notification requiring user input must correct the visible lifecycle, saw \(notificationCommands)"
        )

        state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        sessions = try XCTUnwrap(state["sessions"] as? [String: Any])
        record = try XCTUnwrap(sessions[sessionId] as? [String: Any])
        XCTAssertEqual(record["agentLifecycle"] as? String, "needsInput")
    }

    func testGenericAgentStaleIdleStopDoesNotOverwriteNewerRunningLifecycle() throws {
        let context = try makeClaudeHookContext(name: "codex-stale-idle-stop-lifecycle")
        defer { context.cleanup() }

        let oldSessionId = "stale-idle-stop-old"
        let newSessionId = "stale-idle-stop-new"
        let oldEnvironment = codexLaunchEnvironment(context: context, sessionId: oldSessionId)
        let newEnvironment = codexLaunchEnvironment(context: context, sessionId: newSessionId)
        startAgentHookMockServerAccepting(context: context, connectionLimit: 64)

        let oldPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(oldSessionId)","turn_id":"old-turn","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"old"}"#,
            extraEnvironment: oldEnvironment
        )
        XCTAssertFalse(oldPrompt.timedOut, oldPrompt.stderr)
        XCTAssertEqual(oldPrompt.status, 0, oldPrompt.stderr)

        let newPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(newSessionId)","turn_id":"new-turn","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"new"}"#,
            extraEnvironment: newEnvironment
        )
        XCTAssertFalse(newPrompt.timedOut, newPrompt.stderr)
        XCTAssertEqual(newPrompt.status, 0, newPrompt.stderr)

        let staleStopStart = context.state.commands.count
        let staleStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(oldSessionId)","turn_id":"old-turn","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"old done"}"#,
            extraEnvironment: oldEnvironment
        )
        XCTAssertFalse(staleStop.timedOut, staleStop.stderr)
        XCTAssertEqual(staleStop.status, 0, staleStop.stderr)

        let staleStopCommands = Array(context.state.commands.dropFirst(staleStopStart))
        XCTAssertFalse(
            staleStopCommands.contains { $0.hasPrefix("set_agent_lifecycle codex idle ") },
            "A stale Stop from an older session must not mark the surface idle, saw \(staleStopCommands)"
        )
        XCTAssertFalse(
            staleStopCommands.contains { $0.hasPrefix("set_status codex ") && $0.contains(" Idle ") },
            "A stale Stop from an older session must not replace the newer Running status, saw \(staleStopCommands)"
        )
        XCTAssertFalse(
            staleStopCommands.contains { $0.hasPrefix("notify_target") },
            "A stale Stop from an older session must not publish a completion notification, saw \(staleStopCommands)"
        )

        let stateURL = context.root.appendingPathComponent("codex-hook-sessions.json")
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        let sessions = try XCTUnwrap(state["sessions"] as? [String: Any])
        let newRecord = try XCTUnwrap(sessions[newSessionId] as? [String: Any])
        XCTAssertEqual(newRecord["runtimeStatus"] as? String, "running")
        XCTAssertEqual(newRecord["agentLifecycle"] as? String, "running")
    }

    func testGenericAgentStaleIdleNotificationDoesNotOverwriteNewerRunningLifecycle() throws {
        let context = try makeClaudeHookContext(name: "codex-stale-idle-notification-lifecycle")
        defer { context.cleanup() }

        let oldSessionId = "stale-idle-notification-old"
        let newSessionId = "stale-idle-notification-new"
        let oldEnvironment = codexLaunchEnvironment(context: context, sessionId: oldSessionId)
        let newEnvironment = codexLaunchEnvironment(context: context, sessionId: newSessionId)
        startAgentHookMockServerAccepting(context: context, connectionLimit: 64)

        let oldPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(oldSessionId)","turn_id":"old-turn","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"old"}"#,
            extraEnvironment: oldEnvironment
        )
        XCTAssertFalse(oldPrompt.timedOut, oldPrompt.stderr)
        XCTAssertEqual(oldPrompt.status, 0, oldPrompt.stderr)

        let newPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(newSessionId)","turn_id":"new-turn","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"new"}"#,
            extraEnvironment: newEnvironment
        )
        XCTAssertFalse(newPrompt.timedOut, newPrompt.stderr)
        XCTAssertEqual(newPrompt.status, 0, newPrompt.stderr)

        let staleNotificationStart = context.state.commands.count
        let staleNotification = runCodexHook(
            context: context,
            subcommand: "notification",
            standardInput: #"{"session_id":"\#(oldSessionId)","cwd":"\#(context.root.path)","hook_event_name":"Notification","message":"done"}"#,
            extraEnvironment: oldEnvironment
        )
        XCTAssertFalse(staleNotification.timedOut, staleNotification.stderr)
        XCTAssertEqual(staleNotification.status, 0, staleNotification.stderr)

        let staleNotificationCommands = Array(context.state.commands.dropFirst(staleNotificationStart))
        XCTAssertFalse(
            staleNotificationCommands.contains { $0.hasPrefix("set_agent_lifecycle codex idle ") },
            "A stale idle notification must not mark the newer session idle, saw \(staleNotificationCommands)"
        )
        XCTAssertFalse(
            staleNotificationCommands.contains { $0.hasPrefix("set_status codex ") && $0.contains(" Idle ") },
            "A stale idle notification must not replace the newer Running status, saw \(staleNotificationCommands)"
        )
        XCTAssertFalse(
            staleNotificationCommands.contains { $0.hasPrefix("notify_target") },
            "A stale idle notification must not publish a completion notification, saw \(staleNotificationCommands)"
        )

        let stateURL = context.root.appendingPathComponent("codex-hook-sessions.json")
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        let sessions = try XCTUnwrap(state["sessions"] as? [String: Any])
        let newRecord = try XCTUnwrap(sessions[newSessionId] as? [String: Any])
        XCTAssertEqual(newRecord["runtimeStatus"] as? String, "running")
        XCTAssertEqual(newRecord["agentLifecycle"] as? String, "running")
    }

    func testGenericAgentTurnIdsStayNestedAcrossTurnChanges() throws {
        let context = try makeClaudeHookContext(name: "generic-turn-stack")
        defer { context.cleanup() }

        let sessionId = "generic-turn-stack-session"
        let launchEnvironment = agentLaunchEnvironment(context: context, kind: "gemini", executable: "/usr/local/bin/gemini")
        startAgentHookMockServerAccepting(context: context, connectionLimit: 48)

        let parentPrompt = runAgentHook(
            context: context,
            agent: "gemini",
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"parent-turn","cwd":"\#(context.root.path)","hook_event_name":"BeforeAgent","prompt":"parent"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(parentPrompt.timedOut, parentPrompt.stderr)
        XCTAssertEqual(parentPrompt.status, 0, parentPrompt.stderr)

        let childPromptStart = context.state.commands.count
        let childPrompt = runAgentHook(
            context: context,
            agent: "gemini",
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"child-turn","cwd":"\#(context.root.path)","hook_event_name":"BeforeAgent","prompt":"child"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(childPrompt.timedOut, childPrompt.stderr)
        XCTAssertEqual(childPrompt.status, 0, childPrompt.stderr)
        let childPromptCommands = Array(context.state.commands.dropFirst(childPromptStart))
        XCTAssertFalse(
            childPromptCommands.contains { (self.jsonObject($0)?["method"] as? String)?.hasPrefix("surface.resume.") == true },
            "A generic nested turn_id prompt must not replace the parent resume binding, saw \(childPromptCommands)"
        )
        XCTAssertFalse(
            childPromptCommands.contains { $0.hasPrefix("set_status gemini Running ") },
            "A generic nested turn_id prompt must not rewrite parent Running status, saw \(childPromptCommands)"
        )

        let childStopStart = context.state.commands.count
        let childStop = runAgentHook(
            context: context,
            agent: "gemini",
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"child-turn","cwd":"\#(context.root.path)","hook_event_name":"AfterAgent","last_assistant_message":"child done"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(childStop.timedOut, childStop.stderr)
        XCTAssertEqual(childStop.status, 0, childStop.stderr)
        let childStopCommands = Array(context.state.commands.dropFirst(childStopStart))
        XCTAssertFalse(
            childStopCommands.contains { $0.hasPrefix("notify_target") || $0.hasPrefix("set_status gemini ") },
            "A generic nested turn_id Stop must not notify or mark the parent idle, saw \(childStopCommands)"
        )

        let parentStopStart = context.state.commands.count
        let parentStop = runAgentHook(
            context: context,
            agent: "gemini",
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"parent-turn","cwd":"\#(context.root.path)","hook_event_name":"AfterAgent","last_assistant_message":"parent done"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(parentStop.timedOut, parentStop.stderr)
        XCTAssertEqual(parentStop.status, 0, parentStop.stderr)
        let parentStopCommands = Array(context.state.commands.dropFirst(parentStopStart))
        XCTAssertTrue(
            parentStopCommands.contains { $0.hasPrefix("notify_target_async \(context.workspaceId) \(context.surfaceId) Gemini|") },
            "The generic parent Stop must still notify after its nested child, saw \(parentStopCommands)"
        )
        XCTAssertTrue(
            parentStopCommands.contains { $0.hasPrefix("set_status gemini ") && $0.contains(" Idle ") },
            "The generic parent Stop must still mark Gemini idle, saw \(parentStopCommands)"
        )
    }

}
