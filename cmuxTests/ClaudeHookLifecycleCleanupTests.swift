import Foundation
import Testing

/// Regression coverage for issue #7939: Claude cleanup hooks must target the
/// pane resolved from live identity, never a stale persisted session address.
@Suite(.serialized)
struct ClaudeHookLifecycleCleanupTests {
    private typealias Harness = ClaudeHookLiveDeliveryHarness
    private static let liveWorkspaceId = "11111111-1111-1111-1111-111111111111"
    private static let liveSurfaceId = "22222222-2222-2222-2222-222222222222"
    private static let otherSurfaceId = "55555555-5555-5555-5555-555555555555"
    private static let fallbackSurfaceId = "44444444-4444-4444-4444-444444444444"
    /// A polluted record must not let another agent's active pane make the
    /// live SessionEnd target look stale.
    @Test func sessionEndPollutedRecordStillClearsLivePane() throws {
        let context = try Harness.makeContext(name: "session-end-polluted-record")
        defer { context.cleanup() }
        let sessionId = "session-end-polluted-record-session"
        let now = Date().timeIntervalSince1970
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": Self.liveWorkspaceId,
                    "surfaceId": Self.otherSurfaceId,
                    "cwd": context.root.path,
                    "isRestorable": true,
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
            "activeSessionsBySurface": [
                Self.otherSurfaceId: [
                    "sessionId": "foreign-agent-session",
                    "updatedAt": now,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
            .write(to: context.storeURL)

        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [Self.liveWorkspaceId: [Self.liveSurfaceId, Self.otherSurfaceId]],
            pidTarget: (workspaceId: Self.liveWorkspaceId, surfaceId: Self.liveSurfaceId)
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = Self.liveWorkspaceId
        environment["CMUX_SURFACE_ID"] = Self.liveSurfaceId
        environment["CMUX_CLAUDE_PID"] = "43218"
        let result = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "session-end"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"SessionEnd","cwd":"\#(context.root.path)"}"#
        )
        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        assertSuccessfulHook(result)
        let commands = context.state.snapshot()
        #expect(
            commands.contains {
                $0.hasPrefix("clear_agent_pid claude_code ")
                    && $0.contains("--tab=\(Self.liveWorkspaceId)")
                    && $0.contains("--panel=\(Self.liveSurfaceId)")
            },
            "SessionEnd must clear the live pane despite the polluted record surface; saw \(commands)"
        )
        #expect(
            !commands.contains { $0.hasPrefix("clear_agent_pid claude_code ") && $0.contains("--panel=\(Self.otherSurfaceId)") },
            "SessionEnd must not clear the foreign pane the polluted record named; saw \(commands)"
        )
        #expect(
            commands.contains("clear_notifications --tab=\(Self.liveWorkspaceId) --panel=\(Self.liveSurfaceId)"),
            "A same-workspace live retarget must clear only the real pane; saw \(commands)"
        )
        #expect(
            !commands.contains("clear_notifications --tab=\(Self.liveWorkspaceId)"),
            "A polluted record must not make SessionEnd clear sibling panes; saw \(commands)"
        )
    }
    /// SessionEnd is the only hook after a pane move (Ctrl-C exit): its
    /// cleanup must clear status and notifications on the workspace that owns
    /// the pane NOW, not the consumed record's stale workspace — clearing the
    /// old workspace would leave the moved pane stuck and wipe unrelated
    /// panes' notifications there.
    @Test func sessionEndCleanupFollowsMovedPane() throws {
        let context = try Harness.makeContext(name: "session-end-moved-pane")
        defer { context.cleanup() }
        let sessionId = "session-end-moved-pane-session"
        let newWorkspaceId = "88888888-8888-8888-8888-888888888888"
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
        environment["CMUX_CLAUDE_PID"] = "43215"
        let result = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "session-end"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"SessionEnd","cwd":"\#(context.root.path)"}"#
        )
        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        assertSuccessfulHook(result)
        let commands = context.state.snapshot()
        #expect(
            commands.contains {
                $0.hasPrefix("clear_agent_pid claude_code ")
                    && $0.contains("--tab=\(newWorkspaceId)")
                    && $0.contains("--panel=\(Self.liveSurfaceId)")
            },
            "SessionEnd must clear agent pid/status on the pane's current workspace; saw \(commands)"
        )
        #expect(
            commands.contains("clear_notifications --tab=\(newWorkspaceId) --panel=\(Self.liveSurfaceId)"),
            "A re-homed SessionEnd clear must be scoped to the moved pane, not wipe sibling panes in the destination workspace; saw \(commands)"
        )
        #expect(
            !commands.contains("clear_notifications --tab=\(newWorkspaceId)"),
            "A re-homed SessionEnd must not clear the whole destination workspace; saw \(commands)"
        )
        #expect(
            !commands.contains { $0.hasPrefix("clear_notifications --tab=\(Self.liveWorkspaceId)") },
            "SessionEnd must not wipe the stale workspace's notifications; saw \(commands)"
        )
    }
    @Test func sessionEndClearStaysPaneScopedAfterRecordIsHealed() throws {
        let context = try Harness.makeContext(name: "session-end-healed-target")
        defer { context.cleanup() }
        let sessionId = "session-end-healed-target-session"
        try Harness.writeSessionStore(
            to: context.storeURL,
            sessionId: sessionId,
            workspaceId: Self.liveWorkspaceId,
            surfaceId: Self.liveSurfaceId,
            cwd: context.root.path
        )
        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [Self.liveWorkspaceId: [Self.liveSurfaceId, Self.otherSurfaceId]],
            pidTarget: (workspaceId: Self.liveWorkspaceId, surfaceId: Self.liveSurfaceId)
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = Self.liveWorkspaceId
        environment["CMUX_SURFACE_ID"] = Self.liveSurfaceId
        environment["CMUX_CLAUDE_PID"] = "43305"
        let result = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "session-end"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"SessionEnd","cwd":"\#(context.root.path)"}"#
        )
        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        assertSuccessfulHook(result)
        let commands = context.state.snapshot()
        #expect(commands.contains("clear_notifications --tab=\(Self.liveWorkspaceId) --panel=\(Self.liveSurfaceId)"))
        #expect(!commands.contains("clear_notifications --tab=\(Self.liveWorkspaceId)"))
    }
    /// Since #11976, the CLI records the new turn in the journal for the resolved pane
    /// instead of sending `clear_notifications`; the app reconciles attention from that event.
    @Test func promptSubmitTurnStartFollowsMovedPaneWithoutTouchingSiblings() throws {
        let context = try Harness.makeContext(name: "prompt-submit-pane-clear")
        defer { context.cleanup() }
        let sessionId = "prompt-submit-pane-clear-session"
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
            surfacesByWorkspace: [newWorkspaceId: [Self.liveSurfaceId, Self.otherSurfaceId]],
            pidTarget: (workspaceId: newWorkspaceId, surfaceId: Self.liveSurfaceId)
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = Self.liveWorkspaceId
        environment["CMUX_SURFACE_ID"] = Self.liveSurfaceId
        environment["CMUX_CLAUDE_PID"] = "43306"
        let result = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "prompt-submit"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-1","hook_event_name":"UserPromptSubmit","cwd":"\#(context.root.path)"}"#
        )
        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        assertSuccessfulHook(result)
        let commands = context.state.snapshot()
        let turnStarted = AgentJournalAppendCapture.first(
            in: commands, kind: "agent.turn.started", agentKey: "claude_code", sessionId: sessionId
        )
        #expect(turnStarted?.workspaceId == newWorkspaceId, "turn start must follow the moved pane; saw \(commands)")
        #expect(turnStarted?.surfaceId == Self.liveSurfaceId)
        #expect(
            !commands.contains { $0.contains("--panel=\(Self.otherSurfaceId)") },
            "a new turn must not touch sibling panes; saw \(commands)"
        )
        #expect(
            !commands.contains { $0.hasPrefix("clear_notifications --tab=\(newWorkspaceId)") && !$0.contains("--panel=") },
            "attention effects are pane-scoped, never workspace-wide; saw \(commands)"
        )
    }
    @Test func preToolUsePreservesProviderErrorNotification() throws {
        let context = try Harness.makeContext(name: "pre-tool-use-preserve-error")
        defer { context.cleanup() }
        let sessionId = "pre-tool-use-preserve-error-session"
        let now = Date().timeIntervalSince1970
        let record: [String: Any] = [
            "sessionId": sessionId,
            "workspaceId": Self.liveWorkspaceId,
            "surfaceId": Self.liveSurfaceId,
            "cwd": context.root.path,
            "isRestorable": true,
            "agentLifecycle": "needsInput",
            "activePromptDepth": 1,
            "activePromptTurnId": "turn-1",
            "activePromptTurnIds": ["turn-1"],
            "startedAt": now,
            "updatedAt": now,
        ]
        let store: [String: Any] = [
            "version": 1,
            "sessions": [sessionId: record],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
            .write(to: context.storeURL)
        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [Self.liveWorkspaceId: [Self.liveSurfaceId]],
            pidTarget: (workspaceId: Self.liveWorkspaceId, surfaceId: Self.liveSurfaceId)
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = Self.liveWorkspaceId
        environment["CMUX_SURFACE_ID"] = Self.liveSurfaceId
        environment["CMUX_CLAUDE_PID"] = "43307"
        let stopResult = Harness.runHookProcess(
            context: context, arguments: ["hooks", "claude", "stop"], environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"Stop","last_assistant_message":"Selected model is at capacity"}"#
        )
        assertSuccessfulHook(stopResult)
        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        #expect((try Harness.sessionRecord(in: context.storeURL, sessionId: sessionId))?["lastNotificationStatus"] as? String == "error")

        let result = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "pre-tool-use"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"\#(context.root.path)"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        assertSuccessfulHook(result)
        let commands = context.state.snapshot()
        #expect(
            !commands.contains("clear_notifications --tab=\(Self.liveWorkspaceId) --panel=\(Self.liveSurfaceId)"),
            "PreToolUse must not dismiss a provider-error notification from the same turn; saw \(commands)"
        )
    }

    /// A pane moves mid-turn: the next PreToolUse (which skips the pid/tty
    /// scan for frequency) must still re-home via the cheap `{surface_id}`
    /// probe instead of mutating — and re-recording via upsert — the old
    /// workspace's focused pane.
    @Test func preToolUseFollowsMovedPaneWithoutPidProbe() throws {
        let context = try Harness.makeContext(name: "pre-tool-use-rehome")
        defer { context.cleanup() }
        let sessionId = "pre-tool-use-rehome-session"
        let newWorkspaceId = "99999999-9999-9999-9999-999999999999"

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
                newWorkspaceId: [Self.liveSurfaceId, Self.otherSurfaceId],
            ],
            pidTarget: nil,
            surfaceTargets: [Self.liveSurfaceId: newWorkspaceId]
        )

        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = Self.liveWorkspaceId
        environment["CMUX_SURFACE_ID"] = Self.liveSurfaceId
        environment["CMUX_CLAUDE_PID"] = "43216"

        let result = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "pre-tool-use"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"\#(context.root.path)"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        assertSuccessfulHook(result)

        let commands = context.state.snapshot()
        #expect(
            commands.contains {
                $0.hasPrefix("set_status claude_code Running ")
                    && $0.contains("--tab=\(newWorkspaceId)")
                    && $0.contains("--panel=\(Self.liveSurfaceId)")
            },
            "PreToolUse status must follow the moved pane; saw \(commands)"
        )
        #expect(
            !commands.contains { $0.contains("--panel=\(Self.fallbackSurfaceId)") },
            "PreToolUse must not mutate the old workspace's focused pane; saw \(commands)"
        )
        let stateChanged = AgentJournalAppendCapture.first(
            in: commands, kind: "agent.state.changed", agentKey: "claude_code", sessionId: sessionId
        )
        #expect(stateChanged?.workspaceId == newWorkspaceId, "PreToolUse journal event must follow the moved pane; saw \(commands)")
        #expect(stateChanged?.surfaceId == Self.liveSurfaceId)
        #expect(
            !commands.contains { $0.hasPrefix("clear_notifications --tab=\(newWorkspaceId)") && !$0.contains("--panel=") },
            "attention effects are pane-scoped, never workspace-wide; saw \(commands)"
        )
        let record = try Harness.sessionRecord(in: context.storeURL, sessionId: sessionId)
        #expect(record?["workspaceId"] as? String == newWorkspaceId, "Session record must re-home, not re-pollute")
        #expect(record?["surfaceId"] as? String == Self.liveSurfaceId)
    }

    /// Older apps do not implement the live delivery-target resolver. A
    /// high-frequency PreToolUse hook must retain the legacy validated
    /// session/workspace/surface chain instead of treating the missing method
    /// as an identity rejection and silently dropping the lifecycle update.
    @Test func preToolUseWithoutResolverMethodKeepsLegacyRouting() throws {
        let context = try Harness.makeContext(name: "pre-tool-use-legacy-fallback")
        defer { context.cleanup() }
        let sessionId = "pre-tool-use-legacy-fallback-session"

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
        environment["CMUX_CLAUDE_PID"] = "43304"

        let result = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "pre-tool-use"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"\#(context.root.path)"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        assertSuccessfulHook(result)

        let commands = context.state.snapshot()
        #expect(
            commands.contains {
                $0.hasPrefix("set_status claude_code Running ")
                    && $0.contains("--tab=\(Self.liveWorkspaceId)")
                    && $0.contains("--panel=\(Self.liveSurfaceId)")
            },
            "PreToolUse must keep legacy routing when the resolver method is unavailable; saw \(commands)"
        )
    }

    /// The persisted session surface is stale/closed but the resolver
    /// recovers an authoritative live target from the spawn-time env surface:
    /// the blocking needs-input branch (AskUserQuestion) must use the
    /// resolved surface for its upsert, lifecycle, and notification — not
    /// re-prefer the stale record surface and pin the prompt on a dead pane.
    @Test func preToolUseNeedsInputUsesAuthoritativeResolvedSurface() throws {
        let context = try Harness.makeContext(name: "needs-input-live-surface")
        defer { context.cleanup() }
        let sessionId = "needs-input-live-surface-session"
        let closedSurfaceId = "66666666-6666-6666-6666-666666666666"

        try Harness.writeSessionStore(
            to: context.storeURL,
            sessionId: sessionId,
            workspaceId: Self.liveWorkspaceId,
            surfaceId: closedSurfaceId,
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
        environment["CMUX_CLAUDE_PID"] = "43217"

        let result = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "pre-tool-use"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","permission_mode":"bypassPermissions","cwd":"\#(context.root.path)"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        assertSuccessfulHook(result)

        let commands = context.state.snapshot()
        #expect(
            commands.contains {
                $0.hasPrefix("notify_target_async \(Self.liveWorkspaceId) \(Self.liveSurfaceId) ")
            },
            "Needs-input notification must target the authoritative resolved surface; saw \(commands)"
        )
        #expect(
            !commands.contains { $0.contains(closedSurfaceId) },
            "No mutation may target the stale/closed record surface; saw \(commands)"
        )
        let record = try Harness.sessionRecord(in: context.storeURL, sessionId: sessionId)
        #expect(
            record?["surfaceId"] as? String == Self.liveSurfaceId,
            "Upsert must heal the record to the resolved surface, not re-pollute it"
        )
    }

    @Test func preToolUseRejectsPollutedLiveRecord() throws {
        let context = try Harness.makeContext(name: "pre-tool-use-polluted-live-record")
        defer { context.cleanup() }
        let sessionId = "pre-tool-use-polluted-live-record-session"
        try Harness.writeSessionStore(
            to: context.storeURL,
            sessionId: sessionId,
            workspaceId: Self.liveWorkspaceId,
            surfaceId: Self.otherSurfaceId,
            cwd: context.root.path
        )
        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [Self.liveWorkspaceId: [Self.liveSurfaceId, Self.otherSurfaceId]],
            pidTarget: nil,
            surfaceTargets: [Self.liveSurfaceId: Self.liveWorkspaceId]
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = Self.liveWorkspaceId
        environment["CMUX_SURFACE_ID"] = Self.liveSurfaceId
        environment["CMUX_CLAUDE_PID"] = "43303"
        let result = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "pre-tool-use"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"\#(context.root.path)"}"#
        )
        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        assertSuccessfulHook(result)
        let commands = context.state.snapshot()
        #expect(!commands.contains { $0.hasPrefix("set_status ") || $0.hasPrefix("clear_notifications ") })
    }
    private func assertSuccessfulHook(_ result: ClaudeHookLiveDeliveryHarness.ProcessRunResult) {
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
    }
}
