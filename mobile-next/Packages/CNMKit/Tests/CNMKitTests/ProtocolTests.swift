import CNMProtocol
import CNMTransport
import Foundation
import Testing

@Suite struct ProtocolTests {
    @Test func bulkFrameRoundTrips() {
        let frame = BulkFrame(kind: .output, terminal: 0x01020304, payload: Data("hello".utf8))
        let decoded = BulkFrame(decoding: frame.encoded())
        #expect(decoded == frame)
    }

    @Test func envelopeKinds() throws {
        #expect(Envelope(id: 1, method: "x").kind == .request)
        #expect(Envelope(id: 1, result: .null).kind == .response)
        #expect(Envelope(method: "x").kind == .notification)
        let data = try Envelope(id: 3, method: "a", params: ["k": 1]).encoded()
        #expect(try Envelope(decoding: data).params?["k"]?.intValue == 1)
    }

    @Test func datesSurviveJSONValue() throws {
        let date = Date(timeIntervalSince1970: 1_760_000_000.5)
        let message = ConversationMessage(id: "m", conversation: "c", sender: "me", text: "hi", sentAt: date)
        let value = try JSONValue.encode(message)
        #expect(try value.decode(ConversationMessage.self).sentAt == date)
    }

    @Test func rpcOverLoopback() async throws {
        let (a, b) = LoopbackLink.pair()
        let client = RPCPeer(link: a)
        let server = RPCPeer(link: b)
        server.start(onRequest: { method, params in
            #expect(method == "echo")
            return params ?? .null
        })
        client.start()
        let result = try await client.request("echo", params: ["x": "y"], timeout: .seconds(5))
        #expect(result["x"]?.stringValue == "y")
    }
}

#if os(macOS)
@testable import CNMHost

@Suite struct ChiefTests {
    @Test func bubblesSplitOnBlankLinesButKeepCodeTogether() {
        let reply = "First thought.\n\nSecond one.\n\n```\nline 1\n\nline 2\n```"
        #expect(ConversationStore.bubbles(from: reply) == ["First thought.", "Second one.", "```\nline 1\n\nline 2\n```"])
    }

    @Test func titlesComeFromTheFirstMessage() {
        #expect(ConversationStore.title(from: "Fix the login bug") == "Fix the login bug")
        #expect(ConversationStore.title(from: "Can you check on the demo-app agent and tell me what it did?") == "Can you check on the demo-app…")
        #expect(ConversationStore.title(from: "   ") == "Chief")
    }
}
#endif

#if os(macOS)
@Suite struct AgentLogTests {
    @Test func streamedChunksFoldIntoOneEvent() {
        var events: [AgentEvent] = []
        func chunk(_ seq: Int, _ text: String, kind: String = "agent_message_chunk") -> AgentEvent {
            AgentEvent(session: "s", seq: seq, kind: .update, at: Date(),
                       payload: ["sessionUpdate": .string(kind), "content": ["type": "text", "text": .string(text)]])
        }
        AgentManager.fold(chunk(0, "Hel"), into: &events)
        AgentManager.fold(chunk(1, "lo"), into: &events)
        AgentManager.fold(chunk(2, "hmm", kind: "agent_thought_chunk"), into: &events)
        AgentManager.fold(chunk(3, " world"), into: &events)
        #expect(events.count == 3)
        #expect(events[0].payload["content"]?["text"]?.stringValue == "Hello")
        #expect(events[0].seq == 1)
        #expect(events[2].seq == 3)
    }
}
#endif
