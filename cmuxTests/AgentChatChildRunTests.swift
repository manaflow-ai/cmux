import CMUXAgentLaunch
@testable import CmuxMobileHost
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Child-run (subagent) bookkeeping from parent hook events: Claude `Task`
/// PreToolUse/PostToolUse pairs and Codex SubagentStart/SubagentStop.
@Suite("Agent chat child runs")
struct AgentChatChildRunTests {
    private func record() -> AgentChatSessionRecord {
        AgentChatSessionRecord(
            sessionID: "sess",
            agentKind: .claude,
            workspaceID: nil,
            surfaceID: nil,
            workingDirectory: nil,
            transcriptPath: nil,
            state: .working(since: Date(timeIntervalSince1970: 0)),
            lastActivityAt: Date(timeIntervalSince1970: 0),
            title: nil,
            pid: nil
        )
    }

    private func event(
        _ name: WorkstreamEvent.HookEventName,
        tool: String? = nil,
        input: String? = nil,
        requestId: String? = nil,
        source: String = "claude",
        agentID: String? = nil,
        agentType: String? = nil,
        toolUseID: String? = nil,
        finishedTaskIDs: [String] = [],
        at seconds: TimeInterval
    ) -> WorkstreamEvent {
        var extra: [String: Any] = [:]
        if let agentID { extra["agent_id"] = agentID }
        if let agentType { extra["agent_type"] = agentType }
        if let toolUseID { extra["tool_use_id"] = toolUseID }
        if !finishedTaskIDs.isEmpty { extra["finished_task_ids"] = finishedTaskIDs }
        let extraJSON = extra.isEmpty ? nil : String(
            decoding: (try? JSONSerialization.data(withJSONObject: extra)) ?? Data(), as: UTF8.self
        )
        return WorkstreamEvent(
            sessionId: "sess",
            hookEventName: name,
            source: source,
            toolName: tool,
            toolInputJSON: input,
            requestId: requestId,
            receivedAt: Date(timeIntervalSince1970: seconds),
            extraFieldsJSON: extraJSON
        )
    }

    private func apply(_ rec: inout AgentChatSessionRecord, _ events: WorkstreamEvent...) {
        for event in events {
            AgentChatSessionRegistry.applyChildRunEvent(&rec, event: event)
        }
    }

