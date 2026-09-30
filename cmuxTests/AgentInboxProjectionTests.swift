import Foundation
import Testing
import CMUXAgentLaunch
import CmuxAgentJournal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Agent inbox projection")
struct AgentInboxProjectionTests {
    @Test("merges messages, pending decisions, and completed turns newest first")
    func mergesSourcesInNewestFirstOrder() {
        let now = Date(timeIntervalSince1970: 10_000)
        let message = AgentMessage(
            id: "message-1",
            threadId: "thread-1",
            senderName: "reviewer",
            senderSurfaceId: "surface-agent",
            senderWorkspaceId: "workspace-agent",
            recipientSurfaceId: "surface-human",
            recipientWorkspaceId: "workspace-human",
            body: "Can you review the latest change?",
            createdAt: now.addingTimeInterval(-30),
            inReplyTo: nil,
            state: .queued
        )
        let question = WorkstreamItem(
            workstreamId: "claude-question",
            source: .claude,
            kind: .question,
            createdAt: now.addingTimeInterval(-20),
            payload: .question(
                requestId: "question-1",
                questions: [
                    WorkstreamQuestionPrompt(
                        id: "choice",
                        prompt: "Which option?",
                        multiSelect: false,
                        options: [
                            WorkstreamQuestionOption(id: "a", label: "Option A"),
                            WorkstreamQuestionOption(id: "b", label: "Option B"),
                        ]
                    ),
                ]
            ),
            context: WorkstreamContext(lastUserMessage: "Choose a direction")
        )
        let stop = WorkstreamItem(
            workstreamId: "codex-turn",
            source: .codex,
            kind: .stop,
            createdAt: now.addingTimeInterval(-5),
            payload: .stop(reason: "completed"),
            context: WorkstreamContext(lastUserMessage: "Implement the change")
        )
        let assistant = WorkstreamItem(
            workstreamId: "codex-turn",
            source: .codex,
            kind: .assistantMessage,
            createdAt: now.addingTimeInterval(-6),
            payload: .assistantMessage(text: "Implemented the change.")
        )

        let items = AgentInboxProjection.project(
            messages: [message],
            workstreamItems: [question, assistant, stop],
            workspaceTitles: [
                "workspace-agent": "Agent Workspace",
                "workspace-human": "Human Workspace",
            ],
            now: now
        )

        #expect(items.map(\.kind) == [.finishedTurn, .question, .agentMessage])
        #expect(items[0].agentText == "Implemented the change.")
        #expect(items[0].promptText == "Implement the change")
        #expect(items[1].isUnread)
        #expect(items[2].state == .queued)
        #expect(items[2].workspaceTitle == "Agent Workspace")
    }

    @Test("search matches body, workspace, and agent name")
    func searchFiltersAcrossVisibleFields() {
        let now = Date(timeIntervalSince1970: 20_000)
        let message = AgentMessage(
            id: "message-2",
            threadId: "thread-2",
            senderName: "planner",
            senderSurfaceId: "surface-planner",
            senderWorkspaceId: "workspace-planner",
            recipientSurfaceId: "surface-human",
            recipientWorkspaceId: "workspace-human",
            body: "The migration plan is ready.",
            createdAt: now,
            inReplyTo: nil
        )

        let items = AgentInboxProjection.project(
            messages: [message],
            workstreamItems: [],
            workspaceTitles: ["workspace-planner": "Release Planning"],
            now: now
        )

        #expect(AgentInboxProjection.filtered(items, query: "release").count == 1)
        #expect(AgentInboxProjection.filtered(items, query: "planner").count == 1)
        #expect(AgentInboxProjection.filtered(items, query: "missing").isEmpty)
    }

    @Test("openAgentInbox resolves each workstream id once")
    func openAgentInboxDeduplicatesWorkstreamIDsBeforeResolving() {
        let now = Date(timeIntervalSince1970: 30_000)
        let workstreamID = "claude-duplicate-session"
        let assistant = WorkstreamItem(
            workstreamId: workstreamID,
            source: .claude,
            kind: .assistantMessage,
            createdAt: now,
            payload: .assistantMessage(text: "First reply")
        )
        let stop = WorkstreamItem(
            workstreamId: workstreamID,
            source: .claude,
            kind: .stop,
            createdAt: now.addingTimeInterval(1),
            payload: .stop(reason: "completed")
        )

        #expect(
            AgentInboxProjection.uniqueWorkstreamIDs(from: [assistant, stop]) == [workstreamID]
        )
    }

    @Test("agent inbox replies append a validated agent message")
    func replyPathAppendsToAgentMessageStore() throws {
        let store = AgentMessageStore(
            fileURL: nil,
            now: { Date(timeIntervalSince1970: 31_000) },
            makeId: { "reply-1" }
        )
        let target = AgentInboxReplyTarget.agentMessage(
            surfaceId: "agent-surface",
            workspaceId: "agent-workspace",
            replyTo: "incoming-1"
        )

        let sent = try AgentInboxReplySender.send(
            body: "I checked the change.",
            senderName: "you",
            target: target,
            workstreamTarget: nil,
            store: store
        )

        #expect(sent.id == "reply-1")
        #expect(sent.senderName == "you")
        #expect(sent.recipientSurfaceId == "agent-surface")
        #expect(sent.recipientWorkspaceId == "agent-workspace")
        #expect(sent.body == "I checked the change.")
        #expect(sent.inReplyTo == "incoming-1")
        #expect(store.messages() == [sent])
    }

}
