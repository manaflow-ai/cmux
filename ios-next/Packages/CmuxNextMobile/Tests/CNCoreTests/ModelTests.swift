import CNCore
import Foundation
import Testing

@Suite struct TranscriptItemTests {
    func decode(_ json: String) throws -> TranscriptItem {
        try JSONDecoder().decode(TranscriptItem.self, from: Data(json.utf8))
    }

    @Test func decodesEveryKnownKind() throws {
        let items = try JSONDecoder().decode([TranscriptItem].self, from: Data("""
        [
          {"id":"1","kind":"user","text":"hi","attachments":[{"name":"a.png","mimeType":"image/png"}]},
          {"id":"2","kind":"assistant","text":"**md**","streaming":true},
          {"id":"3","kind":"thought","text":"hmm","streaming":false,"durationMs":1200},
          {"id":"4","kind":"tool","toolKind":"edit","title":"Edit","status":"completed","input":{"a":1},"output":"ok",
           "locations":[{"path":"a.swift","line":3}],"diff":[{"path":"a.swift","oldText":"x","newText":"y"}]},
          {"id":"5","kind":"plan","entries":[{"content":"do it","status":"in_progress","priority":"high"}]},
          {"id":"6","kind":"permission","toolCallId":"4","title":"Allow?","options":[{"id":"o","name":"Allow","kind":"allow_once"}]},
          {"id":"7","kind":"notice","level":"warning","text":"careful"},
          {"id":"8","kind":"turnEnd","stopReason":"end_turn","durationMs":5}
        ]
        """.utf8))
        #expect(items.map(\.kind) == ["user", "assistant", "thought", "tool", "plan", "permission", "notice", "turnEnd"])
        guard case .tool(let tool) = items[3] else { Issue.record("not a tool"); return }
        #expect(tool.toolKind == .edit)
        #expect(tool.diff?.first?.newText == "y")
        #expect(tool.input?["a"] == 1)
        guard case .plan(let plan) = items[4] else { Issue.record("not a plan"); return }
        #expect(plan.entries[0].status == .inProgress)
        guard case .permission(let perm) = items[5] else { Issue.record("not a permission"); return }
        #expect(perm.options[0].kind == .allowOnce && perm.resolved == nil)
        #expect(items[1].isStreaming)
    }

    @Test func preservesUnknownKind() throws {
        let item = try decode(#"{"id":"x9","kind":"hologram","beam":{"w":3}}"#)
        guard case .unknown(let u) = item else { Issue.record("expected unknown"); return }
        #expect(u.id == "x9" && u.kind == "hologram")
        #expect(u.raw["beam"]?["w"] == 3)
        let again = try JSONDecoder().decode(TranscriptItem.self, from: JSONEncoder().encode(item))
        #expect(again == item)
    }

    @Test func roundTripsKnownKindWithKindField() throws {
        let item = TranscriptItem.notice(NoticeTranscriptItem(id: "n", level: .error, text: "boom"))
        let json = try JSONValue(encoding: item)
        #expect(json["kind"] == "notice")
        #expect(try json.decode(as: TranscriptItem.self) == item)
    }

    @Test func unknownEnumValuesFallBack() throws {
        let tool = try decode(#"{"id":"t","kind":"tool","toolKind":"teleport","title":"x","status":"vaporized"}"#)
        guard case .tool(let t) = tool else { Issue.record("not tool"); return }
        #expect(t.toolKind == .other && t.status == .unknown && t.locations.isEmpty)
    }
}

@Suite struct SignalAndEnvelopeTests {
    @Test func signalMessagesRoundTrip() throws {
        let messages: [SignalMessage] = [
            .welcome(peerId: "p_1", hosts: [HostPresence(hostId: "h_1", online: true)]),
            .presence(HostPresence(hostId: "h_1", online: false)),
            .offer(to: "h_1", from: nil, sessionId: "s_1", sdp: "v=0"),
            .candidate(to: "h_1", from: "p_1", sessionId: "s_1", candidate: "candidate:1", sdpMid: "0", sdpMLineIndex: 0),
            .bye(to: "h_1", from: nil, sessionId: "s_1"),
            .error(code: "host_offline", message: nil, sessionId: "s_1"),
        ]
        for m in messages {
            #expect(try JSONDecoder().decode(SignalMessage.self, from: JSONEncoder().encode(m)) == m)
        }
        let unknown = try JSONDecoder().decode(SignalMessage.self, from: Data(#"{"type":"future","x":1}"#.utf8))
        guard case .unknown(let type, _) = unknown else { Issue.record("expected unknown"); return }
        #expect(type == "future")
    }

    @Test func controlEnvelopeDecodesError() throws {
        let env = try JSONDecoder().decode(ControlEnvelope.self, from: Data(#"{"t":"res","id":7,"ok":false,"e":{"code":"not_found","message":"nope"}}"#.utf8))
        #expect(env.e == RPCError(code: .notFound, message: "nope"))
    }

    @Test func iceServerAcceptsStringURL() throws {
        let cfg = try JSONDecoder().decode(ICEConfiguration.self, from: Data(#"{"iceServers":[{"urls":"stun:a"},{"urls":["turn:b"],"username":"u","credential":"c"}],"ttl":600}"#.utf8))
        #expect(cfg.iceServers[0].urls == ["stun:a"])
        #expect(cfg.iceServers[1].credential == "c")
    }
}
