import CmuxAgentJournal
import CmuxControlSocket
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct AgentMessageHookClaimTests {
    @Test("The stop hook reads old deliveries before claiming queued messages")
    func stopHookClaimsQueuedMessagesAfterAcknowledgingDeliveredMessages() async throws {
        let surfaceID = UUID()
        let previous = try appendMessage(to: surfaceID, body: "already delivered")
        let delivered = AgentMessageCenter.store.claimQueued(
            recipientSurfaceId: surfaceID.uuidString,
            via: "claude.wake"
        ).first
        let deliveredAt = try #require(delivered?.deliveredAt)
        let queued = try appendMessage(to: surfaceID, body: "stop hook delivery")

        let response = await TerminalController.shared.agentMessageResponse(ControlRequest(
            id: .string("stop-hook"),
            method: "agent.message.claim",
            params: [
                "surface_id": .string(surfaceID.uuidString),
                "via": .string("codex.stop"),
                "mark_delivered_read": .bool(true),
            ]
        ))
        let result = try decodeResult(response)
        let payloadMessages = try #require(result["messages"] as? [[String: Any]])
        let payload = try #require(payloadMessages.first)

        #expect(payloadMessages.count == 1)
        #expect(payload["id"] as? String == queued.id)
        #expect(payload["state"] as? String == AgentMessageDeliveryState.delivered.rawValue)
        #expect(payload["delivered_via"] as? String == "codex.stop")
        #expect((payload["delivered_at"] as? NSNumber)?.doubleValue != nil)
        #expect(AgentMessageCenter.store.message(id: previous.id)?.state == .read)
        #expect(AgentMessageCenter.store.message(id: delivered?.id ?? "")?.deliveredAt == deliveredAt)
        #expect(AgentMessageCenter.store.message(id: queued.id)?.state == .delivered)
        #expect(AgentMessageCenter.store.message(id: queued.id)?.deliveredVia == "codex.stop")
        #expect(AgentMessageCenter.store.message(id: queued.id)?.deliveredAt != nil)
    }

    @Test("Register polling reads old deliveries without consuming queued messages")
    func registerPollLeavesQueuedMessagesForTheNextClaim() async throws {
        let surfaceID = UUID()
        let previous = try appendMessage(to: surfaceID, body: "already delivered")
        let delivered = AgentMessageCenter.store.claimQueued(
            recipientSurfaceId: surfaceID.uuidString,
            via: "claude.wake"
        ).first
        let deliveredAt = try #require(delivered?.deliveredAt)
        let queued = try appendMessage(to: surfaceID, body: "waiting for wake")

        let response = await TerminalController.shared.agentMessageResponse(ControlRequest(
            id: .string("register"),
            method: "agent.message.poll",
            params: [
                "surface_id": .string(surfaceID.uuidString),
                "poller_key": .string("poller-1"),
                "register": .bool(true),
                "mark_delivered_read": .bool(true),
            ]
        ))
        let result = try decodeResult(response)

        #expect(result["status"] as? String == "current")
        #expect(result["queued"] as? Int == 1)
        #expect(AgentMessageCenter.store.message(id: previous.id)?.state == .read)
        #expect(AgentMessageCenter.store.message(id: delivered?.id ?? "")?.deliveredAt == deliveredAt)
        #expect(AgentMessageCenter.store.message(id: queued.id)?.state == .queued)
        #expect(AgentMessageCenter.store.message(id: queued.id)?.deliveredAt == nil)
        #expect(AgentMessageCenter.store.message(id: queued.id)?.deliveredVia == nil)
    }

    @Test("Human mark_read can acknowledge queued and delivered messages")
    func humanMarkReadStillIncludesQueuedMessages() async throws {
        let surfaceID = UUID()
        let delivered = try appendMessage(to: surfaceID, body: "delivered")
        _ = AgentMessageCenter.store.claimQueued(
            recipientSurfaceId: surfaceID.uuidString,
            via: "claude.wake"
        )
        let queued = try appendMessage(to: surfaceID, body: "queued")
        #expect(AgentMessageCenter.store.message(id: queued.id)?.state == .queued)

        let response = await TerminalController.shared.agentMessageResponse(ControlRequest(
            id: .string("human-read"),
            method: "agent.message.mark_read",
            params: ["surface_id": .string(surfaceID.uuidString)]
        ))
        let result = try decodeResult(response)
        let readIDs = try #require(result["read"] as? [String])

        #expect(Set(readIDs) == Set([queued.id, delivered.id]))
        #expect(AgentMessageCenter.store.message(id: queued.id)?.state == .read)
        #expect(AgentMessageCenter.store.message(id: delivered.id)?.state == .read)
    }

    private func appendMessage(to surfaceID: UUID, body: String) throws -> AgentMessage {
        try AgentMessageCenter.store.append(AgentMessageDraft(
            senderName: "test",
            senderSurfaceId: UUID().uuidString,
            recipientSurfaceId: surfaceID.uuidString,
            body: body
        ))
    }

    private func decodeResult(_ response: String) throws -> [String: Any] {
        let envelope = try #require(
            JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any]
        )
        try #require(envelope["ok"] as? Bool == true, Comment(rawValue: response))
        return try #require(envelope["result"] as? [String: Any])
    }
}
