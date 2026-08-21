import Dispatch
import Foundation
import Testing

/// Behavioral coverage for the agent-notification gating signal the Claude hook
/// forwards to the app: the `notify_target_async` payload's `c=<category>;p=<0|1>`
/// meta segment, and the `hadPendingBackgroundWorkAtStop` cache the idle_prompt
/// path reads. Drives the real CLI against the mock socket server, exactly like
/// `ClaudeNotificationStatusLifecycleTests`.
@Suite(.serialized)
struct ClaudeBackgroundWorkNotifyTests {
    private func notifyLine(_ snapshot: [String], containing needle: String) -> String? {
        snapshot.first { $0.hasPrefix("notify_target_async ") && $0.contains(needle) }
    }

    private func statusLine(_ snapshot: [String], value: String) -> String? {
        snapshot.first { $0.hasPrefix("set_status claude_code \(value) ") }
    }

    private func lifecycleLine(_ snapshot: [String], value: String) -> String? {
        snapshot.first { $0.hasPrefix("set_agent_lifecycle claude_code \(value) ") }
    }

    /// The pane state a hook sequence LEFT behind: the socket verbs are
    /// last-write-wins, so only the final `set_status` / `set_agent_lifecycle`
    /// of a run describes what the sidebar ends up showing.
    private func lastLine(_ snapshot: [String], prefix: String) -> String? {
        snapshot.last { $0.hasPrefix(prefix) }
    }

