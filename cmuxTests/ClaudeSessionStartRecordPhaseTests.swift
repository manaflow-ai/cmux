import Foundation
import Testing

/// The phase a Claude `SessionStart` writes into the on-disk hook-session
/// record, which `cmux sessions list` publishes as `agent_lifecycle`.
///
/// The record is a second store beside the journal, and it is the one every
/// out-of-app reader sees. It hard-wrote `running` on every SessionStart — a
/// startup, a resume, a `/clear`, a compact — at the moment the journal reduced
/// that same event to something else entirely. One event, two stores, opposite
/// answers, which is how a pane and a sidebar row end up disagreeing about the
/// same agent.
@Suite(.serialized)
struct ClaudeSessionStartRecordPhaseTests {
    private typealias Harness = ClaudeHookLiveDeliveryHarness

    private static let workspaceId = "11111111-1111-1111-1111-111111111111"
    private static let surfaceId = "22222222-2222-2222-2222-222222222222"

    /// A SessionStart is not a turn start: the agent is sitting at an empty
    /// prompt with nothing submitted. Recording it as working left every freshly
    /// started agent published as busy until its first turn actually began.
    @Test("A fresh conversation is recorded ready, not working")
    func startupRecordsReadyRatherThanRunning() throws {
        let record = try runSessionStart(
            name: "session-start-startup-ready",
            sessionId: "session-start-startup-ready-session",
            source: "startup"
        )
        #expect(record?["agentLifecycle"] as? String == "idle")
    }

    /// The same for `/clear`: the conversation is dropped and the agent is back
    /// at an empty prompt.
    @Test("A cleared conversation is recorded ready, not working")
    func clearRecordsReadyRatherThanRunning() throws {
        let record = try runSessionStart(
            name: "session-start-clear-ready",
            sessionId: "session-start-clear-ready-session",
            source: "clear"
        )
        #expect(record?["agentLifecycle"] as? String == "idle")
    }

    /// A resume continues a session whose phase already stands. Overwriting it
    /// would blank exactly what survives a relaunch: a pane restored on a
    /// pending question would be republished as busy the moment its agent came
    /// back, and nothing in the app writes this store to correct it. The same
    /// holds for `compact`, which can land inside a live turn.
    @Test("A resumed session keeps the phase it was restored with")
    func resumeLeavesTheRestoredPhaseAlone() throws {
        let record = try runSessionStart(
            name: "session-start-resume-keeps",
            sessionId: "session-start-resume-keeps-session",
            source: "resume",
            existingLifecycle: "needsInput"
        )
        #expect(record?["agentLifecycle"] as? String == "needsInput")
    }

    private func runSessionStart(
        name: String,
        sessionId: String,
        source: String,
        existingLifecycle: String? = nil
    ) throws -> [String: Any]? {
        let context = try Harness.makeContext(name: name)
        defer { context.cleanup() }

        if let existingLifecycle {
            try writeStore(
                to: context.storeURL,
                sessionId: sessionId,
                cwd: context.root.path,
                agentLifecycle: existingLifecycle
            )
        }
        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [Self.workspaceId: [Self.surfaceId]],
            pidTarget: (workspaceId: Self.workspaceId, surfaceId: Self.surfaceId)
        )

        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = Self.workspaceId
        environment["CMUX_SURFACE_ID"] = Self.surfaceId
        environment["CMUX_CLAUDE_PID"] = "44001"

        let result = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "session-start"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","source":"\#(source)","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        assertSuccessfulHook(result)
        return try Harness.sessionRecord(in: context.storeURL, sessionId: sessionId)
    }

    private func writeStore(
        to storeURL: URL,
        sessionId: String,
        cwd: String,
        agentLifecycle: String
    ) throws {
        let now = Date().timeIntervalSince1970
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": Self.workspaceId,
                    "surfaceId": Self.surfaceId,
                    "cwd": cwd,
                    "agentLifecycle": agentLifecycle,
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        try JSONSerialization
            .data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
            .write(to: storeURL)
    }

    private func assertSuccessfulHook(_ result: Harness.ProcessRunResult) {
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
    }
}
