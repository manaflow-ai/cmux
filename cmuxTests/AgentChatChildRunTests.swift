import CMUXAgentLaunch
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
        at seconds: TimeInterval
    ) -> WorkstreamEvent {
        WorkstreamEvent(
            sessionId: "sess",
            hookEventName: name,
            source: "claude",
            toolName: tool,
            toolInputJSON: input,
            requestId: requestId,
            receivedAt: Date(timeIntervalSince1970: seconds)
        )
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
        #expect(!rec.children[0].isRunning)
        #expect(rec.children[0].endedAt == Date(timeIntervalSince1970: 40))
    }

    @Test func nonTaskToolsDoNotCreateChildren() {
        var rec = record()
        AgentChatSessionRegistry.applyChildRunEvent(
            &rec,
            event: event(.preToolUse, tool: "Bash", input: #"{"command":"ls"}"#, at: 10)
        )
        #expect(rec.children.isEmpty)
    }

    @Test func missingRequestIdClosesOldestOpenChild() {
        var rec = record()
        AgentChatSessionRegistry.applyChildRunEvent(
            &rec, event: event(.preToolUse, tool: "Task", at: 10)
        )
        AgentChatSessionRegistry.applyChildRunEvent(
            &rec, event: event(.preToolUse, tool: "Task", at: 20)
        )
        #expect(rec.children.filter(\.isRunning).count == 2)

        AgentChatSessionRegistry.applyChildRunEvent(
            &rec, event: event(.postToolUse, tool: "Task", at: 30)
        )
        #expect(rec.children.filter(\.isRunning).count == 1)
        #expect(rec.children[0].endedAt != nil)
        #expect(rec.children[1].endedAt == nil)
    }

    @Test func subagentStartStopTrackChildren() {
        var rec = record()
        AgentChatSessionRegistry.applyChildRunEvent(
            &rec, event: event(.subagentStart, requestId: "c1", at: 5)
        )
        #expect(rec.children.count == 1)
        AgentChatSessionRegistry.applyChildRunEvent(
            &rec, event: event(.subagentStop, requestId: "c1", at: 25)
        )
        #expect(rec.children[0].endedAt == Date(timeIntervalSince1970: 25))
    }

    @Test func stopClosesAllOpenChildren() {
        var rec = record()
        AgentChatSessionRegistry.applyChildRunEvent(
            &rec, event: event(.preToolUse, tool: "Task", requestId: "a", at: 10)
        )
        AgentChatSessionRegistry.applyChildRunEvent(
            &rec, event: event(.preToolUse, tool: "Task", requestId: "b", at: 11)
        )
        AgentChatSessionRegistry.applyChildRunEvent(
            &rec, event: event(.stop, at: 50)
        )
        #expect(rec.children.allSatisfy { $0.endedAt != nil })
    }

    @Test func settledChildrenPruneAfterRetention() {
        var rec = record()
        AgentChatSessionRegistry.applyChildRunEvent(
            &rec, event: event(.preToolUse, tool: "Task", requestId: "a", at: 0)
        )
        AgentChatSessionRegistry.applyChildRunEvent(
            &rec, event: event(.postToolUse, tool: "Task", requestId: "a", at: 10)
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
