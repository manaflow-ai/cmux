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
        let now: TimeInterval = 4_102_444_800
        let state: [String: Any] = [
            "version": 1,
            "pendingCursorApprovalIndexInitialized": true,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": context.root.path,
                    "agentLifecycle": "running",
                    "lastPermissionMode": "default",
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
        let initialAttributes = try FileManager.default.attributesOfItem(atPath: context.storeURL.path)
        let initialFileNumber = (initialAttributes[.systemFileNumber] as? NSNumber)?.uint64Value
        let initialModificationDate = initialAttributes[.modificationDate] as? Date

        _ = Harness.startDeliveryTargetServer(
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
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"PreToolUse","tool_name":"Bash","permission_mode":"default","cwd":"\#(context.root.path)"}"#
        )

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
        let finalAttributes = try FileManager.default.attributesOfItem(atPath: context.storeURL.path)
        #expect(
            (finalAttributes[.systemFileNumber] as? NSNumber)?.uint64Value == initialFileNumber,
            "An unchanged session must not be atomically replaced"
        )
        #expect(
            finalAttributes[.modificationDate] as? Date == initialModificationDate,
            "An unchanged session must not be rewritten"
        )
    }
}