    /// Two background subagents started 8 ms apart; the later one finishes
    /// first. Its stop has to close its own child, not the oldest.
    @Test func claudeSubagentStopClosesTheChildOfItsAgentID() {
        var rec = record()
        apply(
            &rec,
            event(.preToolUse, tool: "Agent", input: #"{"description":"explore","subagent_type":"explorer"}"#, requestId: "spawn-1", at: 10),
            event(.preToolUse, tool: "Agent", input: #"{"description":"consult","subagent_type":"oracle"}"#, requestId: "spawn-2", at: 11),
            event(.preToolUse, tool: "Read", requestId: "t1", agentID: "agent-oracle", agentType: "oracle", at: 12),
            event(.preToolUse, tool: "Read", requestId: "t2", agentID: "agent-explorer", agentType: "explorer", at: 13),
            event(.subagentStop, requestId: "stop-1", agentID: "agent-oracle", agentType: "oracle", at: 20)
        )

        #expect(rec.children.map(\.label) == ["explore", "consult"])
        #expect(rec.children[0].isRunning)
        #expect(rec.children[1].endedAt == Date(timeIntervalSince1970: 20))
    }

    /// Claude sends stops for agent ids that never started, seconds or minutes
    /// after the parent's Stop. They must not close a child that is running.
    @Test func claudeStopForAnAgentThatNeverStartedLeavesARunningChildAlone() {
        var rec = record()
        apply(
            &rec,
            event(.preToolUse, tool: "Agent", input: #"{"description":"consult","subagent_type":"oracle"}"#, requestId: "spawn-1", at: 10),
            event(.preToolUse, tool: "Read", requestId: "t1", agentID: "agent-oracle", agentType: "oracle", at: 12),
            event(.stop, at: 30),
            event(.subagentStop, requestId: "stop-1", agentID: "agent-ghost", at: 31)
        )

        #expect(rec.children[0].isRunning)
    }

    @Test func claudeStopFromASubagentThatUsedNoToolClosesTheChildOfItsType() {
        var rec = record()
        apply(
            &rec,
            event(.preToolUse, tool: "Agent", input: #"{"subagent_type":"explorer"}"#, requestId: "spawn-1", at: 10),
            event(.preToolUse, tool: "Agent", input: #"{"subagent_type":"oracle"}"#, requestId: "spawn-2", at: 11),
            event(.subagentStop, requestId: "stop-1", agentID: "agent-oracle", agentType: "oracle", at: 20)
        )

        #expect(rec.children[0].isRunning)
        #expect(rec.children[1].endedAt == Date(timeIntervalSince1970: 20))
    }

    @Test func claudeRepeatedStopForOneAgentClosesOneChild() {
        var rec = record()
        apply(
            &rec,
            event(.preToolUse, tool: "Agent", input: #"{"subagent_type":"explorer"}"#, requestId: "spawn-1", at: 10),
            event(.preToolUse, tool: "Agent", input: #"{"subagent_type":"explorer"}"#, requestId: "spawn-2", at: 11),
            event(.preToolUse, tool: "Read", requestId: "t1", agentID: "agent-a", agentType: "explorer", at: 12),
            event(.subagentStop, requestId: "stop-1", agentID: "agent-a", agentType: "explorer", at: 20),
            event(.subagentStop, requestId: "stop-2", agentID: "agent-a", agentType: "explorer", at: 21)
        )

        #expect(rec.children[0].endedAt == Date(timeIntervalSince1970: 20))
        #expect(rec.children[1].isRunning)
    }

    /// A subagent stopped with TaskStop gets no SubagentStop. The parent's
    /// next prompt carries its task notification, and the hook CLI forwards
    /// the task id (the agent id) and tool-use id it names.
    @Test func claudeTaskNotificationClosesTheStoppedChild() {
        var rec = record()
        apply(
            &rec,
            event(.preToolUse, tool: "Agent", input: #"{"description":"slow"}"#, requestId: "spawn-1", toolUseID: "toolu_1", at: 10),
            event(.preToolUse, tool: "Agent", input: #"{"description":"other"}"#, requestId: "spawn-2", toolUseID: "toolu_2", at: 11),
            event(.preToolUse, tool: "Bash", requestId: "t1", agentID: "agent-a", agentType: "general-purpose", at: 12),
            event(.preToolUse, tool: "Read", requestId: "t2", agentID: "agent-b", agentType: "general-purpose", at: 13),
            event(.userPromptSubmit, finishedTaskIDs: ["toolu_1", "agent-a"], at: 20)
        )

        #expect(rec.children[0].endedAt == Date(timeIntervalSince1970: 20))
        #expect(rec.children[1].isRunning)
    }

    @Test func claudeTaskNotificationClosesAChildStoppedBeforeItsFirstTool() {
        var rec = record()
        apply(
            &rec,
            event(.preToolUse, tool: "Agent", input: #"{"description":"slow"}"#, requestId: "spawn-1", toolUseID: "toolu_1", at: 10),
            event(.preToolUse, tool: "Agent", input: #"{"description":"other"}"#, requestId: "spawn-2", toolUseID: "toolu_2", at: 11),
            event(.userPromptSubmit, finishedTaskIDs: ["toolu_2", "agent-never-seen"], at: 20)
        )

        #expect(rec.children[0].isRunning)
        #expect(rec.children[1].endedAt == Date(timeIntervalSince1970: 20))
    }

    /// The stop for an agent id that never started arrives with no type. A
    /// child whose subagent has not fired a hook yet must survive it.
    @Test func claudeStopForAnAgentThatNeverStartedLeavesAnUnboundChildAlone() {
        var rec = record()
        apply(
            &rec,
            event(.preToolUse, tool: "Agent", input: #"{"subagent_type":"oracle"}"#, requestId: "spawn-1", at: 10),
            event(.subagentStop, requestId: "stop-1", agentID: "agent-ghost", at: 12)
        )

        #expect(rec.children[0].isRunning)
        #expect(rec.children[0].agentID == nil)
    }

    /// Codex, pi and OMP correlate by request id; an `agent_id` on their
    /// events must not change that.
    @Test func otherAgentsKeepRequestIDMatching() {
        var rec = record()
        apply(
            &rec,
            event(.subagentStart, requestId: "c1", source: "codex", agentID: "c1", at: 5),
            event(.subagentStart, requestId: "c2", source: "codex", agentID: "c2", at: 6),
            event(.preToolUse, tool: "Read", requestId: "t", source: "codex", agentID: "c2", at: 7),
            event(.subagentStop, requestId: "unknown", source: "codex", agentID: "c2", at: 25)
        )

        #expect(rec.children.allSatisfy { $0.agentID == nil })
        #expect(rec.children[0].endedAt == Date(timeIntervalSince1970: 25))
        #expect(rec.children[1].isRunning)
    }

    @Test func taskSpawnOpensAndClosesChild() {
        var rec = record()
        AgentChatSessionRegistry.applyChildRunEvent(
            &rec,
            event: event(.preToolUse, tool: "Task", input: #"{"description":"Audit tests","subagent_type":"Explore"}"#, requestId: "r1", at: 10)
        )
        #expect(rec.children.count == 1)
        #expect(rec.children[0].label == "Audit tests")
        #expect(rec.children[0].isRunning)

        AgentChatSessionRegistry.applyChildRunEvent(
            &rec,
            event: event(.postToolUse, tool: "Task", requestId: "r1", at: 40)
        )
        #expect(rec.children.count == 1)
        #expect(rec.children[0].isRunning)

        AgentChatSessionRegistry.applyChildRunEvent(
            &rec,
            event: event(.subagentStop, requestId: "r1", at: 50)
        )
        #expect(!rec.children[0].isRunning)
        #expect(rec.children[0].endedAt == Date(timeIntervalSince1970: 50))
    }

    @Test func nonTaskToolsDoNotCreateChildren() {
        var rec = record()
        AgentChatSessionRegistry.applyChildRunEvent(
            &rec,
            event: event(.preToolUse, tool: "Bash", input: #"{"command":"ls"}"#, at: 10)
        )
        #expect(rec.children.isEmpty)
    }

    @Test func agentToolNameAlsoSpawnsChildren() {
        // Claude Code 2.x renamed the spawn tool "Task" -> "Agent".
        var rec = record()
        AgentChatSessionRegistry.applyChildRunEvent(
            &rec,
            event: event(.preToolUse, tool: "Agent", input: #"{"description":"probe A"}"#, requestId: "r9", at: 10)
        )
        #expect(rec.children.count == 1)
        #expect(rec.children[0].label == "probe A")
        AgentChatSessionRegistry.applyChildRunEvent(
            &rec,
            event: event(.postToolUse, tool: "Agent", requestId: "r9", at: 30)
        )
        #expect(rec.children[0].isRunning)
        AgentChatSessionRegistry.applyChildRunEvent(
            &rec,
            event: event(.subagentStop, at: 40)
        )
        #expect(!rec.children[0].isRunning)
    }

    @Test func missingRequestIdClosesOldestOpenChild() {
        var rec = record()
        AgentChatSessionRegistry.applyChildRunEvent(
            &rec, event: event(.preToolUse, tool: "Task", source: "codex", at: 10)
        )
        AgentChatSessionRegistry.applyChildRunEvent(
            &rec, event: event(.preToolUse, tool: "Task", source: "codex", at: 20)
        )
        #expect(rec.children.filter(\.isRunning).count == 2)

        AgentChatSessionRegistry.applyChildRunEvent(
            &rec, event: event(.postToolUse, tool: "Task", source: "codex", at: 30)
        )
        #expect(rec.children.filter(\.isRunning).count == 1)
        #expect(rec.children[0].endedAt != nil)
        #expect(rec.children[1].endedAt == nil)
    }

    @Test func subagentStartStopTrackChildren() {
        var rec = record()
        AgentChatSessionRegistry.applyChildRunEvent(
            &rec, event: event(.subagentStart, requestId: "c1", source: "codex", at: 5)
        )
        #expect(rec.children.count == 1)
        AgentChatSessionRegistry.applyChildRunEvent(
            &rec, event: event(.subagentStop, requestId: "c1", source: "codex", at: 25)
        )
        #expect(rec.children[0].endedAt == Date(timeIntervalSince1970: 25))
    }

    @Test func claudeSubagentStopClosesFirstChildWithoutClosingSibling() {
        var rec = record()
        AgentChatSessionRegistry.applyChildRunEvent(
            &rec, event: event(.preToolUse, tool: "Task", at: 10)
        )
        AgentChatSessionRegistry.applyChildRunEvent(
            &rec, event: event(.preToolUse, tool: "Task", at: 20)
        )

        AgentChatSessionRegistry.applyChildRunEvent(
            &rec, event: event(.postToolUse, tool: "Task", at: 30)
        )
        #expect(rec.children[0].isRunning)
        #expect(rec.children[1].isRunning)

        AgentChatSessionRegistry.applyChildRunEvent(
            &rec, event: event(.subagentStop, at: 31)
        )
        #expect(rec.children[0].endedAt == Date(timeIntervalSince1970: 31))
        #expect(rec.children[1].isRunning)
    }

    @Test func claudeBackgroundSpawnStaysRunningUntilSubagentStop() {
        var rec = record()
        AgentChatSessionRegistry.applyChildRunEvent(
            &rec, event: event(.preToolUse, tool: "Task", at: 10)
        )
        AgentChatSessionRegistry.applyChildRunEvent(
            &rec, event: event(.postToolUse, tool: "Task", at: 11)
        )
        #expect(rec.children[0].isRunning)

        AgentChatSessionRegistry.applyChildRunEvent(
            &rec, event: event(.subagentStop, at: 20)
        )
        #expect(!rec.children[0].isRunning)
    }

    @Test func claudeParentStopLeavesBackgroundChildrenRunningUntilTheirStop() {
        var rec = record()
        AgentChatSessionRegistry.applyChildRunEvent(
            &rec, event: event(.preToolUse, tool: "Task", requestId: "a", at: 10)
        )
        AgentChatSessionRegistry.applyChildRunEvent(
            &rec, event: event(.stop, at: 50)
        )
        #expect(rec.children[0].isRunning)

        AgentChatSessionRegistry.applyChildRunEvent(
            &rec, event: event(.subagentStop, requestId: "a", at: 60)
        )
        #expect(!rec.children[0].isRunning)
    }

    @Test func claudeSessionEndClosesBackgroundChildren() {
        var rec = record()
        AgentChatSessionRegistry.applyChildRunEvent(
            &rec, event: event(.preToolUse, tool: "Task", requestId: "a", at: 10)
        )
        AgentChatSessionRegistry.applyChildRunEvent(
            &rec, event: event(.sessionEnd, at: 50)
        )
        #expect(!rec.children[0].isRunning)
    }

    @Test func nonClaudeParentStopClosesAllOpenChildren() {
        var rec = record()
        AgentChatSessionRegistry.applyChildRunEvent(
            &rec, event: event(.preToolUse, tool: "Task", requestId: "a", source: "codex", at: 10)
        )
        AgentChatSessionRegistry.applyChildRunEvent(
            &rec, event: event(.preToolUse, tool: "Task", requestId: "b", source: "codex", at: 11)
        )
        AgentChatSessionRegistry.applyChildRunEvent(
            &rec, event: event(.stop, source: "codex", at: 50)
        )
        #expect(rec.children.allSatisfy { $0.endedAt != nil })
    }

    @Test func settledChildrenPruneAfterRetention() {
        var rec = record()
        AgentChatSessionRegistry.applyChildRunEvent(
            &rec, event: event(.preToolUse, tool: "Task", requestId: "a", source: "codex", at: 0)
        )
        AgentChatSessionRegistry.applyChildRunEvent(
            &rec, event: event(.postToolUse, tool: "Task", requestId: "a", source: "codex", at: 10)
        )
        #expect(rec.children.count == 1)
        // Any later event past the retention window prunes it.
        AgentChatSessionRegistry.applyChildRunEvent(
            &rec, event: event(.preToolUse, tool: "Bash", at: 10 + AgentChatChildRun.settledRetention + 1)
        )
        #expect(rec.children.isEmpty)
    }

    @Test func duplicatePreToolUseDoesNotForkChild() {
        var rec = record()
        AgentChatSessionRegistry.applyChildRunEvent(
            &rec, event: event(.preToolUse, tool: "Task", requestId: "r1", at: 10)
        )
        AgentChatSessionRegistry.applyChildRunEvent(
            &rec, event: event(.preToolUse, tool: "Task", requestId: "r1", at: 11)
        )
        #expect(rec.children.count == 1)
    }
}
