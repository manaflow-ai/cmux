import Foundation
import Testing

/// Regression tests for https://github.com/manaflow-ai/cmux/issues/7939:
/// a Claude turn-complete notification must land on the pane whose agent
/// finished, resolved from LIVE identity at delivery time — never from a
/// polluted session record, a stale `debug.terminals` tty row, or spawn-time
/// `CMUX_WORKSPACE_ID`/`CMUX_SURFACE_ID` env captured before a pane move.
///
/// The CLI asks the app for the live target via the
/// `agent.resolve_delivery_target` control method:
///   - `{pid}` probe: which live surface owns the agent process right now.
///   - `{surface_id, workspace_id}` probe: which workspace currently hosts a
///     known surface (re-homes a moved pane, issue #5781).
/// When the method is unavailable (older app) the legacy resolution chain is
/// preserved unchanged.
@Suite(.serialized)
struct ClaudeHookLiveDeliveryTargetTests {
    private typealias Harness = ClaudeHookLiveDeliveryHarness

    private static let liveWorkspaceId = "11111111-1111-1111-1111-111111111111"
    private static let liveSurfaceId = "22222222-2222-2222-2222-222222222222"
    private static let otherWorkspaceId = "33333333-3333-3333-3333-333333333333"
    private static let otherSurfaceId = "55555555-5555-5555-5555-555555555555"
    private static let fallbackSurfaceId = "44444444-4444-4444-4444-444444444444"

    /// Two Claude agents in two workspaces: the session record for this agent
    /// was polluted to point at the OTHER agent's pane (issue #7391 drift).
    /// The live pid target must win and the record must self-heal.
    @Test func stopPrefersLivePidTargetOverPollutedSessionRecord() throws {
        let context = try Harness.makeContext(name: "live-pid-wins")
        defer { context.cleanup() }
        let sessionId = "polluted-record-session"

        try Harness.writeSessionStore(
            to: context.storeURL,
            sessionId: sessionId,
            workspaceId: Self.otherWorkspaceId,
            surfaceId: Self.otherSurfaceId,
            cwd: context.root.path
        )
        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [
                Self.liveWorkspaceId: [Self.liveSurfaceId],
                Self.otherWorkspaceId: [Self.otherSurfaceId],
            ],
            pidTarget: (workspaceId: Self.liveWorkspaceId, surfaceId: Self.liveSurfaceId)
        )

        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = Self.otherWorkspaceId
        environment["CMUX_SURFACE_ID"] = Self.otherSurfaceId
        environment["CMUX_CLAUDE_PID"] = "43210"

        let result = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "stop"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"Stop","cwd":"\#(context.root.path)","last_assistant_message":"All done"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        assertSuccessfulHook(result)

