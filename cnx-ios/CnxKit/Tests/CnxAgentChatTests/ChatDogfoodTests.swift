@testable import CnxAgentChat
import Foundation
import Testing

/// Logic fixes from the chat dogfood pass (verify/chat-dogfood.md).
@Suite struct WorkingIndicatorTests {
    private func call(_ id: String, _ status: ACPToolCall.Status, kind: ACPToolCall.Kind = .read) -> ACPToolCall {
        ACPToolCall(id: id, title: "Read \(id)", kind: kind, status: status)
    }

    @Test func showsBeforeTheFirstRowAndAfterFinishedTools() {
        #expect([TurnRow]().needsWorkingIndicator)
        #expect([TurnRow.tool(call("a", .completed))].needsWorkingIndicator)
        #expect([TurnRow.toolGroup(id: "g", calls: [call("a", .completed), call("b", .failed)])].needsWorkingIndicator)
        #expect([TurnRow.plan(id: "p", entries: [])].needsWorkingIndicator)
    }

    @Test func hiddenWhileTheLastRowShowsItsOwnProgress() {
        #expect(![TurnRow.message(id: "m", markdown: "Hi")].needsWorkingIndicator)
        #expect(![TurnRow.thought(id: "t", text: "…")].needsWorkingIndicator)
        #expect(![TurnRow.tool(call("a", .inProgress))].needsWorkingIndicator)
        #expect(![TurnRow.edit(call("e", .pending, kind: .edit))].needsWorkingIndicator)
        #expect(![TurnRow.toolGroup(id: "g", calls: [call("a", .completed), call("b", .inProgress)])].needsWorkingIndicator)
    }

    @Test func hiddenWhileWaitingOnThePerson() {
        let request = ACPPermissionRequest(id: "r", toolCall: call("x", .pending, kind: .execute), options: [])
        #expect(![TurnRow.permission(PermissionRecord(request: request))].needsWorkingIndicator)
        #expect([TurnRow.permission(PermissionRecord(request: request, resolution: .cancelled))].needsWorkingIndicator)
        #expect(![TurnRow.question("q")].needsWorkingIndicator)
    }
}

/// "Reply instead" on a permission request (SPEC 6.5): the reply denies the
/// request and is sent as guidance, so the agent is never left waiting on a
/// permission nobody can answer.
@MainActor
@Suite struct ReplyInsteadTests {
    @Test func replyDeniesThePendingPermissionAndQueuesTheGuidance() async throws {
        let mock = MockAgentSession(
            summary: AgentSessionSummary(id: "s", name: "S", harness: "claude", agentName: "Claude", cwd: "~", workspaceTitle: "w", macName: "m"),
            sleep: { _ in await Task.yield() }
        )
        mock.chunkSize = 4000
        let store = AgentChatStore(source: mock)
        while store.turns.isEmpty { await Task.yield() }
        store.send(prompt: "go")
        while store.pendingPermission == nil { await Task.yield() }
        let request = try #require(store.pendingPermission).request
        store.send(prompt: "Run only the dialer tests instead")
        for _ in 0..<200 where store.pendingPermission != nil { await Task.yield() }
        #expect(store.pendingPermission == nil)
        let record = store.turns.last?.items.compactMap { item -> PermissionRecord? in
            if case .permission(let record) = item, record.request.id == request.id { return record }
            return nil
        }.first
        if case .chose(let option) = record?.resolution {
            #expect(!option.isAllow)
        } else {
            Issue.record("permission not denied: \(String(describing: record?.resolution))")
        }
        for _ in 0..<200 where store.queue.isEmpty { await Task.yield() }
        #expect(store.queue.map(\.text) == ["Run only the dialer tests instead"])
    }
}
