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
        sessionRecord(storeURL, sessionId: sessionId)?["hadPendingBackgroundWorkAtStop"] as? Bool
    }

    private func sessionRecord(_ storeURL: URL, sessionId: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: storeURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = obj["sessions"] as? [String: Any],
              let record = sessions[sessionId] as? [String: Any] else { return nil }
        return record
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

    @Test func clearCarriesPendingBackgroundWorkUntilItDrains() throws {
        let harness = ClaudeHookSurfaceResolutionSwiftTests()
        let context = try harness.makeClaudeHookContext(name: "bg-clear-carry")
        defer { context.cleanup() }
        let storeURL = context.root.appendingPathComponent("claude-hook-sessions.json")
        let oldSession = "bg-clear-old-session"
        let clearSession = "bg-clear-new-session"
        let handled = harness.startClaudeSurfaceResolutionServer(
            context: context,
            surfaces: [(context.surfaceId, "surface:1", true)],
            ttyName: "ttys-bg-clear-carry",
            ttySurfaceId: context.surfaceId
        )
        var environment = harness.claudeHookEnvironment(
            context: context,
            surfaceId: context.surfaceId,
            ttyName: "ttys-bg-clear-carry",
            storeURL: storeURL
        )
        environment["CMUX_CLAUDE_PID"] = String(ProcessInfo.processInfo.processIdentifier)

        let promptResult = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "prompt-submit"],
            environment: environment,
            standardInput: #"{"session_id":"\#(oldSession)","turn_id":"turn-1","cwd":"/tmp/x","hook_event_name":"UserPromptSubmit"}"#,
            timeout: 5
        )
        #expect(handled.wait(timeout: .now() + 5) == .success)
        harness.assertSuccessfulHook(promptResult)

        let pendingStopResult = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "stop"],
            environment: environment,
            standardInput: #"{"session_id":"\#(oldSession)","turn_id":"turn-1","cwd":"/tmp/x","hook_event_name":"Stop","last_assistant_message":"ok","background_tasks":[{"id":"t1","type":"shell","status":"running","description":"build","command":"sleep 1"}],"session_crons":[]}"#,
            timeout: 5
        )
        #expect(handled.wait(timeout: .now() + 5) == .success)
        harness.assertSuccessfulHook(pendingStopResult)

        let clearEndCommandStart = context.state.snapshot().count
        let clearEndResult = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "session-end"],
            environment: environment,
            standardInput: #"{"session_id":"\#(oldSession)","reason":"clear","cwd":"/tmp/x","hook_event_name":"SessionEnd"}"#,
            timeout: 5
        )
        #expect(handled.wait(timeout: .now() + 5) == .success)
        harness.assertSuccessfulHook(clearEndResult)
        let clearEndCommands = Array(context.state.snapshot().dropFirst(clearEndCommandStart))
        #expect(
            !clearEndCommands.contains { $0.hasPrefix("clear_agent_pid claude_code ") },
            "SessionEnd(clear) must not erase live background activity; saw \(clearEndCommands)"
        )

        let clearCommandStart = context.state.snapshot().count
        let clearResult = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "session-start"],
            environment: environment,
            standardInput: #"{"session_id":"\#(clearSession)","source":"clear","cwd":"/tmp/x","hook_event_name":"SessionStart"}"#,
            timeout: 5
        )
        #expect(handled.wait(timeout: .now() + 5) == .success)
        harness.assertSuccessfulHook(clearResult)
        let clearCommands = Array(context.state.snapshot().dropFirst(clearCommandStart))

        #expect(
            statusLine(clearCommands, value: "Running") != nil,
            "/clear must preserve the Running pill while background work survives; saw \(clearCommands)"
        )
        #expect(statusLine(clearCommands, value: "Idle") == nil)
        #expect(
            lifecycleLine(clearCommands, value: "running") != nil,
            "/clear must keep the pane non-hibernatable while background work survives; saw \(clearCommands)"
        )
        #expect(lifecycleLine(clearCommands, value: "idle") == nil)
        let clearRecord = try #require(sessionRecord(storeURL, sessionId: clearSession))
        #expect(clearRecord["agentLifecycle"] as? String == "running")
        #expect(clearRecord["hadPendingBackgroundWorkAtStop"] as? Bool == true)

        let nextPromptResult = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "prompt-submit"],
            environment: environment,
            standardInput: #"{"session_id":"\#(clearSession)","turn_id":"turn-2","cwd":"/tmp/x","hook_event_name":"UserPromptSubmit"}"#,
            timeout: 5
        )
        #expect(handled.wait(timeout: .now() + 5) == .success)
        harness.assertSuccessfulHook(nextPromptResult)

        let drainedCommandStart = context.state.snapshot().count
        let drainedStopResult = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "stop"],
            environment: environment,
            standardInput: #"{"session_id":"\#(clearSession)","turn_id":"turn-2","cwd":"/tmp/x","hook_event_name":"Stop","last_assistant_message":"done","background_tasks":[],"session_crons":[]}"#,
            timeout: 5
        )
        #expect(handled.wait(timeout: .now() + 5) == .success)
        harness.assertSuccessfulHook(drainedStopResult)
        let drainedCommands = Array(context.state.snapshot().dropFirst(drainedCommandStart))

        #expect(
            statusLine(drainedCommands, value: "Idle") != nil,
            "The first Stop that observes drained background work must restore Idle; saw \(drainedCommands)"
        )
        #expect(lifecycleLine(drainedCommands, value: "idle") != nil)
        let drainedRecord = try #require(sessionRecord(storeURL, sessionId: clearSession))
        #expect(drainedRecord["agentLifecycle"] as? String == "idle")
        #expect(drainedRecord["hadPendingBackgroundWorkAtStop"] as? Bool == false)
    }

    @Test func clearDoesNotCarryPendingWorkFromSiblingPane() throws {
        let harness = ClaudeHookSurfaceResolutionSwiftTests()
        let context = try harness.makeClaudeHookContext(name: "bg-clear-sibling")
        defer { context.cleanup() }
        let storeURL = context.root.appendingPathComponent("claude-hook-sessions.json")
        let siblingSurfaceId = "77777777-7777-7777-7777-777777777777"
        let siblingSession = "bg-sibling-session"
        let clearSession = "bg-primary-clear-session"
        let handled = harness.startClaudeSurfaceResolutionServer(
            context: context,
            surfaces: [
                (context.surfaceId, "surface:1", true),
                (siblingSurfaceId, "surface:2", false),
            ],
            ttyName: "ttys-bg-clear-sibling",
            ttySurfaceId: context.surfaceId
        )
        let environment = harness.claudeHookEnvironment(
            context: context,
            surfaceId: context.surfaceId,
            ttyName: "ttys-bg-clear-sibling",
            storeURL: storeURL
        )

        let siblingPrompt = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "prompt-submit", "--surface", siblingSurfaceId],
            environment: environment,
            standardInput: #"{"session_id":"\#(siblingSession)","turn_id":"turn-1","cwd":"/tmp/x","hook_event_name":"UserPromptSubmit"}"#,
            timeout: 5
        )
        #expect(handled.wait(timeout: .now() + 5) == .success)
        harness.assertSuccessfulHook(siblingPrompt)

        let siblingStop = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "stop", "--surface", siblingSurfaceId],
            environment: environment,
            standardInput: #"{"session_id":"\#(siblingSession)","turn_id":"turn-1","cwd":"/tmp/x","hook_event_name":"Stop","last_assistant_message":"ok","background_tasks":[{"id":"t1","type":"shell","status":"running","description":"build","command":"sleep 1"}],"session_crons":[]}"#,
            timeout: 5
        )
        #expect(handled.wait(timeout: .now() + 5) == .success)
        harness.assertSuccessfulHook(siblingStop)

        let siblingEnd = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "session-end", "--surface", siblingSurfaceId],
            environment: environment,
            standardInput: #"{"session_id":"\#(siblingSession)","reason":"clear","cwd":"/tmp/x","hook_event_name":"SessionEnd"}"#,
            timeout: 5
        )
        #expect(handled.wait(timeout: .now() + 5) == .success)
        harness.assertSuccessfulHook(siblingEnd)

        let clearCommandStart = context.state.snapshot().count
        let clearResult = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "session-start"],
            environment: environment,
            standardInput: #"{"session_id":"\#(clearSession)","source":"clear","cwd":"/tmp/x","hook_event_name":"SessionStart"}"#,
            timeout: 5
        )
        #expect(handled.wait(timeout: .now() + 5) == .success)
        harness.assertSuccessfulHook(clearResult)
        let clearCommands = Array(context.state.snapshot().dropFirst(clearCommandStart))

        #expect(statusLine(clearCommands, value: "Idle") != nil)
        #expect(
            statusLine(clearCommands, value: "Running") == nil,
            "A sibling pane's background work must not keep this pane Running; saw \(clearCommands)"
        )
        #expect(lifecycleLine(clearCommands, value: "idle") != nil)
        #expect(lifecycleLine(clearCommands, value: "running") == nil)
        let clearRecord = try #require(sessionRecord(storeURL, sessionId: clearSession))
        #expect(clearRecord["agentLifecycle"] as? String == "idle")
        #expect(clearRecord["hadPendingBackgroundWorkAtStop"] as? Bool != true)
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
        // The idle nag is an attention channel, not evidence that Claude is
        // blocked on a decision. It must preserve the terminal Idle outcome.
        #expect(statusLine(snapshot, value: "Needs input") == nil,
                "Idle idle_prompt must not invent a Needs input pill; saw \(snapshot)")
        #expect(snapshot.contains {
            $0.contains(#""_cmux_agent_lifecycle":"idle""#)
        }, "Idle idle_prompt must publish the accepted Idle lifecycle; saw \(snapshot)")
    }
}
