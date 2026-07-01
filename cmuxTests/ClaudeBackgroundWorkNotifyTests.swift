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

    private func runStopHook(
        name: String,
        sessionId: String,
        stdin: String
    ) throws -> (snapshot: [String], storeURL: URL) {
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
        context.cleanup()
        return (snapshot, storeURL)
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
        let (snapshot, storeURL) = try runStopHook(name: "bg-run", sessionId: session, stdin: stdin)
        #expect(
            notifyLine(snapshot, containing: "c=turn-complete;p=1") != nil,
            "Stop with a running background task must tag the done-ping pending; saw \(snapshot)"
        )
        #expect(cachedPending(storeURL, sessionId: session) == true)
    }

    @Test func stopWithEmptyArraysTagsIdleAndCachesFalse() throws {
        let session = "bg-empty-session"
        let stdin = #"""
        {"session_id":"\#(session)","cwd":"/tmp/x","hook_event_name":"Stop","last_assistant_message":"ok","background_tasks":[],"session_crons":[]}
        """#
        let (snapshot, storeURL) = try runStopHook(name: "bg-empty", sessionId: session, stdin: stdin)
        #expect(notifyLine(snapshot, containing: "c=turn-complete;p=0") != nil,
                "Truly-idle stop must tag pending=0; saw \(snapshot)")
        #expect(cachedPending(storeURL, sessionId: session) == false)
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
        let (snapshot, storeURL) = try runStopHook(name: "bg-old", sessionId: session, stdin: stdin)
        #expect(notifyLine(snapshot, containing: "c=turn-complete;p=0") != nil,
                "Absent arrays (old client) must behave as not-pending; saw \(snapshot)")
        #expect(cachedPending(storeURL, sessionId: session) == false)
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
        #expect(notifyLine(context.state.snapshot(), containing: "c=idle-reminder;p=1") != nil,
                "idle_prompt after a pending stop must inherit pending=1; saw \(context.state.snapshot())")
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
        _ = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "stop"],
            environment: environment,
            standardInput: #"{"session_id":"\#(session)","cwd":"/tmp/x","hook_event_name":"Stop","last_assistant_message":"ok","background_tasks":[],"session_crons":[]}"#,
            timeout: 5
        )
        #expect(handled.wait(timeout: .now() + 5) == .success)
        let notifResult = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "notification"],
            environment: environment,
            standardInput: #"{"session_id":"\#(session)","cwd":"/tmp/x","hook_event_name":"Notification","message":"Claude is waiting for your input","notification_type":"idle_prompt"}"#,
            timeout: 5
        )
        #expect(handled.wait(timeout: .now() + 5) == .success)
        harness.assertSuccessfulHook(notifResult)
        #expect(notifyLine(context.state.snapshot(), containing: "c=idle-reminder;p=0") != nil,
                "idle_prompt after an idle stop must tag pending=0; saw \(context.state.snapshot())")
    }
}
