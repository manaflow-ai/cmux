import Dispatch
import CMUXAgentLaunch
import Foundation
import Testing

@Suite(.serialized)
struct ClaudeNotificationStatusLifecycleTests {
    @Test func claudeNotificationRegistersSessionScopedPIDForStaleSweep() throws {
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

        let storeURL = context.root.appendingPathComponent("claude-hook-sessions.json")
        var environment = harness.claudeHookEnvironment(
            context: context,
            surfaceId: context.surfaceId,
            ttyName: "ttys-claude-notify-pid",
            storeURL: storeURL
        )
        environment["CMUX_CLAUDE_PID"] = "\(claudePID)"

        let result = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "notification"],
            environment: environment,
            standardInput: #"{"session_id":"claude-notify-pid-session","cwd":"\#(context.root.path)","hook_event_name":"Notification","message":"Claude needs your input"}"#,
            timeout: 5
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        harness.assertSuccessfulHook(result)

        let commands = context.state.snapshot()
        let statusCommand = try #require(
            commands.first {
                $0.hasPrefix("set_status claude_code Needs input ")
                    && $0.contains("--tab=\(context.workspaceId)")
                    && $0.contains("--panel=\(context.surfaceId)")
            },
            "Expected Claude notification to set a Needs input status, saw \(commands)"
        )
        let runtimeKeys = AgentRuntimeSessionKey(
            statusKey: "claude_code",
            sessionID: "claude-notify-pid-session"
        ).compatibleRawValues
        let record = try #require(
            ClaudeHookLiveDeliveryHarness.sessionRecord(
                in: storeURL,
                sessionId: "claude-notify-pid-session"
            )
        )
        let runtimeGeneration = try #require(record["runtimeGeneration"] as? Double)
        let encodedPIDIndex = try #require(commands.firstIndex {
            $0.hasPrefix("set_agent_pid \(runtimeKeys[0]) \(claudePID) ")
        })
        let legacyPIDIndex = try #require(commands.firstIndex {
            $0.hasPrefix("set_agent_pid \(runtimeKeys[1]) \(claudePID) ")
        })
        let lifecycleIndex = try #require(commands.firstIndex {
            $0.hasPrefix("set_agent_lifecycle claude_code ")
        })
        let runtimeAuthority = "--runtime-key=\(runtimeKeys[0])"
        let generationAuthority = "--runtime-generation=\(runtimeGeneration)"
        #expect(encodedPIDIndex < legacyPIDIndex)
        #expect(legacyPIDIndex < lifecycleIndex)
        #expect(commands[encodedPIDIndex].contains(runtimeAuthority))
        #expect(commands[encodedPIDIndex].contains(generationAuthority))
        #expect(commands[legacyPIDIndex].contains(runtimeAuthority))
        #expect(commands[legacyPIDIndex].contains(generationAuthority))
        #expect(commands[lifecycleIndex].contains(runtimeAuthority))
        #expect(commands[lifecycleIndex].contains(generationAuthority))
        #expect(statusCommand.contains(runtimeAuthority))
        #expect(statusCommand.contains(generationAuthority))
    }
}
