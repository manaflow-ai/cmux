import Foundation
import Testing

/// Behavior tests for the Grok chat-history adapter: extraction from native
/// `chat_history.jsonl`, injected metadata filtering, and shared-engine parity.
@Suite struct AutoNamingGrokAdapterTests {
    private let engine = AutoNamingEngine()

    private func historyLine(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    @Test func extractsUserAndAssistantMessagesFromChatHistory() {
        let lines = [
            historyLine(["type": "system", "content": "You are Grok"]),
            historyLine(["type": "user", "content": "Fix the Grok session restore bug"]),
            historyLine(["type": "assistant", "content": "I will inspect the resume path."]),
            historyLine(["role": "assistant", "content": [["type": "text", "text": "The restore command is patched."]]]),
            "not json"
        ]

        let messages = engine.extractGrokMessages(fromChatHistoryLines: lines)
        #expect(messages == [
            AutoNamingTranscriptMessage(role: "user", text: "Fix the Grok session restore bug"),
            AutoNamingTranscriptMessage(role: "assistant", text: "I will inspect the resume path."),
            AutoNamingTranscriptMessage(role: "assistant", text: "The restore command is patched.")
        ])
    }

    @Test func userQueryTagWinsOverInjectedMetadata() {
        let userContent = """
        <user_info>
        OS Version: macos 26.4
        </user_info>
        <git_status>
        Current branch: feat/auto-name
        </git_status>
        <user_query>
        Add Grok workspace naming
        </user_query>
        """
        let lines = [
            historyLine(["type": "user", "content": userContent]),
            historyLine(["type": "assistant", "content": "Done."])
        ]

        let messages = engine.extractGrokMessages(fromChatHistoryLines: lines)
        #expect(messages.first == AutoNamingTranscriptMessage(role: "user", text: "Add Grok workspace naming"))
    }

    @Test func sharedEnginePipelineParityWithGrokContent() throws {
        let lines = [
            historyLine(["type": "user", "content": "Name workspaces from Grok history"]),
            historyLine(["type": "assistant", "content": "I will use chat_history.jsonl."])
        ]
        let messages = engine.extractGrokMessages(fromChatHistoryLines: lines)
        let context = try #require(engine.buildContext(from: messages))
        let prompt = engine.buildPrompt(currentTitle: "Old title", context: context)
        #expect(prompt.contains("Name workspaces from Grok history"))
        #expect(prompt.contains("The current title is: Old title"))

        let decision = engine.throttleDecision(
            snapshot: AutoNamingSessionSnapshot(),
            transcriptLineCount: engine.config.minTranscriptLines,
            now: Date(timeIntervalSince1970: 1_000_000)
        )
        #expect(decision == .proceed(baseline: engine.config.minTranscriptLines))
    }
}
