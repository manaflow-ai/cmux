import CmuxiOSPush
import Foundation
import Testing

private struct FixtureTransport: CloudChatTransport {
    func sessions() async throws -> [CloudChatSession] {
        [CloudChatSession(id: "s1", title: "Review", machineID: "vm-1")]
    }

    func history(sessionID: String) async throws -> [CloudChatMessage] {
        [CloudChatMessage(id: "m1", role: .assistant, text: "Ready")]
    }

    func send(sessionID: String, text: String) async throws -> CloudChatMessage {
        CloudChatMessage(id: "m2", role: .user, text: text)
    }
}

private struct MultipleSessionTransport: CloudChatTransport {
    let all: [CloudChatSession] = [
        CloudChatSession(id: "first", title: "First", machineID: "vm-1"),
        CloudChatSession(id: "attention", title: "Needs attention", machineID: "vm-2"),
    ]

    func sessions() async throws -> [CloudChatSession] { all }

    func history(sessionID: String) async throws -> [CloudChatMessage] {
        [CloudChatMessage(id: "m-\(sessionID)", role: .assistant, text: sessionID)]
    }

    func send(sessionID: String, text: String) async throws -> CloudChatMessage {
        CloudChatMessage(id: "sent", role: .user, text: text)
    }
}

private struct EmptySessionTransport: CloudChatTransport {
    func sessions() async throws -> [CloudChatSession] { [] }
    func history(sessionID: String) async throws -> [CloudChatMessage] { [] }
    func send(sessionID: String, text: String) async throws -> CloudChatMessage {
        CloudChatMessage(id: "sent", role: .user, text: text)
    }
}

@Test("Cloud chat model loads, selects and sends through its transport")
@MainActor
func cloudChatModelRoundTrip() async {
    let model = CloudChatViewModel(transport: FixtureTransport())
    await model.load()
    #expect(model.sessions.map(\.id) == ["s1"])
    #expect(model.messages.map(\.text) == ["Ready"])
    await model.send("  hello  ")
    #expect(model.messages.last?.text == "hello")
}

@Test("Cloud attention chooses its requested session")
@MainActor
func cloudChatPreferredSession() async {
    let model = CloudChatViewModel(transport: MultipleSessionTransport(), preferredSessionID: "attention")
    await model.load()
    #expect(model.selectedSessionID == "attention")
    #expect(model.messages.map(\.text) == ["attention"])
    await model.load()
    #expect(model.selectedSessionID == "attention")
}

@Test("A missing attention session does not fall back to another chat")
@MainActor
func cloudChatMissingPreferredSession() async {
    let model = CloudChatViewModel(transport: EmptySessionTransport(), preferredSessionID: "gone")
    await model.load()
    #expect(model.selectedSessionID == nil)
    #expect(model.requestedSessionUnavailable)
}

@Test("Replacing the relay clears the old client state")
@MainActor
func cloudChatTransportReplacement() async {
    let model = CloudChatViewModel(transport: FixtureTransport())
    await model.load()
    #expect(model.selectedSessionID == "s1")
    model.replaceTransport(nil)
    #expect(model.sessions.isEmpty)
    #expect(model.messages.isEmpty)
    #expect(model.selectedSessionID == nil)
}

@Test("Cloud attention only accepts namespaced complete payloads")
func cloudAttentionPayload() {
    let payload: [AnyHashable: Any] = [
        "cmux.cloud.kind": "permission",
        "cmux.cloud.session_id": "s1",
        "cmux.cloud.machine_id": "vm-1",
        "cmux.cloud.title": "Approve deploy",
        "cmux.cloud.body": "Cloud needs your permission",
    ]
    let attention = CloudChatAttention(userInfo: payload)
    #expect(attention?.kind == .permission)
    #expect(attention?.sessionID == "s1")
    #expect(CloudChatAttention(userInfo: ["session_id": "s1"]) == nil)
    #expect(CloudChatAttention(userInfo: [
        "cmux.cloud.kind": "unknown", "cmux.cloud.session_id": "s1",
    ]) == nil)
    #expect(CloudChatAttention(userInfo: [
        "cmux.cloud.kind": "done", "cmux.cloud.session_id": "",
    ]) == nil)
    #expect(CloudChatAttention(userInfo: [
        "cmux.cloud.kind": "question", "cmux.cloud.body": "missing session",
    ]) == nil)
}

@Test("Cloud relay accepts an acknowledgement before the assistant reply exists")
func cloudRelayAcceptedSendEnvelope() async throws {
    let transport = CloudChatRPCTransport { method, params in
        #expect(method == "mobile.chat.send")
        #expect(params["session_id"] as? String == "s1")
        #expect(params["text"] as? String == "hello")
        return Data(#"{"accepted":true,"prompt_id":"p1"}"#.utf8)
    }
    let message = try await transport.send(sessionID: "s1", text: "hello")
    #expect(message.id == "p1")
    #expect(message.role == .user)
    #expect(message.text == "hello")
}

@Test("Cloud relay decodes a session without a machine id")
func cloudRelaySessionWithoutMachineID() async throws {
    let transport = CloudChatRPCTransport { method, _ in
        #expect(method == "mobile.chat.sessions")
        return Data(#"[{"id":"s1","title":"Cloud","state":"active"}]"#.utf8)
    }
    let sessions = try await transport.sessions()
    #expect(sessions == [CloudChatSession(id: "s1", title: "Cloud")])
}
