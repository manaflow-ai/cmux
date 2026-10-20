import Dispatch
import Foundation
import Testing

/// Claude Code fires `StopFailure` instead of `Stop` when a turn dies on an
/// API error (usage limit, dropped connection, overload). The pane must leave
/// "Running" for a visible error state that names the reason, and the later
/// idle nag must not quietly settle it back to idle. Drives the real CLI
/// against the mock socket server, like `ClaudeBackgroundWorkNotifyTests`.
@Suite(.serialized)
struct ClaudeStopFailureStatusTests {
    private func statusLines(_ snapshot: [String]) -> [String] {
        snapshot.filter { $0.hasPrefix("set_status claude_code ") }
    }

    private func journalKinds(_ snapshot: [String]) -> [String] {
        AgentJournalAppendCapture.captures(in: snapshot)
            .filter { $0.agentKey == "claude_code" }
            .compactMap(\.kind)
    }

    private func run(
        name: String,
        hooks: [(subcommand: String, stdin: String)]
    ) throws -> (snapshot: [String], store: [String: Any]?) {
        let harness = ClaudeHookSurfaceResolutionSwiftTests()
        let context = try harness.makeClaudeHookContext(name: name)
        defer { context.cleanup() }
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
        for hook in hooks {
            let result = harness.runProcess(
                executablePath: context.cliPath,
                arguments: ["hooks", "claude", hook.subcommand],
                environment: environment,
                standardInput: hook.stdin,
                timeout: ClaudeHookLiveDeliveryHarness.processWallBound
            )
            #expect(handled.wait(timeout: .now() + 5) == .success)
            harness.assertSuccessfulHook(result)
        }
        let store = (try? Data(contentsOf: storeURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return (context.state.snapshot(), store)
    }

    @Test func usageLimitShowsErrorStatusWithResetTime() throws {
        let session = "stop-failure-usage"
        let (snapshot, store) = try run(name: "sf-usage", hooks: [(
            "stop",
            #"{"session_id":"\#(session)","cwd":"/tmp/x","hook_event_name":"StopFailure","error":"rate_limit","last_assistant_message":"You've hit your weekly limit · resets Oct 3 at 9am (America/Toronto)"}"#
        )])
        let statuses = statusLines(snapshot)
        #expect(statuses.contains { line in
            line.hasPrefix("set_status claude_code Usage limit, resets Oct 3 at 9am ")
                && line.contains("--icon=exclamationmark.triangle.fill")
                && line.contains("--color=#FF453A")
                && line.contains("--priority=100")
        }, "StopFailure must set the error pill with the reset time; saw \(snapshot)")
        #expect(!statuses.contains { $0.hasPrefix("set_status claude_code Idle ") })
        #expect(!statuses.contains { $0.hasPrefix("set_status claude_code Running ") })
        #expect(journalKinds(snapshot).contains("agent.error.reported"),
                "StopFailure must journal an error, not a completed turn; saw \(snapshot)")
        #expect(!journalKinds(snapshot).contains("agent.turn.completed"))
        let record = (store?["sessions"] as? [String: Any])?[session] as? [String: Any]
        #expect(record?["hookEventName"] as? String == "StopFailure")
    }

    @Test func droppedConnectionClassifiesFromTheAssistantMessage() throws {
        let (snapshot, _) = try run(name: "sf-conn", hooks: [(
            "stop",
            #"{"session_id":"stop-failure-conn","cwd":"/tmp/x","hook_event_name":"StopFailure","error":"server_error","last_assistant_message":"API Error: Connection dropped (ECONNRESET)"}"#
        )])
        #expect(statusLines(snapshot).contains { $0.hasPrefix("set_status claude_code Connection dropped ") },
                "A dropped connection must name the reason; saw \(snapshot)")
        #expect(journalKinds(snapshot).contains("agent.error.reported"))
    }

    @Test func idleNagAfterStopFailureKeepsTheError() throws {
        let session = "stop-failure-idle"
        let (snapshot, _) = try run(name: "sf-idle", hooks: [
            (
                "stop",
                #"{"session_id":"\#(session)","cwd":"/tmp/x","hook_event_name":"StopFailure","error":"overloaded","last_assistant_message":"API Error: Overloaded"}"#
            ),
            (
                "notification",
                #"{"session_id":"\#(session)","cwd":"/tmp/x","hook_event_name":"Notification","message":"Claude is waiting for your input","notification_type":"idle_prompt"}"#
            ),
        ])
        #expect(journalKinds(snapshot).contains("agent.error.reported"))
        #expect(!journalKinds(snapshot).contains("agent.idle.observed"),
                "The idle nag after a StopFailure must not settle the error to idle; saw \(snapshot)")
    }
}
