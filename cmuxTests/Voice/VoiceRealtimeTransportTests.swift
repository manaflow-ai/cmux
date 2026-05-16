import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class VoiceRealtimeTransportTests: XCTestCase {
    func testSessionUpdateEncoding() throws {
        let event = RealtimeClientEvent.sessionUpdate(
            model: "gpt-4o-realtime-preview",
            instructions: "test",
            tools: VoiceToolDefinitions.all
        )
        let data = try JSONEncoder().encode(event)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "session.update")
        let session = json["session"] as? [String: Any]
        XCTAssertEqual(session?["model"] as? String, "gpt-4o-realtime-preview")
    }

    func testAudioAppendEncoding() throws {
        let audio = Data([0x01, 0x02])
        let event = RealtimeClientEvent.audioAppend(audio)
        let data = try JSONEncoder().encode(event)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "input_audio_buffer.append")
        XCTAssertFalse((json["audio"] as? String ?? "").isEmpty)
    }

    func testFunctionCallOutputEncoding() throws {
        let event = RealtimeClientEvent.functionCallOutput(callId: "call_abc", output: #"{"ok":true}"#)
        let data = try JSONEncoder().encode(event)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "conversation.item.create")
        let item = json["item"] as? [String: Any]
        XCTAssertEqual(item?["type"] as? String, "function_call_output")
        XCTAssertEqual(item?["call_id"] as? String, "call_abc")
    }

    func testServerEventParsingFunctionCallDone() throws {
        let json = """
        {
          "type": "response.function_call_arguments.done",
          "call_id": "call_xyz",
          "name": "switch_workspace",
          "arguments": "{\\"id\\":\\"uuid-here\\"}"
        }
        """
        let event = try JSONDecoder().decode(RealtimeServerEvent.self, from: Data(json.utf8))
        guard case .functionCallDone(let call) = event else {
            XCTFail("Expected .functionCallDone"); return
        }
        XCTAssertEqual(call.callId, "call_xyz")
        XCTAssertEqual(call.name, "switch_workspace")
    }

    func testServerEventParsingUnknownIsIgnored() throws {
        let json = #"{"type":"session.created","session":{}}"#
        let event = try JSONDecoder().decode(RealtimeServerEvent.self, from: Data(json.utf8))
        guard case .other = event else {
            XCTFail("Expected .other"); return
        }
    }
}
