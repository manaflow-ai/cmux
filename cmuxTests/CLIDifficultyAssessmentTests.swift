import CMUXAgentLaunch
import Foundation
import Testing

// DifficultyAssessmentEngine is compiled directly into this test target (like
// AutoNamingEngine); the hook store delegates its throttle to the pure
// `throttleDecision` exercised here, so the store tests need no CLI process.

@Suite struct CLIDifficultyAssessmentTests {
    private typealias Engine = DifficultyAssessmentEngine
    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    @Test func promptTruncatesEachExcerpt() {
        let limit = DifficultyAssessmentConfig.excerptLimit
        let prompt = Engine.buildPrompt(
            lastUserMessage: String(repeating: "u", count: limit + 500),
            lastAssistantMessage: String(repeating: "a", count: limit + 500)
        )
        #expect(prompt.contains(String(repeating: "u", count: limit)))
        #expect(!prompt.contains(String(repeating: "u", count: limit + 1)))
        #expect(prompt.contains(String(repeating: "a", count: limit)))
        #expect(!prompt.contains(String(repeating: "a", count: limit + 1)))
        #expect(prompt.contains("easy") && prompt.contains("normal") && prompt.contains("hard"))
    }

    @Test func parseAcceptsOneWordWithPunctuation() {
        #expect(Engine.parse("Hard.") == .hard)
        #expect(Engine.parse("\n  \"easy\"\n") == .easy)
        #expect(Engine.parse("normal\nbecause it is fine") == .normal)
    }

    @Test func parseRejectsSentences() {
        #expect(Engine.parse("This looks hard") == nil)
        #expect(Engine.parse("") == nil)
        #expect(Engine.parse("medium") == nil)
    }

    @Test func excerptTakesLastOfEachRole() {
        let messages = [
            AutoNamingTranscriptMessage(role: "user", text: "u1"),
            AutoNamingTranscriptMessage(role: "assistant", text: "a1"),
            AutoNamingTranscriptMessage(role: "user", text: "u2"),
        ]
        let pair = Engine.excerpt(from: messages)
        #expect(pair?.user == "u2")
        #expect(pair?.assistant == "a1")
        #expect(Engine.excerpt(from: Array(messages.prefix(1))) == nil)
    }

    @Test func storeThrottlesWithinMinInterval() {
        let min = DifficultyAssessmentConfig.minInterval
        let stamp = t0.timeIntervalSince1970
        #expect(Engine.throttleDecision(inFlightAt: nil, lastAssessedAt: nil, now: t0) == .proceed)
        #expect(Engine.throttleDecision(inFlightAt: nil, lastAssessedAt: stamp, now: t0.addingTimeInterval(min - 1)) == .skipTooSoon)
        #expect(Engine.throttleDecision(inFlightAt: nil, lastAssessedAt: stamp, now: t0.addingTimeInterval(min)) == .proceed)
    }

    @Test func storeSkipsWhileInFlightUntilExpiry() {
        let expiry = DifficultyAssessmentConfig.inFlightExpiry
        let stamp = t0.timeIntervalSince1970
        #expect(Engine.throttleDecision(inFlightAt: stamp, lastAssessedAt: nil, now: t0.addingTimeInterval(expiry - 1)) == .skipInFlight)
        #expect(Engine.throttleDecision(inFlightAt: stamp, lastAssessedAt: nil, now: t0.addingTimeInterval(expiry)) == .proceed)
    }
}
