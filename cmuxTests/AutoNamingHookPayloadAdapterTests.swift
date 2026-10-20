import Foundation
import Testing

/// Behavior tests for the hook-payload source adapter used by agents whose
/// cmux hooks expose recent prompt/assistant text instead of a transcript file.
@Suite struct AutoNamingHookPayloadAdapterTests {
    private let engine = AutoNamingEngine()

    @Test(arguments: [
        "pi",
        "omp"
    ])
    func extractsDirectPromptAndAssistantFields(agent: String) {
        let object: [String: Any] = [
            "session_id": "\(agent)-session",
            "prompt": "Add \(agent) workspace naming",
            "last_assistant_message": "I will summarize the hook transcript."
        ]

        let messages = engine.extractHookMessages(fromPayloadObjects: [object])
        #expect(messages == [
            AutoNamingTranscriptMessage(role: "user", text: "Add \(agent) workspace naming"),
            AutoNamingTranscriptMessage(role: "assistant", text: "I will summarize the hook transcript.")
        ])
    }

    @Test func extractsOpenCodeContextMessages() {
        let object: [String: Any] = [
            "session_id": "opencode-session",
            "hook_event_name": "session.idle",
            "context": [
                "lastUserMessage": "Implement OpenCode workspace naming",
                "assistantPreamble": "I found the plugin event stream."
            ]
        ]

        let messages = engine.extractHookMessages(fromPayloadObjects: [object])
        #expect(messages == [
            AutoNamingTranscriptMessage(role: "user", text: "Implement OpenCode workspace naming"),
            AutoNamingTranscriptMessage(role: "assistant", text: "I found the plugin event stream.")
        ])
    }

    @Test func hookMessageLineEquivalentsReachSharedThrottleFloor() {
        let messages = [
            AutoNamingTranscriptMessage(role: "user", text: "Name this workspace"),
            AutoNamingTranscriptMessage(role: "assistant", text: "I can summarize it.")
        ]

        let lineCount = engine.hookMessageLineEquivalentCount(messages)
        #expect(lineCount == engine.config.minTranscriptLines)

        let decision = engine.throttleDecision(
            snapshot: AutoNamingSessionSnapshot(),
            transcriptLineCount: lineCount,
            now: Date(timeIntervalSince1970: 1_000_000)
        )
        #expect(decision == .proceed(baseline: lineCount))
    }

    @Test func hookMessageLineEquivalentsUseMonotonicTotalWhenCacheIsCapped() {
        let messages = [
            AutoNamingTranscriptMessage(role: "user", text: "Newest request"),
            AutoNamingTranscriptMessage(role: "assistant", text: "Newest answer")
        ]

        let lineCount = engine.hookMessageLineEquivalentCount(messages, totalMessageCount: 40)
        #expect(lineCount == 40 * engine.config.minLineGrowth)
    }

    @Test func sharedEnginePipelineParityWithHookContent() throws {
        let messages = engine.extractHookMessages(fromPayloadObjects: [[
            "prompt": "Name Pi and OpenCode sessions",
            "assistant_response": "Use the same auto-naming engine."
        ]])
        let context = try #require(engine.buildContext(from: messages))
        let prompt = engine.buildPrompt(currentTitle: nil, context: context)
        #expect(prompt.contains("Name Pi and OpenCode sessions"))
        #expect(prompt.contains("Use the same auto-naming engine."))
        #expect(!prompt.contains("current title"))
    }
}