        let commands = context.state.snapshot()
        #expect(
            commands.contains { $0.hasPrefix("notify_target_async \(Self.liveWorkspaceId) \(Self.liveSurfaceId) ") },
            "Turn-complete notification must target the live pane resolved from the agent pid; saw \(commands)"
        )
        #expect(
            !commands.contains { $0.hasPrefix("notify_target_async \(Self.otherWorkspaceId)") },
            "Notification must not follow the polluted session record to another workspace; saw \(commands)"
        )
        #expect(
            commands.contains {
                $0.hasPrefix("set_status claude_code Idle ")
                    && $0.contains("--tab=\(Self.liveWorkspaceId)")
                    && $0.contains("--panel=\(Self.liveSurfaceId)")
            },
            "Status pill must follow the live pane; saw \(commands)"
        )
        let record = try Harness.sessionRecord(in: context.storeURL, sessionId: sessionId)
        #expect(record?["workspaceId"] as? String == Self.liveWorkspaceId, "Session record workspace must self-heal")
        #expect(record?["surfaceId"] as? String == Self.liveSurfaceId, "Session record surface must self-heal")
    }

    /// Pane moved to another workspace after the session record was written
    /// (issue #5781). Without a pid answer, the recorded surface must be
    /// re-homed to its CURRENT workspace instead of falling back to the old
    /// workspace's focused surface.
    @Test func stopFollowsMovedPaneToCurrentWorkspace() throws {
        let context = try Harness.makeContext(name: "moved-pane")
        defer { context.cleanup() }
        let sessionId = "moved-pane-session"
        let newWorkspaceId = "77777777-7777-7777-7777-777777777777"

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
                Self.liveWorkspaceId: [Self.fallbackSurfaceId],
                newWorkspaceId: [Self.liveSurfaceId],
            ],
            pidTarget: nil,
            surfaceTargets: [Self.liveSurfaceId: newWorkspaceId]
        )

        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = Self.liveWorkspaceId
        environment["CMUX_SURFACE_ID"] = Self.liveSurfaceId
        environment["CMUX_CLAUDE_PID"] = "43211"

        let result = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "stop"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"Stop","cwd":"\#(context.root.path)","last_assistant_message":"All done"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        assertSuccessfulHook(result)

        let commands = context.state.snapshot()
        #expect(
            commands.contains { $0.hasPrefix("notify_target_async \(newWorkspaceId) \(Self.liveSurfaceId) ") },
            "Notification must follow the moved pane to its current workspace; saw \(commands)"
        )
        #expect(
            !commands.contains { $0.contains("notify_target_async \(Self.liveWorkspaceId) \(Self.fallbackSurfaceId)") },
            "Notification must not land on the old workspace's focused surface; saw \(commands)"
        )
        let record = try Harness.sessionRecord(in: context.storeURL, sessionId: sessionId)
        #expect(record?["workspaceId"] as? String == newWorkspaceId, "Session record must re-home to the pane's current workspace")
        #expect(record?["surfaceId"] as? String == Self.liveSurfaceId)
    }

    /// The workspace listing lags the app's panel map: the recorded surface is
    /// not in the resolved workspace's listing, yet the app confirms the same
    /// workspace still owns it. The identity surface must win over the
    /// focused-surface fallback even when the re-homed workspace is unchanged.
    @Test func stopPrefersRehomedIdentitySurfaceInSameWorkspace() throws {
        let context = try Harness.makeContext(name: "same-workspace-rehome")
        defer { context.cleanup() }
        let sessionId = "same-workspace-rehome-session"

        try Harness.writeSessionStore(
            to: context.storeURL,
            sessionId: sessionId,
            workspaceId: Self.liveWorkspaceId,
            surfaceId: Self.liveSurfaceId,
            cwd: context.root.path
        )
        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [Self.liveWorkspaceId: [Self.fallbackSurfaceId]],
            pidTarget: nil,
            surfaceTargets: [Self.liveSurfaceId: Self.liveWorkspaceId]
        )

        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = Self.liveWorkspaceId
        environment["CMUX_SURFACE_ID"] = Self.liveSurfaceId
        environment["CMUX_CLAUDE_PID"] = "43214"

        let result = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "stop"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"Stop","cwd":"\#(context.root.path)","last_assistant_message":"All done"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        assertSuccessfulHook(result)

        let commands = context.state.snapshot()
        #expect(
            commands.contains { $0.hasPrefix("notify_target_async \(Self.liveWorkspaceId) \(Self.liveSurfaceId) ") },
            "Notification must land on the identity surface confirmed by the app, not the focused-surface fallback; saw \(commands)"
        )
        #expect(
            !commands.contains { $0.contains("notify_target_async \(Self.liveWorkspaceId) \(Self.fallbackSurfaceId)") },
            "Notification must not land on the focused-surface fallback when the app confirms the identity surface; saw \(commands)"
        )
    }

    /// SessionStart with a stale `debug.terminals` tty row pointing at another
    /// agent's pane (issue #7391 genesis): the live pid target must win so the
    /// session record is born correct.
    @Test func sessionStartPrefersLivePidTargetOverStaleTTYRow() throws {
        let context = try Harness.makeContext(name: "stale-tty")
        defer { context.cleanup() }
        let sessionId = "stale-tty-session"
        let ttyName = "ttys-stale-row"

        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [
                Self.liveWorkspaceId: [Self.liveSurfaceId],
                Self.otherWorkspaceId: [Self.otherSurfaceId],
            ],
            pidTarget: (workspaceId: Self.liveWorkspaceId, surfaceId: Self.liveSurfaceId),
            ttyRows: [(tty: ttyName, workspaceId: Self.otherWorkspaceId, surfaceId: Self.otherSurfaceId)]
        )

        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = Self.liveWorkspaceId
        environment["CMUX_SURFACE_ID"] = Self.liveSurfaceId
        environment["CMUX_CLI_TTY_NAME"] = ttyName
        environment["CMUX_CLAUDE_PID"] = "43212"
        environment["CMUX_AGENT_LAUNCH_KIND"] = "claude"
        environment["CMUX_AGENT_LAUNCH_EXECUTABLE"] = "/usr/local/bin/claude"
        environment["CMUX_AGENT_LAUNCH_CWD"] = context.root.path

        let result = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "session-start"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","source":"clear","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        assertSuccessfulHook(result)

        let commands = context.state.snapshot()
        let resumeBinding = try #require(
            Harness.resumeBindingParams(in: context).last,
            "Expected SessionStart to publish a resume binding, saw \(commands)"
        )
        #expect(
            resumeBinding["surface_id"] as? String == Self.liveSurfaceId,
            "Resume binding must target the pane that owns the live agent pid, not the stale tty row; params=\(resumeBinding)"
        )
        #expect(
            commands.contains {
                $0.hasPrefix("set_status claude_code Running ")
                    && $0.contains("--tab=\(Self.liveWorkspaceId)")
                    && $0.contains("--panel=\(Self.liveSurfaceId)")
            },
            "Visible status must target the live pane; saw \(commands)"
        )
        let record = try Harness.sessionRecord(in: context.storeURL, sessionId: sessionId)
        #expect(record?["workspaceId"] as? String == Self.liveWorkspaceId)
        #expect(record?["surfaceId"] as? String == Self.liveSurfaceId)
    }


    /// Older app without `agent.resolve_delivery_target`: the legacy chain
    /// (session record validated against live workspaces) keeps working.
    @Test func stopWithoutResolverMethodKeepsLegacyRouting() throws {
        let context = try Harness.makeContext(name: "legacy-fallback")
        defer { context.cleanup() }
        let sessionId = "legacy-session"

        try Harness.writeSessionStore(
            to: context.storeURL,
            sessionId: sessionId,
            workspaceId: Self.liveWorkspaceId,
            surfaceId: Self.liveSurfaceId,
            cwd: context.root.path
        )
        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [Self.liveWorkspaceId: [Self.liveSurfaceId]],
            pidTarget: nil,
            resolverMethodAvailable: false
        )

        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = Self.liveWorkspaceId
        environment["CMUX_SURFACE_ID"] = Self.liveSurfaceId
        environment["CMUX_CLAUDE_PID"] = "43213"

        let result = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "stop"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"Stop","cwd":"\#(context.root.path)","last_assistant_message":"All done"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        assertSuccessfulHook(result)

        let commands = context.state.snapshot()
        #expect(
            commands.contains { $0.hasPrefix("notify_target_async \(Self.liveWorkspaceId) \(Self.liveSurfaceId) ") },
            "Legacy routing must keep working when the resolver method is unavailable; saw \(commands)"
        )
    }

    private func assertSuccessfulHook(_ result: ClaudeHookLiveDeliveryHarness.ProcessRunResult) {
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
    }
}
