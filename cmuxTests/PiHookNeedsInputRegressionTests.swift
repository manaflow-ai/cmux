import XCTest
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension CLINotifyProcessIntegrationRegressionTests {
    func testPiQuestionNeedsInputSurvivesCompletionStop() throws {
        let context = try makeClaudeHookContext(name: "pi-question-stop")
        defer { context.cleanup() }

        let sessionId = "pi-question-stop-session"
        startAgentHookMockServerAccepting(context: context)
        let launchEnvironment = agentLaunchEnvironment(
            context: context,
            kind: "pi",
            executable: "/usr/local/bin/pi"
        )
        let start = runAgentHook(
            context: context,
            agent: "pi",
            subcommand: "session-start",
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertEqual(start.status, 0, start.stderr)

        let prompt = runAgentHook(
            context: context,
            agent: "pi",
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"pi-turn-1","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"Ask me which option to use."}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertEqual(prompt.status, 0, prompt.stderr)

        let question = runAgentHook(
            context: context,
            agent: "pi",
            subcommand: "notification",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"pi-turn-1","cwd":"\#(context.root.path)","hook_event_name":"questionAsked","event":"questionAsked","message":"Which option should I take?"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertEqual(question.status, 0, question.stderr)

        let stopStart = context.state.commands.count
        let stop = runAgentHook(
            context: context,
            agent: "pi",
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"pi-turn-1","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"Which option should I take?"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertEqual(stop.status, 0, stop.stderr)
        let stopCommands = Array(context.state.commands.dropFirst(stopStart))
        XCTAssertFalse(
            stopCommands.contains { $0.hasPrefix("set_status pi ") && $0.contains(" Idle ") },
            "Pi Stop must preserve a same-turn Needs input state, saw \(stopCommands)"
        )

        let stateURL = context.root.appendingPathComponent("pi-hook-sessions.json")
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        let sessions = try XCTUnwrap(state["sessions"] as? [String: Any])
        let record = try XCTUnwrap(sessions[sessionId] as? [String: Any])
        XCTAssertEqual(record["runtimeStatus"] as? String, "needsInput")
        XCTAssertEqual(record["agentLifecycle"] as? String, "needsInput")
    }

    func testPiSessionShutdownClearsNeedsInput() throws {
        let context = try makeClaudeHookContext(name: "pi-question-shutdown")
        defer { context.cleanup() }

        let sessionId = "pi-question-shutdown-session"
        startAgentHookMockServerAccepting(context: context)
        let launchEnvironment = agentLaunchEnvironment(
            context: context,
            kind: "pi",
            executable: "/usr/local/bin/pi"
        )
        for (subcommand, payload) in [
            (
                "session-start",
                #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#
            ),
            (
                "prompt-submit",
                #"{"session_id":"\#(sessionId)","turn_id":"pi-shutdown-turn","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"Ask me which option to use."}"#
            ),
            (
                "notification",
                #"{"session_id":"\#(sessionId)","turn_id":"pi-shutdown-turn","cwd":"\#(context.root.path)","hook_event_name":"questionAsked","event":"questionAsked","message":"Which option should I take?"}"#
            ),
        ] {
            let result = runAgentHook(
                context: context,
                agent: "pi",
                subcommand: subcommand,
                standardInput: payload,
                extraEnvironment: launchEnvironment
            )
            XCTAssertEqual(result.status, 0, "\(subcommand): \(result.stderr)")
        }

        let stopStart = context.state.commands.count
        let stop = runAgentHook(
            context: context,
            agent: "pi",
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"pi-shutdown-turn","cwd":"\#(context.root.path)","hook_event_name":"Stop","terminationReason":"session_shutdown","last_assistant_message":"Which option should I take?"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertEqual(stop.status, 0, stop.stderr)
        let stopCommands = Array(context.state.commands.dropFirst(stopStart))
        XCTAssertTrue(
            stopCommands.contains { $0.contains("set_status pi Idle") },
            "Session shutdown must clear Pi Needs input, saw \(stopCommands)"
        )
        XCTAssertFalse(
            stopCommands.contains { $0.contains("set_status pi Needs input") },
            "Session shutdown must not preserve Pi Needs input, saw \(stopCommands)"
        )

        let stateURL = context.root.appendingPathComponent("pi-hook-sessions.json")
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        let sessions = try XCTUnwrap(state["sessions"] as? [String: Any])
        let record = try XCTUnwrap(sessions[sessionId] as? [String: Any])
        XCTAssertEqual(record["runtimeStatus"] as? String, "idle")
        XCTAssertEqual(record["agentLifecycle"] as? String, "idle")
        XCTAssertEqual(record["lastNotificationStatus"] as? String, "idle")
    }

    func testPiIdleDialogResolutionReturnsToIdle() throws {
        let context = try makeClaudeHookContext(name: "pi-idle-dialog")
        defer { context.cleanup() }

        let sessionId = "pi-idle-dialog-session"
        startAgentHookMockServerAccepting(context: context)
        let launchEnvironment = agentLaunchEnvironment(
            context: context,
            kind: "pi",
            executable: "/usr/local/bin/pi"
        )
        let start = runAgentHook(
            context: context,
            agent: "pi",
            subcommand: "session-start",
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertEqual(start.status, 0, start.stderr)

        let question = runAgentHook(
            context: context,
            agent: "pi",
            subcommand: "notification",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"pi-idle-dialog-id","cwd":"\#(context.root.path)","hook_event_name":"questionAsked","event":"questionAsked","message":"Idle dialog"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertEqual(question.status, 0, question.stderr)

        let resolutionStart = context.state.commands.count
        let resolution = runAgentHook(
            context: context,
            agent: "pi",
            subcommand: "approval-response",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"pi-idle-dialog-id","cwd":"\#(context.root.path)","hook_event_name":"ApprovalResponse","cmux_pi_idle_dialog":true}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertEqual(resolution.status, 0, resolution.stderr)
        let commands = Array(context.state.commands.dropFirst(resolutionStart))
        XCTAssertTrue(commands.contains { $0.contains("set_status pi Idle") }, "Idle Pi dialog resolution must restore Idle, saw \(commands)")
        XCTAssertFalse(commands.contains { $0.contains("set_status pi Running") }, "Idle Pi dialog resolution must not mark Pi Running, saw \(commands)")
    }
}
