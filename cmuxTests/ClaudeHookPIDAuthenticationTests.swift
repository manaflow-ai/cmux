import Foundation
import Testing

@Suite(.serialized)
struct ClaudeHookPIDAuthenticationTests {
    private typealias Harness = ClaudeHookLiveDeliveryHarness

    private static let liveWorkspaceId = "11111111-1111-1111-1111-111111111111"
    private static let liveSurfaceId = "22222222-2222-2222-2222-222222222222"
    private static let otherWorkspaceId = "33333333-3333-3333-3333-333333333333"
    private static let otherSurfaceId = "55555555-5555-5555-5555-555555555555"

    @Test("A persisted PID is never promoted to live identity")
    func persistedPIDDoesNotOverrideCurrentHookIdentity() throws {
        let context = try Harness.makeContext(name: "persisted-pid-not-authoritative")
        defer { context.cleanup() }
        let sessionId = "persisted-pid-session"

        try Harness.writeSessionStore(
            to: context.storeURL,
            sessionId: sessionId,
            workspaceId: Self.liveWorkspaceId,
            surfaceId: Self.liveSurfaceId,
            cwd: context.root.path,
            pid: 43299
        )
        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [
                Self.liveWorkspaceId: [Self.liveSurfaceId],
                Self.otherWorkspaceId: [Self.otherSurfaceId],
            ],
            pidTarget: (workspaceId: Self.otherWorkspaceId, surfaceId: Self.otherSurfaceId)
        )

        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = Self.liveWorkspaceId
        environment["CMUX_SURFACE_ID"] = Self.liveSurfaceId

        let result = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "stop"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"Stop","cwd":"\#(context.root.path)","last_assistant_message":"All done"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        assertSuccessfulHook(result)
        let commands = context.state.snapshot()
        #expect(commands.contains { $0.hasPrefix("notify_target_async \(Self.liveWorkspaceId) \(Self.liveSurfaceId) ") })
        #expect(!commands.contains { $0.hasPrefix("notify_target_async \(Self.otherWorkspaceId)") })
    }

    @Test("A current PID failure does not fall back to uncorroborated records")
    func currentPIDFailureFailsClosedWithoutSurfaceCorroboration() throws {
        let context = try Harness.makeContext(name: "current-pid-fails-closed")
        defer { context.cleanup() }
        let sessionId = "current-pid-fails-closed-session"

        try Harness.writeSessionStore(
            to: context.storeURL,
            sessionId: sessionId,
            workspaceId: Self.liveWorkspaceId,
            surfaceId: Self.liveSurfaceId,
            cwd: context.root.path
        )
        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [
                Self.liveWorkspaceId: [Self.liveSurfaceId],
                Self.otherWorkspaceId: [Self.otherSurfaceId],
            ],
            pidTarget: nil,
            surfaceTargets: [Self.otherSurfaceId: Self.otherWorkspaceId]
        )

        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = Self.otherWorkspaceId
        environment["CMUX_SURFACE_ID"] = Self.otherSurfaceId
        environment["CMUX_CLAUDE_PID"] = "43300"

        let result = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "stop"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"Stop","cwd":"\#(context.root.path)","last_assistant_message":"All done"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        assertSuccessfulHook(result)
        #expect(!context.state.snapshot().contains { $0.hasPrefix("notify_target_async ") })
    }

    @Test("Fresh SessionStart rejects spawn-environment identity when PID lookup has no TTY")
    func freshSessionStartRejectsUnverifiedInvocationSurface() throws {
        let context = try Harness.makeContext(name: "fresh-session-surface-corroboration")
        defer { context.cleanup() }
        let sessionId = "fresh-session-surface-corroboration-session"

        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [Self.liveWorkspaceId: [Self.liveSurfaceId]],
            pidTarget: nil,
            surfaceTargets: [Self.liveSurfaceId: Self.liveWorkspaceId]
        )

        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = Self.liveWorkspaceId
        environment["CMUX_SURFACE_ID"] = Self.liveSurfaceId
        environment["CMUX_CLAUDE_PID"] = "43301"

        let result = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "session-start"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","source":"clear","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        assertSuccessfulHook(result)
        #expect((try? Harness.sessionRecord(in: context.storeURL, sessionId: sessionId)) == nil)
    }

    @Test("SessionEnd does not mutate a record rejected by live identity")
    func sessionEndSuppressesVisibleCleanupAfterIdentityRejection() throws {
        let context = try Harness.makeContext(name: "session-end-identity-rejected")
        defer { context.cleanup() }
        let sessionId = "session-end-identity-rejected-session"
        try Harness.writeSessionStore(
            to: context.storeURL,
            sessionId: sessionId,
            workspaceId: Self.liveWorkspaceId,
            surfaceId: Self.liveSurfaceId,
            cwd: context.root.path
        )
        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [
                Self.liveWorkspaceId: [Self.liveSurfaceId],
                Self.otherWorkspaceId: [Self.otherSurfaceId],
            ],
            pidTarget: nil,
            surfaceTargets: [Self.otherSurfaceId: Self.otherWorkspaceId]
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = Self.otherWorkspaceId
        environment["CMUX_SURFACE_ID"] = Self.otherSurfaceId
        environment["CMUX_CLAUDE_PID"] = "43302"
        let result = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "session-end"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"SessionEnd","cwd":"\#(context.root.path)"}"#
        )
        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        assertSuccessfulHook(result)
        let commands = context.state.snapshot()
        #expect(!commands.contains { $0.hasPrefix("clear_agent_pid ") })
        #expect(!commands.contains { $0.hasPrefix("clear_notifications ") })
        #expect(try Harness.sessionRecord(in: context.storeURL, sessionId: sessionId) != nil)
    }

    private func assertSuccessfulHook(_ result: Harness.ProcessRunResult) {
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
    }
}
