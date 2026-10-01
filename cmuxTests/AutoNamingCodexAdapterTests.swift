import Foundation
import Testing

// The Codex source adapter lives in the shared auto-naming engine file,
// which is compiled directly into this test target (see
// AutoNamingEngineTests for the same arrangement).

/// Behavior tests for the Codex rollout adapter: extraction from rollout
/// JSONL (`response_item` message payloads), injected-context filtering, and
/// parity of the shared engine pipeline when driven by codex content.
@Suite struct AutoNamingCodexAdapterTests {
    private let engine = AutoNamingEngine()

    private func rolloutLine(type: String, payload: [String: Any]) -> String {
        let object: [String: Any] = ["type": type, "payload": payload]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }

    private func messageLine(role: String, content: Any) -> String {
        rolloutLine(type: "response_item", payload: [
            "type": "message",
            "role": role,
            "content": content
        ])
    }

    @Test func extractsMessagesFromRolloutShapes() {
        let lines = [
            messageLine(role: "user", content: [["type": "input_text", "input_text": "Fix the auth bug"]]),
            messageLine(role: "assistant", content: [["type": "output_text", "text": "Looking at login now."]]),
            messageLine(role: "user", content: "plain string content"),
            // Event noise and non-message payloads are skipped.
            rolloutLine(type: "event_msg", payload: ["type": "task_started"]),
            rolloutLine(type: "turn_context", payload: ["turn_id": "t1"]),
            rolloutLine(type: "response_item", payload: ["type": "function_call", "name": "shell"]),
            "not json"
        ]
        let messages = engine.extractCodexMessages(fromRolloutLines: lines)
        #expect(messages == [
            AutoNamingTranscriptMessage(role: "user", text: "Fix the auth bug"),
            AutoNamingTranscriptMessage(role: "assistant", text: "Looking at login now."),
            AutoNamingTranscriptMessage(role: "user", text: "plain string content")
        ])
    }

    @Test func injectedContextBlocksAreSkipped() {
        let lines = [
            messageLine(role: "user", content: "<environment_context>cwd: /tmp</environment_context>"),
            messageLine(role: "user", content: "<user_instructions>be terse</user_instructions>"),
            messageLine(role: "user", content: "<subagent_notification>done</subagent_notification>"),
            messageLine(role: "user", content: "Actual user question about flaky tests")
        ]
        let messages = engine.extractCodexMessages(fromRolloutLines: lines)
        #expect(messages.count == 1)
        #expect(messages[0].text == "Actual user question about flaky tests")
    }

    @Test func missingOrEmptyRolloutYieldsNoContext() {
        #expect(engine.extractCodexMessages(fromRolloutLines: []).isEmpty)
        let onlyNoise = [
            rolloutLine(type: "event_msg", payload: ["type": "task_complete"]),
            "garbage"
        ]
        #expect(engine.buildContext(from: engine.extractCodexMessages(fromRolloutLines: onlyNoise)) == nil)
    }

    @Test func sharedEnginePipelineParityWithCodexContent() throws {
        // One representative pass through the shared pipeline driven by codex
        // content: extraction feeds context, context feeds the prompt, and
        // the throttle behaves identically regardless of the source adapter.
        let lines = [
            messageLine(role: "user", content: "Rename the workspace automatically"),
            messageLine(role: "assistant", content: [["type": "output_text", "text": "Plan: hook into Stop."]])
        ]
        let messages = engine.extractCodexMessages(fromRolloutLines: lines)
        let context = try #require(engine.buildContext(from: messages))
        let prompt = engine.buildPrompt(currentTitle: "Old title", context: context)
        #expect(prompt.contains("Rename the workspace automatically"))
        #expect(prompt.contains("The current title is: Old title"))

        let decision = engine.throttleDecision(
            snapshot: AutoNamingSessionSnapshot(),
            transcriptLineCount: engine.config.minTranscriptLines,
            now: Date(timeIntervalSince1970: 1_000_000)
        )
        #expect(decision == .proceed(baseline: engine.config.minTranscriptLines))
    }
}