    private func runStopHook(
        name: String,
        sessionId: String,
        stdin: String
    ) throws -> (snapshot: [String], cachedPending: Bool?) {
        let harness = ClaudeHookSurfaceResolutionSwiftTests()
        let context = try harness.makeClaudeHookContext(name: name)
        let storeURL = context.root.appendingPathComponent("claude-hook-sessions.json")
        let handled = harness.startClaudeSurfaceResolutionServer(
            context: context,
            surfaces: [(context.surfaceId, "surface:1", true)],
            ttyName: "ttys-\(name)",
            ttySurfaceId: context.surfaceId
        )
        let environment = harness.claudeHookEnvironment(
            context: context,
            surfaceId: context.surfaceId,
            ttyName: "ttys-\(name)",
            storeURL: storeURL
        )
        let result = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "stop"],
            environment: environment,
            standardInput: stdin,
            timeout: 5
        )
        #expect(handled.wait(timeout: .now() + 5) == .success)
        harness.assertSuccessfulHook(result)
        let snapshot = context.state.snapshot()
        // Read the cached flag from the store BEFORE cleanup deletes the temp dir.
        let cached = cachedPending(storeURL, sessionId: sessionId)
        context.cleanup()
        return (snapshot, cached)
    }

    private func cachedPending(_ storeURL: URL, sessionId: String) -> Bool? {
        guard let data = try? Data(contentsOf: storeURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = obj["sessions"] as? [String: Any],
              let record = sessions[sessionId] as? [String: Any] else { return nil }
        return record["hadPendingBackgroundWorkAtStop"] as? Bool
    }

    @Test func stopWithRunningBackgroundTaskTagsPendingAndCaches() throws {
        let session = "bg-running-session"
        let stdin = #"""
        {"session_id":"\#(session)","cwd":"/tmp/x","hook_event_name":"Stop","last_assistant_message":"ok","background_tasks":[{"id":"t1","type":"shell","status":"running","description":"build","command":"sleep 1"}],"session_crons":[]}
        """#
        let (snapshot, cached) = try runStopHook(name: "bg-run", sessionId: session, stdin: stdin)
        #expect(
            notifyLine(snapshot, containing: "c=turn-complete;p=1") != nil,
            "Stop with a running background task must tag the done-ping pending; saw \(snapshot)"
        )
        #expect(cached == true)
        // Sidebar pill must not say "Idle" while background work is live.
        #expect(statusLine(snapshot, value: "Running") != nil,
                "Pending stop must show a Running pill, not Idle; saw \(snapshot)")
        #expect(statusLine(snapshot, value: "Idle") == nil)
        // And the hibernation lifecycle must stay non-idle so the planner can't
        // SIGTERM the live background task.
        #expect(lifecycleLine(snapshot, value: "running") != nil,
                "Pending stop must publish a running lifecycle; saw \(snapshot)")
        #expect(lifecycleLine(snapshot, value: "idle") == nil)
    }

    @Test func stopWithEmptyArraysTagsIdleAndCachesFalse() throws {
        let session = "bg-empty-session"
        let stdin = #"""
        {"session_id":"\#(session)","cwd":"/tmp/x","hook_event_name":"Stop","last_assistant_message":"ok","background_tasks":[],"session_crons":[]}
        """#
        let (snapshot, cached) = try runStopHook(name: "bg-empty", sessionId: session, stdin: stdin)
        #expect(notifyLine(snapshot, containing: "c=turn-complete;p=0") != nil,
                "Truly-idle stop must tag pending=0; saw \(snapshot)")
        #expect(cached == false)
        // Truly-idle turn end keeps the "Idle" pill and the hibernatable lifecycle.
        #expect(statusLine(snapshot, value: "Idle") != nil,
                "Truly-idle stop must show the Idle pill; saw \(snapshot)")
        #expect(lifecycleLine(snapshot, value: "idle") != nil,
                "Truly-idle stop must publish an idle lifecycle; saw \(snapshot)")
    }

    @Test func stopWithPendingCronTagsPending() throws {
        let session = "bg-cron-session"
        let stdin = #"""
        {"session_id":"\#(session)","cwd":"/tmp/x","hook_event_name":"Stop","last_assistant_message":"ok","background_tasks":[],"session_crons":[{"id":"c1"}]}
        """#
        let (snapshot, _) = try runStopHook(name: "bg-cron", sessionId: session, stdin: stdin)
        #expect(notifyLine(snapshot, containing: "c=turn-complete;p=1") != nil,
                "A pending scheduled wakeup must tag pending=1; saw \(snapshot)")
    }

    @Test func stopWithoutBackgroundKeysOldClientTagsNotPending() throws {
        // claude < 2.1.145 omits both arrays entirely: preserve prior behavior.
        let session = "bg-oldclient-session"
        let stdin = #"""
        {"session_id":"\#(session)","cwd":"/tmp/x","hook_event_name":"Stop","last_assistant_message":"ok"}
        """#
        let (snapshot, cached) = try runStopHook(name: "bg-old", sessionId: session, stdin: stdin)
        #expect(notifyLine(snapshot, containing: "c=turn-complete;p=0") != nil,
                "Absent arrays (old client) must behave as not-pending; saw \(snapshot)")
        #expect(cached == false)
    }

    @Test func notificationPermissionPromptTagsNeedsPermission() throws {
        let harness = ClaudeHookSurfaceResolutionSwiftTests()
        let context = try harness.makeClaudeHookContext(name: "notif-perm")
        defer { context.cleanup() }
        let handled = harness.startClaudeSurfaceResolutionServer(
            context: context,
            surfaces: [(context.surfaceId, "surface:1", true)],
            ttyName: "ttys-notif-perm",
            ttySurfaceId: context.surfaceId
        )
        let environment = harness.claudeHookEnvironment(
            context: context,
            surfaceId: context.surfaceId,
            ttyName: "ttys-notif-perm",
            storeURL: context.root.appendingPathComponent("claude-hook-sessions.json")
        )
        let result = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "notification"],
            environment: environment,
            standardInput: #"{"session_id":"notif-perm-session","cwd":"/tmp/x","hook_event_name":"Notification","message":"Claude needs your permission","notification_type":"permission_prompt"}"#,
            timeout: 5
        )
        #expect(handled.wait(timeout: .now() + 5) == .success)
        harness.assertSuccessfulHook(result)
        #expect(notifyLine(context.state.snapshot(), containing: "c=needs-permission;p=0") != nil,
                "permission_prompt must tag needs-permission; saw \(context.state.snapshot())")
    }

    @Test func notificationWithoutTypeFallsBackToCueClassification() throws {
        // Older claude clients omit notification_type; the permission cue in the
        // message must still gate the alert under "Agent Needs Permission".
        let harness = ClaudeHookSurfaceResolutionSwiftTests()
        let context = try harness.makeClaudeHookContext(name: "notif-cue")
        defer { context.cleanup() }
        let handled = harness.startClaudeSurfaceResolutionServer(
            context: context,
            surfaces: [(context.surfaceId, "surface:1", true)],
            ttyName: "ttys-notif-cue",
            ttySurfaceId: context.surfaceId
        )
        let environment = harness.claudeHookEnvironment(
            context: context,
            surfaceId: context.surfaceId,
            ttyName: "ttys-notif-cue",
            storeURL: context.root.appendingPathComponent("claude-hook-sessions.json")
        )
        let result = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "notification"],
            environment: environment,
            standardInput: #"{"session_id":"notif-cue-session","cwd":"/tmp/x","hook_event_name":"Notification","message":"Claude needs your permission to run a tool"}"#,
            timeout: 5
        )
        #expect(handled.wait(timeout: .now() + 5) == .success)
        harness.assertSuccessfulHook(result)
        #expect(notifyLine(context.state.snapshot(), containing: "c=needs-permission;p=0") != nil,
                "Permission-cue notification without notification_type must tag needs-permission; saw \(context.state.snapshot())")
    }

    @Test func idlePromptAfterPendingStopReadsCachedPending() throws {
        // Stop (pending) then idle_prompt on the SAME session: the idle nag must
        // inherit the cached pending flag because its payload lacks background_tasks.
        let session = "idle-after-pending"
        let harness = ClaudeHookSurfaceResolutionSwiftTests()
        let context = try harness.makeClaudeHookContext(name: "idle-pending")
        defer { context.cleanup() }
        let storeURL = context.root.appendingPathComponent("claude-hook-sessions.json")
        let handled = harness.startClaudeSurfaceResolutionServer(
            context: context,
            surfaces: [(context.surfaceId, "surface:1", true)],
            ttyName: "ttys-idle-pending",
            ttySurfaceId: context.surfaceId
        )
        let environment = harness.claudeHookEnvironment(
            context: context,
            surfaceId: context.surfaceId,
            ttyName: "ttys-idle-pending",
            storeURL: storeURL
        )
        let stopResult = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "stop"],
            environment: environment,
            standardInput: #"{"session_id":"\#(session)","cwd":"/tmp/x","hook_event_name":"Stop","last_assistant_message":"ok","background_tasks":[{"id":"t1","type":"shell","status":"running","description":"build","command":"sleep 1"}],"session_crons":[]}"#,
            timeout: 5
        )
        #expect(handled.wait(timeout: .now() + 5) == .success)
        harness.assertSuccessfulHook(stopResult)

        let notifResult = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "notification"],
            environment: environment,
            standardInput: #"{"session_id":"\#(session)","cwd":"/tmp/x","hook_event_name":"Notification","message":"Claude is waiting for your input","notification_type":"idle_prompt"}"#,
            timeout: 5
        )
        #expect(handled.wait(timeout: .now() + 5) == .success)
        harness.assertSuccessfulHook(notifResult)
        let snapshot = context.state.snapshot()
        #expect(notifyLine(snapshot, containing: "c=idle-reminder;p=1") != nil,
                "idle_prompt after a pending stop must inherit pending=1; saw \(snapshot)")
        // A pending idle reminder must not flip the pane to "Needs input": the
        // banner is suppressed app-side and the pane is still Running.
        #expect(statusLine(snapshot, value: "Needs input") == nil,
                "Pending idle_prompt must not set a Needs input pill; saw \(snapshot)")
    }

    @Test func idlePromptAfterIdleStopTagsNotPending() throws {
        let session = "idle-after-idle"
        let harness = ClaudeHookSurfaceResolutionSwiftTests()
        let context = try harness.makeClaudeHookContext(name: "idle-idle")
        defer { context.cleanup() }
        let storeURL = context.root.appendingPathComponent("claude-hook-sessions.json")
        let handled = harness.startClaudeSurfaceResolutionServer(
            context: context,
            surfaces: [(context.surfaceId, "surface:1", true)],
            ttyName: "ttys-idle-idle",
            ttySurfaceId: context.surfaceId
        )
        let environment = harness.claudeHookEnvironment(
            context: context,
            surfaceId: context.surfaceId,
            ttyName: "ttys-idle-idle",
            storeURL: storeURL
        )
        let stopResult = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "stop"],
            environment: environment,
            standardInput: #"{"session_id":"\#(session)","cwd":"/tmp/x","hook_event_name":"Stop","last_assistant_message":"ok","background_tasks":[],"session_crons":[]}"#,
            timeout: 5
        )
        #expect(handled.wait(timeout: .now() + 5) == .success)
        harness.assertSuccessfulHook(stopResult)
        let notifResult = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "notification"],
            environment: environment,
            standardInput: #"{"session_id":"\#(session)","cwd":"/tmp/x","hook_event_name":"Notification","message":"Claude is waiting for your input","notification_type":"idle_prompt"}"#,
            timeout: 5
        )
        #expect(handled.wait(timeout: .now() + 5) == .success)
        harness.assertSuccessfulHook(notifResult)
        let snapshot = context.state.snapshot()
        #expect(notifyLine(snapshot, containing: "c=idle-reminder;p=0") != nil,
                "idle_prompt after an idle stop must tag pending=0; saw \(snapshot)")
        // With no pending work this is a real waiting state, so the pill flips.
        #expect(statusLine(snapshot, value: "Needs input") != nil,
                "Idle idle_prompt must still set the Needs input pill; saw \(snapshot)")
    }

    @Test func agentCompletedNotificationLeavesPaneRunning() throws {
        // `agent_completed` is Claude Code's user-facing form of SubagentStop: a
        // Task subagent finished while the parent agent keeps working on its
        // turn. It is progress, not an attention state, so it must not flip the
        // pane to "Needs input" (which makes the workspace infer
        // needs-attention) and must not fire a turn-complete ping.
        // https://github.com/manaflow-ai/cmux/issues/10233
        let harness = ClaudeHookSurfaceResolutionSwiftTests()
        let context = try harness.makeClaudeHookContext(name: "notif-subagent")
        defer { context.cleanup() }
        let handled = harness.startClaudeSurfaceResolutionServer(
            context: context,
            surfaces: [(context.surfaceId, "surface:1", true)],
            ttyName: "ttys-notif-subagent",
            ttySurfaceId: context.surfaceId
        )
        let environment = harness.claudeHookEnvironment(
            context: context,
            surfaceId: context.surfaceId,
            ttyName: "ttys-notif-subagent",
            storeURL: context.root.appendingPathComponent("claude-hook-sessions.json")
        )
        // Seed the working pane the parent agent is mid-turn in, so the
        // assertions below distinguish "left the pane Running" from "published
        // some other state" or "published nothing at all".
        let promptResult = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "prompt-submit"],
            environment: environment,
            standardInput: #"{"session_id":"notif-subagent-session","cwd":"/tmp/x","hook_event_name":"UserPromptSubmit","prompt":"review this"}"#,
            timeout: 5
        )
        #expect(handled.wait(timeout: .now() + 5) == .success)
        harness.assertSuccessfulHook(promptResult)
        let result = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "notification"],
            environment: environment,
            standardInput: #"{"session_id":"notif-subagent-session","cwd":"/tmp/x","hook_event_name":"Notification","message":"Agent code-reviewer completed","notification_type":"agent_completed"}"#,
            timeout: 5
        )
        #expect(handled.wait(timeout: .now() + 5) == .success)
        harness.assertSuccessfulHook(result)
        let snapshot = context.state.snapshot()
        #expect(statusLine(snapshot, value: "Needs input") == nil,
                "A finished subagent must not set the Needs input pill; saw \(snapshot)")
        #expect(lifecycleLine(snapshot, value: "needsInput") == nil,
                "A finished subagent must not publish a needs-input lifecycle; saw \(snapshot)")
        #expect(snapshot.first { $0.hasPrefix("notify_target_async ") } == nil,
                "A finished subagent must not fire a turn-complete ping; saw \(snapshot)")
        let lastStatus = try #require(
            lastLine(snapshot, prefix: "set_status claude_code "),
            "Expected the seeded Running pill in \(snapshot)"
        )
        #expect(lastStatus.hasPrefix("set_status claude_code Running "),
                "The pane must be left Running after a subagent finishes; saw \(lastStatus)")
        let lastLifecycle = try #require(
            lastLine(snapshot, prefix: "set_agent_lifecycle claude_code "),
            "Expected the seeded running lifecycle in \(snapshot)"
        )
        #expect(lastLifecycle.hasPrefix("set_agent_lifecycle claude_code running "),
                "The lifecycle must be left running after a subagent finishes; saw \(lastLifecycle)")
    }

    @Test func agentCompletedNotificationDoesNotSwallowTheParentStop() throws {
        // The subagent that finishes LAST still hands the turn back to the
        // parent, whose own Stop owns the real turn-complete transition. The
        // suppressed `agent_completed` must leave that signal intact.
        // https://github.com/manaflow-ai/cmux/issues/10233
        let session = "subagent-then-stop"
        let harness = ClaudeHookSurfaceResolutionSwiftTests()
        let context = try harness.makeClaudeHookContext(name: "notif-subagent-stop")
        defer { context.cleanup() }
        let handled = harness.startClaudeSurfaceResolutionServer(
            context: context,
            surfaces: [(context.surfaceId, "surface:1", true)],
            ttyName: "ttys-notif-subagent-stop",
            ttySurfaceId: context.surfaceId
        )
        let environment = harness.claudeHookEnvironment(
            context: context,
            surfaceId: context.surfaceId,
            ttyName: "ttys-notif-subagent-stop",
            storeURL: context.root.appendingPathComponent("claude-hook-sessions.json")
        )
        let notifResult = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "notification"],
            environment: environment,
            standardInput: #"{"session_id":"\#(session)","cwd":"/tmp/x","hook_event_name":"Notification","message":"Agent code-reviewer completed","notification_type":"agent_completed"}"#,
            timeout: 5
        )
        #expect(handled.wait(timeout: .now() + 5) == .success)
        harness.assertSuccessfulHook(notifResult)
        let stopResult = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "stop"],
            environment: environment,
            standardInput: #"{"session_id":"\#(session)","cwd":"/tmp/x","hook_event_name":"Stop","last_assistant_message":"ok","background_tasks":[],"session_crons":[]}"#,
            timeout: 5
        )
        #expect(handled.wait(timeout: .now() + 5) == .success)
        harness.assertSuccessfulHook(stopResult)
        let snapshot = context.state.snapshot()
        // Exactly one ping, and it carries the parent's own last assistant
        // message — asserting mere presence would be satisfied by the
        // subagent's ping, which is the thing this fix removes.
        let notifyLines = snapshot.filter { $0.hasPrefix("notify_target_async ") }
        #expect(notifyLines.count == 1,
                "Only the parent Stop may ping for this turn; saw \(notifyLines)")
        #expect(notifyLines.first?.contains("|ok|c=turn-complete;p=0") == true,
                "The surviving ping must be the parent Stop's turn-complete; saw \(notifyLines)")
        let lastStatus = try #require(
            lastLine(snapshot, prefix: "set_status claude_code "),
            "Expected the parent Stop's pill in \(snapshot)"
        )
        #expect(lastStatus.hasPrefix("set_status claude_code Idle "),
                "The parent Stop must leave the Idle pill; saw \(lastStatus)")
        let lastLifecycle = try #require(
            lastLine(snapshot, prefix: "set_agent_lifecycle claude_code "),
            "Expected the parent Stop's lifecycle in \(snapshot)"
        )
        #expect(lastLifecycle.hasPrefix("set_agent_lifecycle claude_code idle "),
                "The parent Stop must leave an idle lifecycle; saw \(lastLifecycle)")
    }
}
