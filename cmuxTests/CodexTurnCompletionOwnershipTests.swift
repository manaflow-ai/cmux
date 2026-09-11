import Dispatch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior-level coverage for Codex completion ownership and native child
/// lifecycle. The tests drive the real hook executable against the existing
/// socket harness, so a passing result proves the visible mutation path rather
/// than a source-text or hook-shape convention.
@Suite(.serialized)
struct CodexTurnCompletionOwnershipTests {
    private struct Harness {
        let support: ClaudeHookSurfaceResolutionSwiftTests
        let context: ClaudeHookSurfaceResolutionSwiftTests.ClaudeHookContext
        let handled: DispatchSemaphore
        let environment: [String: String]
        let sessionId: String
        let token: String
    }

    @Test
    func inheritedOuterPIDCannotLetNestedCodexStopSettleForegroundPane() throws {
        let harness = try makeHarness(name: "codex-nested-inherited-pid")
        defer { harness.context.cleanup() }

        try runHook(
            harness,
            subcommand: "session-start",
            input: sessionStartPayload(harness)
        )
        try runHook(
            harness,
            subcommand: "prompt-submit",
            input: promptPayload(harness, turnId: "outer-turn")
        )

        let beforeNestedStop = harness.context.state.snapshot().count
        var nestedEnvironment = harness.environment
        // This is the exact failure mode from #7520: the child process keeps
        // the outer CMUX_CODEX_PID, while the hook's observed process is new.
        nestedEnvironment["CMUX_CODEX_HOOK_PID"] = "4243"
        let nestedResult = runProcess(
            harness,
            subcommand: "stop",
            input: #"{"session_id":"inner-autoreview","turn_id":"review-turn","cwd":"/tmp/review","hook_event_name":"Stop","last_assistant_message":"{\"findings\":[]}"}"#,
            environment: nestedEnvironment
        )
        harness.support.assertSuccessfulHook(nestedResult)
        #expect(harness.handled.wait(timeout: .now() + 5) == .success)

        let nestedCommands = Array(
            harness.context.state.snapshot().dropFirst(beforeNestedStop)
        )
        #expect(
            !nestedCommands.contains { $0.hasPrefix("notify_target_async ") },
            "A nested reviewer Stop must never publish foreground completion: \(nestedCommands)"
        )
        #expect(
            !nestedCommands.contains { $0.hasPrefix("set_status codex Idle ") },
            "A nested reviewer Stop must not make the foreground pane idle: \(nestedCommands)"
        )
        #expect(
            !nestedCommands.contains { $0.contains("surface.resume.set") },
            "A nested reviewer Stop must not replace the foreground resume identity: \(nestedCommands)"
        )
    }

    @Test
    func nativeChildrenKeepParentRunningUntilAllChildrenDrainThenNotifyOnce() throws {
        let harness = try makeHarness(name: "codex-native-child-settlement")
        defer { harness.context.cleanup() }

        try runHook(
            harness,
            subcommand: "session-start",
            input: sessionStartPayload(harness)
        )
        try runHook(
            harness,
            subcommand: "prompt-submit",
            input: promptPayload(harness, turnId: "turn-1")
        )
        try runFeedLifecycle(harness, event: "SubagentStart", id: "child-a")
        try runFeedLifecycle(harness, event: "SubagentStart", id: "child-b")

        let beforePendingStop = harness.context.state.snapshot().count
        try runHook(
            harness,
            subcommand: "stop",
            input: stopPayload(harness, turnId: "turn-1")
        )
        let pendingCommands = Array(
            harness.context.state.snapshot().dropFirst(beforePendingStop)
        )
        #expect(
            !pendingCommands.contains { $0.hasPrefix("notify_target_async ") },
            "A parent Stop with live children must not notify, even under an always-capable hook path: \(pendingCommands)"
        )
        #expect(
            pendingCommands.contains { $0.hasPrefix("set_status codex Running ") },
            "A parent Stop with live children must remain Running: \(pendingCommands)"
        )
        #expect(
            !pendingCommands.contains { $0.hasPrefix("set_status codex Idle ") },
            "A pending parent Stop must not also mark the pane idle: \(pendingCommands)"
        )
        #expect(
            AgentJournalAppendCapture.captures(in: pendingCommands).contains {
                $0.kind == "agent.turn.completed" && $0.pendingWork
            },
            "The pending parent boundary must be journaled authoritatively: \(pendingCommands)"
        )

        try runFeedLifecycle(harness, event: "SubagentStop", id: "child-a")
        let beforePartiallyDrainedStop = harness.context.state.snapshot().count
        try runHook(
            harness,
            subcommand: "stop",
            input: stopPayload(harness, turnId: "turn-1")
        )
        let partiallyDrainedCommands = Array(
            harness.context.state.snapshot().dropFirst(beforePartiallyDrainedStop)
        )
        #expect(
            !partiallyDrainedCommands.contains { $0.hasPrefix("notify_target_async ") },
            "One remaining child must continue to suppress completion: \(partiallyDrainedCommands)"
        )
        #expect(
            partiallyDrainedCommands.contains { $0.hasPrefix("set_status codex Running ") },
            "One remaining child must keep the pane Running: \(partiallyDrainedCommands)"
        )
        #expect(
            !partiallyDrainedCommands.contains { $0.hasPrefix("set_status codex Idle ") },
            "One remaining child must not also mark the pane idle: \(partiallyDrainedCommands)"
        )

        let beforeFinalChildStop = harness.context.state.snapshot().count
        try runFeedLifecycle(harness, event: "SubagentStop", id: "child-b")
        #expect(
            waitForConditionBlocking(timeout: 5) {
                let snapshot = harness.context.state.snapshot()
                return snapshot.contains { $0.hasPrefix("notify_target_async ") }
                    && snapshot.contains { $0.hasPrefix("set_status codex Idle ") }
            },
            "The persistent child-stop path must settle the pending parent turn: \(harness.context.state.snapshot())"
        )
        let finalCommands = Array(
            harness.context.state.snapshot().dropFirst(beforeFinalChildStop)
        )
        let finalNotifications = finalCommands.filter {
            $0.hasPrefix("notify_target_async ")
        }
        #expect(
            finalNotifications.count == 1,
            "The settled foreground turn must produce exactly one completion: \(finalCommands)"
        )
        #expect(
            finalCommands.contains { $0.hasPrefix("set_status codex Idle ") },
            "The settled foreground turn must become idle: \(finalCommands)"
        )
        #expect(
            !finalCommands.contains { $0.hasPrefix("set_status codex Running ") },
            "The settled foreground turn must not remain Running: \(finalCommands)"
        )

        // A parent Stop arriving after the detached child-stop settlement is a
        // duplicate boundary and must not publish another completion or repaint
        // the pane.
        let beforeDuplicateStop = harness.context.state.snapshot().count
        try runHook(
            harness,
            subcommand: "stop",
            input: stopPayload(harness, turnId: "turn-1")
        )
        let duplicateCommands = Array(
            harness.context.state.snapshot().dropFirst(beforeDuplicateStop)
        )
        let cumulativeNotifications = harness.context.state.snapshot().filter {
            $0.hasPrefix("notify_target_async ")
        }
        #expect(
            cumulativeNotifications.count == 1,
            "A duplicate settled Stop must not publish a second completion: \(harness.context.state.snapshot())"
        )
        #expect(
            !duplicateCommands.contains { $0.hasPrefix("set_status codex Idle ") },
            "A duplicate settled Stop must not repaint the pane idle: \(duplicateCommands)"
        )
    }

    @Test
    func transcriptTerminalChildrenSettleMissingNativeStopsWithoutClearingLiveChildren() throws {
        let harness = try makeHarness(name: "codex-transcript-child-settlement")
        defer { harness.context.cleanup() }

        try runHook(
            harness,
            subcommand: "session-start",
            input: sessionStartPayload(harness)
        )
        try writeCodexLedger(
            harness,
            activeChildrenByTurn: [
                "child-turn-a": ["child-a"],
                "child-turn-b": ["child-b"],
            ]
        )

        let transcriptPath = try writeSubagentTranscript(
            harness,
            activities: [
                (id: "child-a", kind: "interrupted"),
                (id: "child-a", kind: "interacted"),
                (id: "child-b", kind: "interrupted"),
                (id: "child-b", kind: "interacted"),
            ],
            followupAgentIDs: ["child-b"],
            trailingPaddingBytes: 768 * 1024
        )
        let beforeLiveChildStop = harness.context.state.snapshot().count
        try runHook(
            harness,
            subcommand: "stop",
            input: stopPayload(
                harness,
                turnId: "turn-1",
                transcriptPath: transcriptPath
            )
        )
        let liveChildCommands = Array(
            harness.context.state.snapshot().dropFirst(beforeLiveChildStop)
        )
        #expect(
            !liveChildCommands.contains { $0.hasPrefix("notify_target_async ") },
            "A follow-up task must keep the restarted child active: \(liveChildCommands)"
        )
        #expect(
            liveChildCommands.contains { $0.hasPrefix("set_status codex Running ") },
            "A nonterminal transcript child must keep the pane Running: \(liveChildCommands)"
        )

        _ = try writeSubagentTranscript(
            harness,
            activities: [
                (id: "child-a", kind: "interrupted"),
                (id: "child-a", kind: "interacted"),
                (id: "child-b", kind: "interrupted"),
                (id: "child-b", kind: "interacted"),
                (id: "child-b", kind: "completed"),
            ],
            followupAgentIDs: ["child-b"],
            trailingPaddingBytes: 768 * 1024
        )
        let beforeSettledStop = harness.context.state.snapshot().count
        #expect(
            waitUntil(timeout: 8) {
                let commands = Array(
                    harness.context.state.snapshot().dropFirst(beforeSettledStop)
                )
                return commands.contains { $0.hasPrefix("set_status codex Idle ") }
            },
            "A bounded Stop retry must reconcile child state flushed after the original callback"
        )
        let settledCommands = Array(
            harness.context.state.snapshot().dropFirst(beforeSettledStop)
        )
        #expect(settledCommands.filter { $0.hasPrefix("notify_target_async ") }.count == 1)
        #expect(settledCommands.contains { $0.hasPrefix("set_status codex Idle ") })
        #expect(!settledCommands.contains { $0.hasPrefix("set_status codex Running ") })
        #expect(
            AgentJournalAppendCapture.captures(in: settledCommands).contains {
                $0.kind == "agent.turn.completed" && !$0.pendingWork
            },
            "Transcript-terminal children must clear pending work: \(settledCommands)"
        )
    }

    @Test
    func normalTopLevelStopStillNotifiesAndBecomesIdle() throws {
        let harness = try makeHarness(name: "codex-normal-top-level-stop")
        defer { harness.context.cleanup() }

        try runHook(
            harness,
            subcommand: "session-start",
            input: sessionStartPayload(harness)
        )
        try runHook(
            harness,
            subcommand: "prompt-submit",
            input: promptPayload(harness, turnId: "normal-turn")
        )
        let beforeStop = harness.context.state.snapshot().count
        try runHook(
            harness,
            subcommand: "stop",
            input: stopPayload(harness, turnId: "normal-turn")
        )
        let commands = Array(harness.context.state.snapshot().dropFirst(beforeStop))
        #expect(commands.filter { $0.hasPrefix("notify_target_async ") }.count == 1)
        #expect(commands.contains { $0.hasPrefix("set_status codex Idle ") })
        #expect(!commands.contains { $0.hasPrefix("set_status codex Running ") })
    }

    private func makeHarness(name: String) throws -> Harness {
        let support = ClaudeHookSurfaceResolutionSwiftTests()
        let context = try support.makeClaudeHookContext(name: name)
        let handled = support.startClaudeSurfaceResolutionServer(
            context: context,
            surfaces: [(context.surfaceId, "surface:1", true)],
            ttyName: "ttys-\(name)",
            ttySurfaceId: context.surfaceId
        )
        let token = "codex-owner-\(name)"
        let environment = [
            "HOME": context.root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PWD": context.root.path,
            "CMUX_SOCKET_PATH": context.socketPath,
            "CMUX_WORKSPACE_ID": context.workspaceId,
            "CMUX_SURFACE_ID": context.surfaceId,
            "CMUX_CLI_TTY_NAME": "ttys-\(name)",
            "CMUX_CODEX_PID": "4242",
            "CMUX_CODEX_HOOK_PID": "4242",
            "CMUX_CODEX_INVOCATION_ID": token,
            "CMUX_AGENT_HOOK_STATE_DIR": context.root.path,
            "CMUX_CODEX_TURN_LEDGER_PATH": context.root.appendingPathComponent("codex-turn-ledger.json").path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CMUX_AGENT_LAUNCH_KIND": "codex",
            "CMUX_AGENT_LAUNCH_EXECUTABLE": "/usr/local/bin/codex",
            "CMUX_AGENT_LAUNCH_CWD": context.root.path,
        ]
        return Harness(
            support: support,
            context: context,
            handled: handled,
            environment: environment,
            sessionId: "session-\(name)",
            token: token
        )
    }

    private func runHook(
        _ harness: Harness,
        subcommand: String,
        input: String,
        environment: [String: String]? = nil
    ) throws {
        let result = runProcess(
            harness,
            subcommand: subcommand,
            input: input,
            environment: environment ?? harness.environment,
            timeout: 10
        )
        #expect(harness.handled.wait(timeout: .now() + 10) == .success)
        harness.support.assertSuccessfulHook(result)
    }

    private func runFeedLifecycle(
        _ harness: Harness,
        event: String,
        id: String
    ) throws {
        try runHook(
            harness,
            subcommand: "feed --source codex --event \(event)",
            input: #"{"session_id":"\#(harness.sessionId)","turn_id":"turn-1","agent_id":"\#(id)","cwd":"\#(harness.context.root.path)","hook_event_name":"\#(event)"}"#
        )
    }

    private func runProcess(
        _ harness: Harness,
        subcommand: String,
        input: String,
        environment: [String: String],
        timeout: TimeInterval = 5
    ) -> ClaudeHookSurfaceResolutionSwiftTests.ProcessRunResult {
        let command = subcommand.split(separator: " ").map(String.init)
        let arguments = command.first == "feed"
            ? ["hooks"] + command
            : ["hooks", "codex"] + command
        return harness.support.runProcess(
            executablePath: harness.context.cliPath,
            arguments: arguments,
            environment: environment,
            standardInput: input,
            timeout: timeout
        )
    }

    private func sessionStartPayload(_ harness: Harness) -> String {
        #"{"session_id":"\#(harness.sessionId)","cwd":"\#(harness.context.root.path)","hook_event_name":"SessionStart"}"#
    }

    private func promptPayload(_ harness: Harness, turnId: String) -> String {
        #"{"session_id":"\#(harness.sessionId)","turn_id":"\#(turnId)","cwd":"\#(harness.context.root.path)","hook_event_name":"UserPromptSubmit"}"#
    }

    private func writeSubagentTranscript(
        _ harness: Harness,
        activities: [(id: String, kind: String)],
        followupAgentIDs: Set<String> = [],
        trailingPaddingBytes: Int = 0
    ) throws -> String {
        let transcriptURL = harness.context.root.appendingPathComponent("parent-rollout.jsonl")
        var lines: [String] = []
        for (index, activity) in activities.enumerated() {
            let activityID = "call-activity-\(index)"
            if activity.kind == "interacted", followupAgentIDs.contains(activity.id) {
                lines.append(
                    #"{"type":"response_item","payload":{"type":"function_call","name":"followup_task","call_id":"\#(activityID)","arguments":"{}"}}"#
                )
            }
            lines.append(
                #"{"ordinal":\#(index),"type":"event_msg","payload":{"type":"item_completed","turn_id":"turn-1","item":{"type":"SubAgentActivity","id":"\#(activityID)","kind":"\#(activity.kind)","agent_thread_id":"\#(activity.id)"}}}"#
            )
        }
        var remainingPaddingBytes = trailingPaddingBytes
        while remainingPaddingBytes > 0 {
            let chunkBytes = min(4 * 1024, remainingPaddingBytes)
            let padding = String(repeating: "x", count: chunkBytes)
            lines.append(
                #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"\#(padding)"}]}}"#
            )
            remainingPaddingBytes -= chunkBytes
        }
        try (lines.joined(separator: "\n") + "\n").write(
            to: transcriptURL,
            atomically: true,
            encoding: .utf8
        )
        return transcriptURL.path
    }

    private func writeCodexLedger(
        _ harness: Harness,
        activeChildrenByTurn: [String: [String]]
    ) throws {
        let record: [String: Any] = [
            "workspaceID": harness.context.workspaceId,
            "surfaceID": harness.context.surfaceId,
            "owner": [
                "token": harness.token,
                "pid": 4242,
            ],
            "activeTurnID": "turn-1",
            "activeChildrenByTurn": activeChildrenByTurn,
            "unknownChildrenByTurn": [:],
            "terminalChildrenByTurn": [:],
            "pendingTurns": [:],
            "settledTurnIDs": [],
            "notifiedTurnIDs": [],
            "updatedAt": Date.now.timeIntervalSince1970,
        ]
        let object: [String: Any] = [
            "records": [harness.sessionId: record],
            "surfaceOwners": [harness.context.surfaceId: harness.sessionId],
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let path = try #require(harness.environment["CMUX_CODEX_TURN_LEDGER_PATH"])
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date.now < deadline
        return condition()
    }

    private func stopPayload(
        _ harness: Harness,
        turnId: String,
        transcriptPath: String? = nil
    ) -> String {
        var payload: [String: Any] = [
            "session_id": harness.sessionId,
            "turn_id": turnId,
            "cwd": harness.context.root.path,
            "hook_event_name": "Stop",
            "last_assistant_message": "done",
        ]
        if let transcriptPath {
            payload["transcript_path"] = transcriptPath
        }
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
