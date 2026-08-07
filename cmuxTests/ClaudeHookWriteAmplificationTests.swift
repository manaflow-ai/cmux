import Foundation
import Testing

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/9693.
/// Repeated ordinary Claude tool calls must not turn an already-running
/// lifecycle observation into durable Feed telemetry or a session-file write.
@Suite(.serialized)
struct ClaudeHookWriteAmplificationTests {
    private typealias Harness = ClaudeHookLiveDeliveryHarness

    @Test func ordinaryToolUseWhileRunningDoesNotWriteDurableState() throws {
        let context = try Harness.makeContext(name: "pre-tool-write-amplification")
        defer { context.cleanup() }

        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "ordinary-running-tool-session"
        let now = Date.now.timeIntervalSince1970
        let state: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": context.root.path,
                    "agentLifecycle": "running",
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        let stateData = try JSONSerialization.data(
            withJSONObject: state,
            options: [.prettyPrinted, .sortedKeys]
        )
        try stateData.write(to: context.storeURL)

        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [workspaceId: [surfaceId]],
            pidTarget: nil,
            surfaceTargets: [surfaceId: workspaceId]
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        let result = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "pre-tool-use"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"\#(context.root.path)"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        #expect(
            !context.state.snapshot().contains { command in
                command.contains(#""method":"feed.push""#)
                    || command.hasPrefix("set_status ")
                    || command.hasPrefix("set_agent_lifecycle ")
                    || command.hasPrefix("clear_notifications ")
            }
        )
        #expect(try Data(contentsOf: context.storeURL) == stateData)
    }

    @Test(arguments: ["PostToolUse", "PostToolUseFailure"])
    func blockingToolCompletionClearsNeedsInputWithoutFeedTelemetry(
        hookEventName: String
    ) throws {
        let context = try Harness.makeContext(name: "input-resolved-\(hookEventName)")
        defer { context.cleanup() }

        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "resolved-blocking-tool-session"
        let now = Date.now.timeIntervalSince1970
        let state: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": context.root.path,
                    "agentLifecycle": "needsInput",
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: state).write(to: context.storeURL)

        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [workspaceId: [surfaceId]],
            pidTarget: nil,
            surfaceTargets: [surfaceId: workspaceId]
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        let result = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "input-resolved"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"\#(hookEventName)","tool_name":"AskUserQuestion","cwd":"\#(context.root.path)"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        let commands = context.state.snapshot()
        #expect(!commands.contains { $0.contains(#""method":"feed.push""#) })
        #expect(commands.contains("clear_notifications --tab=\(workspaceId) --panel=\(surfaceId)"))
        #expect(
            commands.contains {
                $0.hasPrefix("set_agent_lifecycle claude_code running ")
                    && $0.contains("--tab=\(workspaceId)")
                    && $0.contains("--panel=\(surfaceId)")
            }
        )
        #expect(
            commands.contains {
                $0.hasPrefix("set_status claude_code ")
                    && $0.contains("--icon=bolt.fill")
                    && $0.contains("--tab=\(workspaceId)")
                    && $0.contains("--panel=\(surfaceId)")
            }
        )
        let record = try Harness.sessionRecord(in: context.storeURL, sessionId: sessionId)
        #expect(record?["agentLifecycle"] as? String == "running")
    }
}
