import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class VoiceRealtimeEventParserTests: XCTestCase {
    @MainActor
    func testVoiceToolsExposeWorkspaceFocusAndImplicitFocusTarget() {
        let tools = VoiceToolExecutor().toolDefinitions

        let createWorkspace = tools.first { $0["name"] as? String == "cmux_create_workspace" }
        let workspaceParameters = createWorkspace?["parameters"] as? [String: Any]
        let workspaceProperties = workspaceParameters?["properties"] as? [String: Any]
        XCTAssertNotNil(workspaceProperties?["focus"])

        let focus = tools.first { $0["name"] as? String == "cmux_focus" }
        let focusParameters = focus?["parameters"] as? [String: Any]
        let required = focusParameters?["required"] as? [String]
        XCTAssertTrue(required?.isEmpty ?? false)
    }

    func testExtractsFunctionCallsFromResponseDone() {
        let event: [String: Any] = [
            "type": "response.done",
            "response": [
                "output": [
                    [
                        "type": "function_call",
                        "name": "cmux_get_context",
                        "call_id": "call_123",
                        "arguments": "{}"
                    ]
                ]
            ]
        ]

        XCTAssertEqual(
            VoiceRealtimeEventParser.functionCalls(in: event),
            [
                VoiceRealtimeFunctionCall(
                    callID: "call_123",
                    name: "cmux_get_context",
                    arguments: "{}"
                )
            ]
        )
    }

    func testParsesOpenAIKeyFromEnvFile() {
        let key = OpenAIAPIKeyResolver.parseAPIKey(from: """
        # comment
        OPENAI_API_KEY="sk-proj-test"
        """)

        XCTAssertEqual(key, "sk-proj-test")
    }

    func testReadsAssistantTranscriptDelta() {
        let event: [String: Any] = [
            "type": "response.output_audio_transcript.delta",
            "delta": "hello"
        ]

        XCTAssertEqual(VoiceRealtimeEventParser.assistantDelta(in: event), "hello")
    }

    func testReadsUserTranscriptionDelta() {
        let event: [String: Any] = [
            "type": "conversation.item.input_audio_transcription.delta",
            "item_id": "item_123",
            "delta": "open"
        ]

        XCTAssertEqual(
            VoiceRealtimeEventParser.userTranscriptionDelta(in: event),
            VoiceRealtimeTextDelta(itemID: "item_123", text: "open")
        )
    }

    func testReadsSpeechStartedItemID() {
        let event: [String: Any] = [
            "type": "input_audio_buffer.speech_started",
            "item_id": "item_456"
        ]

        XCTAssertEqual(VoiceRealtimeEventParser.speechStartedItemID(in: event), "item_456")
    }

    func testDetectsActiveResponseError() {
        let event: [String: Any] = [
            "type": "error",
            "error": [
                "code": "conversation_already_has_active_response",
                "message": "Conversation already has an active response in progress."
            ]
        ]

        XCTAssertTrue(VoiceRealtimeEventParser.isActiveResponseError(in: event))
    }
}
