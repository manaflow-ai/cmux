import Foundation
import Testing
@testable import CmuxNativeWire

@Suite struct LineFramingTests {
    let framer = LineFramer()

    @Test func smallLineIsOneNewlineTerminatedMessage() throws {
        let line = Data(#"{"id":1,"cmd":"identify"}"#.utf8)
        let messages = framer.encode(line: line)
        #expect(messages == [line + Data([0x0A])])
        // A trailing newline on input is not doubled.
        #expect(framer.encode(line: line + Data([0x0A])) == messages)
        var r = LineReassembler()
        #expect(try r.accept(messages[0]) == [line])
    }

    @Test func exactlyAtLimitIsNotFragmented() {
        let line = Data(repeating: UInt8(ascii: "a"), count: LineFramer.defaultMaximumMessageBytes - 1)
        let messages = framer.encode(line: line)
        #expect(messages.count == 1)
        #expect(messages[0].count == LineFramer.defaultMaximumMessageBytes)
    }

    @Test func largeLineFragmentsUnderLimitAndReassembles() throws {
        // Multi-byte UTF-8 so fragment boundaries split code points.
        let text = #"{"id":7,"ok":true,"data":""# + String(repeating: "é漢🙂x", count: 20_000) + #""}"#
        let line = Data(text.utf8)
        let messages = framer.encode(line: line)
        #expect(messages.count > 1)
        for (k, message) in messages.enumerated() {
            #expect(message.count <= LineFramer.defaultMaximumMessageBytes)
            #expect(message.last == 0x0A)
            #expect(message.starts(with: Data(#"{"frag":\#(k),"of":\#(messages.count),"d":""#.utf8)))
        }
        var r = LineReassembler()
        var out: [Data] = []
        for message in messages { out += try r.accept(message) }
        #expect(out == [line])
        #expect(!r.isMidLine)
    }

    @Test func fragmentEnvelopeIsValidJSON() throws {
        let line = Data(repeating: UInt8(ascii: "z"), count: 40_000)
        for message in framer.encode(line: line) {
            let object = try JSONSerialization.jsonObject(with: message.dropLast()) as? [String: Any]
            #expect(object?["frag"] is Int)
            #expect(object?["of"] is Int)
            #expect(object?["d"] is String)
        }
    }

    @Test func outOfOrderFragmentsAreRejected() throws {
        let messages = framer.encode(line: Data(repeating: 1, count: 50_000))
        #expect(messages.count >= 3)
        var r = LineReassembler()
        _ = try r.accept(messages[0])
        #expect(throws: LineReassembler.Failure.self) { try r.accept(messages[2]) }
    }

    @Test func plainLineDuringFragmentIsRejected() throws {
        let messages = framer.encode(line: Data(repeating: 1, count: 50_000))
        var r = LineReassembler()
        _ = try r.accept(messages[0])
        #expect(throws: LineReassembler.Failure.badFragment) { try r.accept(Data("{\"id\":1}\n".utf8)) }
    }

    @Test func oversizeReassemblyIsRejected() throws {
        let messages = framer.encode(line: Data(repeating: 1, count: 50_000))
        var r = LineReassembler(maximumLineBytes: 20_000)
        #expect(throws: LineReassembler.Failure.lineTooLarge) {
            for message in messages { _ = try r.accept(message) }
        }
    }

    @Test func plainMessageMayCarrySeveralLines() throws {
        var r = LineReassembler()
        #expect(try r.accept(Data("{\"a\":1}\n{\"b\":2}\n".utf8)) == [Data("{\"a\":1}".utf8), Data("{\"b\":2}".utf8)])
        #expect(try r.accept(Data("{\"c\":3}".utf8)) == [Data("{\"c\":3}".utf8)])
    }

    @Test func customLimitRoundTrips() throws {
        let small = LineFramer(maximumMessageBytes: 512)
        let line = Data((0..<5000).map { UInt8($0 % 251) })
        let messages = small.encode(line: line)
        #expect(messages.allSatisfy { $0.count <= 512 })
        var r = LineReassembler()
        var out: [Data] = []
        for message in messages { out += try r.accept(message) }
        #expect(out == [line])
    }

    @Test func byteStreamSplitterHandlesPartialChunks() throws {
        var s = ByteStreamLineSplitter(maximumLineBytes: 1024)
        #expect(try s.append(Data("{\"id\":1".utf8)) == [])
        #expect(try s.append(Data("}\n{\"id\":2}\n\n{\"id\"".utf8)) == [Data("{\"id\":1}".utf8), Data("{\"id\":2}".utf8)])
        #expect(s.pendingByteCount == 5)
        #expect(try s.append(Data(":3}\n".utf8)) == [Data("{\"id\":3}".utf8)])
        #expect(s.pendingByteCount == 0)
    }

    @Test func byteStreamSplitterEnforcesLimit() {
        var s = ByteStreamLineSplitter(maximumLineBytes: 8)
        #expect(throws: ByteStreamLineSplitter.Failure.lineTooLarge) { try s.append(Data(repeating: 0x41, count: 9)) }
    }
}

@Suite struct WireModelTests {
    @Test func signalMessageRoundTrip() throws {
        let m = SignalMessage.ice(sid: "s1", candidate: IceCandidate(candidate: "candidate:1 1 udp 1 1.2.3.4 5 typ host", sdpMid: "0", sdpMLineIndex: 0))
        let decoded = try SignalMessage(jsonString: try m.jsonString())
        #expect(decoded == m)
        let fromDO = try SignalMessage(jsonString: #"{"t":"offer","sid":"x","sdp":"v=0","from":"phone","user_id":"u1"}"#)
        #expect(fromDO.t == .offer && fromDO.userID == "u1" && fromDO.from == "phone")
    }

    @Test func iceServerUrlsAcceptStringOrArray() throws {
        let json = #"{"iceServers":[{"urls":"stun:stun.cloudflare.com:3478"},{"urls":["turn:a","turns:b"],"username":"u","credential":"c"}],"ttl":86400,"expires_at":1}"#
        let r = try JSONDecoder().decode(IceServersResponse.self, from: Data(json.utf8))
        #expect(r.iceServers[0].urls == ["stun:stun.cloudflare.com:3478"])
        #expect(r.iceServers[1].urls.count == 2 && r.iceServers[1].username == "u")
    }

    @Test func serviceMessagesClassify() throws {
        let req = try ServiceMessage(line: Data(#"{"id":3,"method":"fs.list","params":{"path":"~"}}"#.utf8))
        #expect(req == .request(ServiceRequest(id: 3, method: "fs.list", params: ["path": "~"])))
        let ok = try ServiceMessage(line: Data(#"{"id":3,"ok":true,"result":{"n":1}}"#.utf8))
        #expect(ok == .response(ServiceResponse(id: 3, result: ["n": 1])))
        let err = try ServiceMessage(line: Data(#"{"id":4,"ok":false,"error":{"code":"forbidden","message":"no"}}"#.utf8))
        #expect(err == .response(ServiceResponse(id: 4, error: .forbidden("no"))))
        let ev = try ServiceMessage(line: Data(#"{"event":"feed.item","payload":{}}"#.utf8))
        #expect(ev == .event(ServiceEvent(event: "feed.item", payload: [:])))
        let line = try ServiceMessage.response(ServiceResponse(id: 9, result: ["a": true])).line()
        #expect(String(decoding: line, as: UTF8.self) == #"{"id":9,"ok":true,"result":{"a":true}}"#)
    }
}
