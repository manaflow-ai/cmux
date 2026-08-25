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

    private func journalEvent(
        _ snapshot: [String],
        kind: String,
        pendingWork: Bool? = nil
    ) -> AgentJournalAppendCapture? {
        AgentJournalAppendCapture.captures(in: snapshot).first { capture in
            capture.kind == kind
                && capture.agentKey == "claude_code"
                && (pendingWork == nil || capture.pendingWork == pendingWork)
        }
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
        // And the journaled turn boundary must carry pending_work=true so the
        // reduced lifecycle stays running (non-hibernatable) while the
        // background task is live.
        #expect(journalEvent(snapshot, kind: "agent.turn.completed", pendingWork: true) != nil,
                "Pending stop must journal a pending turn completion; saw \(snapshot)")
        #expect(journalEvent(snapshot, kind: "agent.turn.completed", pendingWork: false) == nil)
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
        // Truly-idle turn end keeps the "Idle" pill and journals a
        // non-pending turn completion (which reduces to the hibernatable
        // idle lifecycle).
        #expect(statusLine(snapshot, value: "Idle") != nil,
                "Truly-idle stop must show the Idle pill; saw \(snapshot)")
        #expect(journalEvent(snapshot, kind: "agent.turn.completed", pendingWork: false) != nil,
                "Truly-idle stop must journal a non-pending turn completion; saw \(snapshot)")
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
        let snapshot = context.state.snapshot()
        #expect(notifyLine(snapshot, containing: "c=needs-permission;p=0") != nil,
                "permission_prompt must tag needs-permission; saw \(snapshot)")
        // The counterpart to `idlePromptAfterIdleStopNotifiesWithoutFlippingToNeedsInput`:
        // suppressing the idle nag must not also suppress a real blocking prompt,
        // which is the one case that may paint the pane as needing input.
        #expect(lifecycleLine(snapshot, value: "needsInput") != nil,
                "permission_prompt must set the needsInput lifecycle; saw \(snapshot)")
        #expect(statusLine(snapshot, value: "Needs input") != nil,
                "permission_prompt must set the Needs input pill; saw \(snapshot)")
    }

    /// Both error-shaped cues through one context and one mock server.
    ///
    /// One test rather than two, sharing a context: every context parks a
    /// global-queue thread in `accept()` for the run (closing the listener fd
    /// does not wake a blocked `accept()` on macOS), so a context per case
    /// starves the pool and unrelated hooks then block on connect until they
    /// time out.
    @Test func notificationErrorAndQuotaCuesPublishTheErrorLifecycle() throws {
        // Red is "the agent errored or ran out of quota". Claude used to fold both
        // into the needs-input orange, so red was unreachable on a Claude-only
        // setup: an out-of-quota pane looked identical to one asking a question.
        let harness = ClaudeHookSurfaceResolutionSwiftTests()
        let context = try harness.makeClaudeHookContext(name: "notif-error-cues")
        defer { context.cleanup() }
        let handled = harness.startClaudeSurfaceResolutionServer(
            context: context,
            surfaces: [(context.surfaceId, "surface:1", true)],
            ttyName: "ttys-notif-error-cues",
            ttySurfaceId: context.surfaceId
        )
        let environment = harness.claudeHookEnvironment(
            context: context,
            surfaceId: context.surfaceId,
            ttyName: "ttys-notif-error-cues",
            storeURL: context.root.appendingPathComponent("claude-hook-sessions.json")
        )

        for (session, message) in [
            ("error", "Claude reported an error: request failed"),
            ("quota", "Claude usage limit reached"),
        ] {
            let start = context.state.snapshot().count
            let result = harness.runProcess(
                executablePath: context.cliPath,
                arguments: ["hooks", "claude", "notification"],
                environment: environment,
                standardInput: #"{"session_id":"notif-\#(session)-session","cwd":"/tmp/x","hook_event_name":"Notification","message":"\#(message)"}"#,
                // Above the agents' own 5s hook budget: these are subprocesses, and
                // a busy machine starves a healthy hook past 5s, which then reads
                // as a product hang rather than the scheduling artifact it is.
                timeout: 15
            )
            #expect(handled.wait(timeout: .now() + 15) == .success)
            harness.assertSuccessfulHook(result)
            let commands = Array(context.state.snapshot().dropFirst(start))
            #expect(
                commands.contains { $0.hasPrefix("set_agent_lifecycle claude_code error ") },
                "\"\(message)\" must publish the error lifecycle; saw \(commands)"
            )
            #expect(
                !commands.contains { $0.hasPrefix("set_agent_lifecycle claude_code needsInput ") },
                "\"\(message)\" must not publish needsInput; saw \(commands)"
            )
        }
    }

    /// A started agent is present and ready, so its pane must read as ready
    /// rather than as an empty terminal, and `/clear` must not report the agent
    /// as working while it sits at a fresh empty prompt.
    ///
    /// Both session starts share one context and mock server: every context
    /// parks a global-queue thread in `accept()` for the run, and a context per
    /// case starves the pool until unrelated hooks time out.
    @Test func sessionStartPublishesIdleAndClearDoesNotReportRunning() throws {
        let harness = ClaudeHookSurfaceResolutionSwiftTests()
        let context = try harness.makeClaudeHookContext(name: "session-start-idle")
        defer { context.cleanup() }
        let handled = harness.startClaudeSurfaceResolutionServer(
            context: context,
            surfaces: [(context.surfaceId, "surface:1", true)],
            ttyName: "ttys-session-start-idle",
            ttySurfaceId: context.surfaceId
        )
        let environment = harness.claudeHookEnvironment(
            context: context,
            surfaceId: context.surfaceId,
            ttyName: "ttys-session-start-idle",
            storeURL: context.root.appendingPathComponent("claude-hook-sessions.json")
        )

        for (session, source) in [("startup", "startup"), ("cleared", "clear")] {
            let start = context.state.snapshot().count
            let result = harness.runProcess(
                executablePath: context.cliPath,
                arguments: ["hooks", "claude", "session-start"],
                environment: environment,
                standardInput: #"{"session_id":"session-start-\#(session)","cwd":"/tmp/x","hook_event_name":"SessionStart","source":"\#(source)"}"#,
                // Above the agents' own 5s hook budget: a busy machine starves a
                // healthy hook past 5s, which then reads as a product hang.
                timeout: 15
            )
            #expect(handled.wait(timeout: .now() + 15) == .success)
            harness.assertSuccessfulHook(result)
            let commands = Array(context.state.snapshot().dropFirst(start))
            #expect(
                commands.contains { $0.hasPrefix("set_agent_lifecycle claude_code idle ") },
                "source=\(source) must publish idle so a ready agent is not read as no agent; saw \(commands)"
            )
            #expect(
                !commands.contains { $0.hasPrefix("set_agent_lifecycle claude_code running ") },
                "source=\(source) must not report the agent as working; saw \(commands)"
            )
            #expect(
                !commands.contains { $0.hasPrefix("set_status claude_code Running ") },
                "source=\(source) must not set a Running pill; saw \(commands)"
            )
        }
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
        // And the journal must record it as an observation, never as a
        // needs-input question, so the reduced lifecycle stays running.
        #expect(journalEvent(snapshot, kind: "agent.question.requested") == nil,
                "Pending idle_prompt must not journal a needs-input question; saw \(snapshot)")
        #expect(journalEvent(snapshot, kind: "agent.state.changed") != nil,
                "Pending idle_prompt must still journal an observation; saw \(snapshot)")
    }

    @Test func idlePromptAfterIdleStopNotifiesWithoutFlippingToNeedsInput() throws {
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
        // The ~60s idle nag asks nothing — the agent is just sitting at its
        // prompt — so it must not undo the Stop hook's idle state and paint the
        // pane as blocked. Only a permission prompt, plan approval, or question
        // may do that. The journal records the nag as an explicit "ready"
        // assertion rather than a question the agent never posed.
        #expect(statusLine(snapshot, value: "Needs input") == nil,
                "Idle idle_prompt must not set the Needs input pill; saw \(snapshot)")
        #expect(journalEvent(snapshot, kind: "agent.question.requested") == nil,
                "Idle idle_prompt must not journal a question; saw \(snapshot)")
        let readyAssertion = journalEvent(snapshot, kind: "agent.state.changed")
        #expect(readyAssertion?.declaredPhase == "idle",
                "Idle idle_prompt must assert the ready phase; saw \(snapshot)")
    }
}
