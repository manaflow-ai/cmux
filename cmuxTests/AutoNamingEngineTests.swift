import Foundation
import Testing

// AutoNamingEngine and its supporting types are compiled directly into this
// test target (the bundled CLI is a tool target that tests cannot import),
// so no app-module import is needed for them.

/// Behavior tests for the pure auto-naming engine: throttle decisions,
/// transcript extraction, prompt construction, response sanitization, and
/// the summarizer environment policy.
@Suite struct AutoNamingEngineTests {
    private let engine = AutoNamingEngine()
    private var config: AutoNamingConfig { engine.config }

    private func snapshot(
        lastTitle: String? = nil,
        lastLineCount: Int? = nil,
        lastNamedAt: TimeInterval? = nil,
        inFlightAt: TimeInterval? = nil,
        lastAttemptAt: TimeInterval? = nil
    ) -> AutoNamingSessionSnapshot {
        AutoNamingSessionSnapshot(
            lastTitle: lastTitle,
            lastLineCount: lastLineCount,
            lastNamedAt: lastNamedAt,
            inFlightAt: inFlightAt,
            lastAttemptAt: lastAttemptAt
        )
    }

    // MARK: - Throttle

    @Test func firstNamingAlwaysQualifies() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let decision = engine.throttleDecision(
            snapshot: snapshot(),
            transcriptLineCount: config.minTranscriptLines,
            now: now
        )
        #expect(decision == .proceed(baseline: config.minTranscriptLines))
    }

    @Test func shortTranscriptSkips() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let decision = engine.throttleDecision(
            snapshot: snapshot(),
            transcriptLineCount: config.minTranscriptLines - 1,
            now: now
        )
        #expect(decision == .skipShortTranscript)
    }

    @Test func insufficientGrowthSkipsAndSufficientGrowthQualifies() {
        let base = TimeInterval(1_000_000)
        let now = Date(timeIntervalSince1970: base + config.minInterval + 1)
        let named = snapshot(lastTitle: "Fix auth bug", lastLineCount: 100, lastNamedAt: base)

        let tooLittle = engine.throttleDecision(
            snapshot: named,
            transcriptLineCount: 100 + config.minLineGrowth - 1,
            now: now
        )
        #expect(tooLittle == .skipInsufficientGrowth)

        let enough = engine.throttleDecision(
            snapshot: named,
            transcriptLineCount: 100 + config.minLineGrowth,
            now: now
        )
        #expect(enough == .proceed(baseline: 100 + config.minLineGrowth))
    }

    @Test func timeFloorIsRespected() {
        let base = TimeInterval(1_000_000)
        let tooSoon = Date(timeIntervalSince1970: base + config.minInterval - 1)
        let decision = engine.throttleDecision(
            snapshot: snapshot(lastTitle: "Fix auth bug", lastLineCount: 100, lastNamedAt: base),
            transcriptLineCount: 100 + config.minLineGrowth * 10,
            now: tooSoon
        )
        #expect(decision == .skipTooSoon)
    }

    @Test func failedAttemptEnforcesCooldownBeforeRetry() {
        // A failed pass records lastAttemptAt but never lastNamedAt/lastLineCount.
        // Within minInterval the throttle must back off (no per-turn respawn of a
        // rate-limited summarizer); after it, retry is allowed.
        let base = TimeInterval(1_000_000)
        let failed = snapshot(lastAttemptAt: base)

        let tooSoon = engine.throttleDecision(
            snapshot: failed,
            transcriptLineCount: 100,
            now: Date(timeIntervalSince1970: base + config.minInterval - 1)
        )
        #expect(tooSoon == .skipTooSoon)

        let afterCooldown = engine.throttleDecision(
            snapshot: failed,
            transcriptLineCount: 100,
            now: Date(timeIntervalSince1970: base + config.minInterval + 1)
        )
        #expect(afterCooldown == .proceed(baseline: 100))
    }

    @Test func failureAfterSuccessBacksOffOnLastAttemptNotLastNamed() {
        // Named long ago but just attempted (and failed) again: the cooldown
        // anchors on the recent attempt, not the stale success.
        let base = TimeInterval(1_000_000)
        let attemptAt = base + config.minInterval * 5
        let snap = snapshot(
            lastTitle: "Old", lastLineCount: 100, lastNamedAt: base, lastAttemptAt: attemptAt
        )
        let decision = engine.throttleDecision(
            snapshot: snap,
            transcriptLineCount: 100 + config.minLineGrowth * 10,
            now: Date(timeIntervalSince1970: attemptAt + 1)
        )
        #expect(decision == .skipTooSoon)
    }

    @Test func compactionReseedsInsteadOfSkippingForever() {
        let base = TimeInterval(1_000_000)
        let now = Date(timeIntervalSince1970: base + config.minInterval + 1)
        let decision = engine.throttleDecision(
            snapshot: snapshot(lastTitle: "Fix auth bug", lastLineCount: 500, lastNamedAt: base),
            transcriptLineCount: 60,
            now: now
        )
        #expect(decision == .reseedBaseline(to: 60))
    }

    @Test func unexpiredInFlightMarkerSkipsAndExpiredAllowsRetry() {
        let base = TimeInterval(1_000_000)
        let unexpired = engine.throttleDecision(
            snapshot: snapshot(inFlightAt: base),
            transcriptLineCount: 100,
            now: Date(timeIntervalSince1970: base + config.inFlightExpiry - 1)
        )
        #expect(unexpired == .skipInFlight)

        // The marker outlives the LLM deadline by the grace window, so a
        // pass still in its termination/apply phase cannot be doubled.
        #expect(config.inFlightExpiry > config.llmTimeout)

        let expired = engine.throttleDecision(
            snapshot: snapshot(inFlightAt: base),
            transcriptLineCount: 100,
            now: Date(timeIntervalSince1970: base + config.inFlightExpiry + 1)
        )
        #expect(expired == .proceed(baseline: 100))
    }

    // MARK: - Extraction

    private func jsonlLine(role: String, content: Any) -> String {
        let object: [String: Any] = ["type": role, "message": ["content": content]]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }

    @Test func extractsUserAndAssistantTextSkippingNoise() {
        let lines = [
            jsonlLine(role: "user", content: "Fix the auth bug in login"),
            "not json at all",
            jsonlLine(role: "assistant", content: [["type": "text", "text": "Looking at the login flow now."]]),
            jsonlLine(role: "user", content: [["type": "tool_result", "content": "noise"]]),
            "{\"type\":\"summary\",\"summary\":\"ignored\"}",
            jsonlLine(role: "assistant", content: [["type": "thinking", "thinking": "hidden"], ["type": "text", "text": "Found it."]])
        ]
        let messages = engine.extractMessages(fromTranscriptLines: lines)
        #expect(messages == [
            AutoNamingTranscriptMessage(role: "user", text: "Fix the auth bug in login"),
            AutoNamingTranscriptMessage(role: "assistant", text: "Looking at the login flow now."),
            AutoNamingTranscriptMessage(role: "assistant", text: "Found it.")
        ])
    }

    @Test func emptyOrUnreadableTranscriptYieldsNoContext() {
        #expect(engine.buildContext(from: []) == nil)
        #expect(engine.extractMessages(fromTranscriptLines: ["", "garbage", "{}"]).isEmpty)
    }

    @Test func latestClaudeConversationTitleUsesNewestAiTitle() {
        let lines = [
            #"{"type":"ai-title","aiTitle":"Old implementation plan"}"#,
            jsonlLine(role: "user", content: "Fix the auth bug"),
            #"{"type":"ai-title","aiTitle":"\"Rename Claude tabs\""}"#
        ]

        #expect(engine.latestClaudeConversationTitle(fromTranscriptLines: lines) == "Rename Claude tabs")
    }

    @Test func latestClaudeConversationTitleFiltersBySessionId() {
        let lines = [
            #"{"type":"ai-title","sessionId":"target-session","aiTitle":"Matching title"}"#,
            #"{"type":"ai-title","session_id":"other-session","aiTitle":"Unrelated newer title"}"#
        ]

        #expect(
            engine.latestClaudeConversationTitle(
                fromTranscriptLines: lines,
                matchingSessionId: "target-session"
            ) == "Matching title"
        )
        #expect(
            engine.latestClaudeConversationTitle(
                fromTranscriptLines: lines,
                matchingSessionId: "missing-session"
            ) == nil
        )
    }

    @Test func latestClaudeConversationTitleIgnoresGenericAndMalformedTitles() {
        let lines = [
            #"{"type":"ai-title","aiTitle":"✳ Claude Code"}"#,
            #"{"type":"ai-title"}"#,
            #"{"type":"user","message":{"content":"not a title"}}"#
        ]

        #expect(engine.latestClaudeConversationTitle(fromTranscriptLines: lines) == nil)
    }

    @Test func contextCombinesHeadUserMessagesAndTailWithTruncation() throws {
        let longText = String(repeating: "x", count: config.contextMessageMaxChars + 100)
        var messages: [AutoNamingTranscriptMessage] = [
            AutoNamingTranscriptMessage(role: "user", text: "First ask"),
            AutoNamingTranscriptMessage(role: "user", text: "Second ask"),
            AutoNamingTranscriptMessage(role: "user", text: "Third ask")
        ]
        for index in 0..<10 {
            messages.append(AutoNamingTranscriptMessage(role: "assistant", text: "Reply \(index)"))
        }
        messages.append(AutoNamingTranscriptMessage(role: "user", text: longText))

        let context = try #require(engine.buildContext(from: messages))
        #expect(context.contains("user: First ask"))
        #expect(context.contains("user: Second ask"))
        #expect(!context.contains("Third ask"))
        #expect(context.contains("Reply 9"))
        // The long tail message is truncated to the per-message cap.
        #expect(!context.contains(longText))
        #expect(context.contains(String(longText.prefix(config.contextMessageMaxChars))))
    }

    // MARK: - Prompt

    @Test func promptCarriesCurrentTitleAndVerbatimInstruction() {
        let prompt = engine.buildPrompt(currentTitle: "Fix auth bug", context: "user: hello")
        #expect(prompt.contains("The current title is: Fix auth bug"))
        #expect(prompt.contains("EXACTLY"))
        #expect(prompt.contains("user: hello"))

        let untitled = engine.buildPrompt(currentTitle: nil, context: "user: hello")
        #expect(!untitled.contains("current title"))
    }

    // MARK: - Sanitization

    @Test func sanitizationNormalizesUsableResponses() {
        #expect(engine.sanitizeResponse("Fix auth bug\nextra line", currentTitle: nil) == "Fix auth bug")
        #expect(engine.sanitizeResponse("\n\n  \"Debug login flow\"  \n", currentTitle: nil) == "Debug login flow")
        #expect(engine.sanitizeResponse("Multi   space    title", currentTitle: nil) == "Multi space title")
        #expect(engine.sanitizeResponse("\u{201C}Fix auth bug\u{201D}", currentTitle: nil) == "Fix auth bug")
        #expect(engine.sanitizeResponse("'Fix auth bug'", currentTitle: nil) == "Fix auth bug")
    }

    @Test func sanitizationTruncatesUnbrokenStringsAtHardCap() {
        let unbroken = String(repeating: "x", count: config.maxTitleLength + 10)
        let sanitized = engine.sanitizeResponse(unbroken, currentTitle: nil)
        #expect(sanitized == String(repeating: "x", count: config.maxTitleLength))
    }

    @Test func sanitizationRejectsGarbage() {
        #expect(engine.sanitizeResponse(nil, currentTitle: nil) == nil)
        #expect(engine.sanitizeResponse("", currentTitle: nil) == nil)
        #expect(engine.sanitizeResponse("   \n  \n", currentTitle: nil) == nil)
        #expect(engine.sanitizeResponse("\"\"", currentTitle: nil) == nil)
    }

    @Test func sanitizationEnforcesLengthCapAtWordBoundary() throws {
        let long = "Investigating the extremely convoluted authentication subsystem regression"
        let sanitized = try #require(engine.sanitizeResponse(long, currentTitle: nil))
        #expect(sanitized.count <= config.maxTitleLength)
        #expect(!sanitized.hasSuffix(" "))
        // Cut on a word boundary, not mid-word.
        #expect(long.hasPrefix(sanitized))
        let nextIndex = long.index(long.startIndex, offsetBy: sanitized.count)
        #expect(long[nextIndex] == " ")
    }

    @Test func identicalTitleIsNoOp() {
        #expect(engine.sanitizeResponse("Fix auth bug", currentTitle: "Fix auth bug") == nil)
        #expect(engine.sanitizeResponse("Fix auth bug", currentTitle: "Other title") == "Fix auth bug")
    }

    // MARK: - Environment policy

    @Test func summarizerEnvironmentScrubsRecursionVarsAndPreservesBackend() {
        let policy = AutoNamingEnvironmentPolicy()
        let env = policy.summarizerEnvironment(from: [
            "CMUX_WORKSPACE_ID": "ws",
            "CMUX_SURFACE_ID": "sf",
            "CLAUDECODE": "1",
            "CLAUDE_CODE": "1",
            "CLAUDE_CODE_CHILD_SESSION": "child",
            "CLAUDE_CODE_ENTRYPOINT": "cli",
            "CLAUDE_CODE_PARENT_SESSION_ID": "parent",
            "CLAUDE_CODE_SESSION_ID": "abc",
            "NODE_OPTIONS": "--require /tmp/guard.js",
            "CLAUDE_CODE_EXECPATH": "/usr/local/bin/claude",
            "CLAUDE_CODE_SSE_PORT": "12345",
            "CLAUDE_CODE_USE_VERTEX": "1",
            "CLAUDE_CODE_USE_BEDROCK": "0",
            "ANTHROPIC_API_KEY": "key",
            "ANTHROPIC_MODEL": "custom",
            "PATH": "/usr/bin",
            "HOME": "/Users/dev"
        ])
        #expect(env["CMUX_WORKSPACE_ID"] == nil)
        #expect(env["CMUX_SURFACE_ID"] == nil)
        #expect(env["CLAUDECODE"] == nil)
        #expect(env["CLAUDE_CODE"] == nil)
        #expect(env["CLAUDE_CODE_CHILD_SESSION"] == nil)
        #expect(env["CLAUDE_CODE_ENTRYPOINT"] == nil)
        #expect(env["CLAUDE_CODE_PARENT_SESSION_ID"] == nil)
        #expect(env["CLAUDE_CODE_SESSION_ID"] == nil)
        #expect(env["NODE_OPTIONS"] == nil)
        #expect(env["CLAUDE_CODE_EXECPATH"] == nil)
        #expect(env["CLAUDE_CODE_SSE_PORT"] == nil)
        #expect(env["CLAUDE_CODE_USE_VERTEX"] == "1")
        #expect(env["CLAUDE_CODE_USE_BEDROCK"] == "0")
        #expect(env["ANTHROPIC_API_KEY"] == "key")
        #expect(env["ANTHROPIC_MODEL"] == "custom")
        #expect(env["PATH"] == "/usr/bin")
        #expect(env["HOME"] == "/Users/dev")
    }

    @Test func codexSummarizerEnvironmentKeepsAuthDiscoveryButDropsOtherProviderCredentials() {
        let policy = AutoNamingEnvironmentPolicy()
        let env = policy.codexSummarizerEnvironment(from: [
            "CMUX_WORKSPACE_ID": "ws",
            "ANTHROPIC_API_KEY": "anthropic",
            "AWS_SECRET_ACCESS_KEY": "aws",
            "GOOGLE_APPLICATION_CREDENTIALS": "/tmp/gcp.json",
            "OPENAI_API_KEY": "openai",
            "OPENAI_BASE_URL": "https://api.openai.com/v1",
            "CODEX_HOME": "/Users/dev/.codex",
            "PATH": "/usr/bin",
            "HOME": "/Users/dev"
        ])

        #expect(env["CMUX_WORKSPACE_ID"] == nil)
        #expect(env["ANTHROPIC_API_KEY"] == nil)
        #expect(env["AWS_SECRET_ACCESS_KEY"] == nil)
        #expect(env["GOOGLE_APPLICATION_CREDENTIALS"] == nil)
        #expect(env["OPENAI_API_KEY"] == "openai")
        #expect(env["OPENAI_BASE_URL"] == "https://api.openai.com/v1")
        #expect(env["CODEX_HOME"] == "/Users/dev/.codex")
        #expect(env["PATH"] == "/usr/bin")
        #expect(env["HOME"] == "/Users/dev")
    }

    @Test func modelHonorsSmallFastOverride() {
        let policy = AutoNamingEnvironmentPolicy()
        #expect(policy.claudeModel(from: [:]) == "haiku")
        #expect(policy.claudeModel(from: ["ANTHROPIC_SMALL_FAST_MODEL": "  "]) == "haiku")
        #expect(policy.claudeModel(from: ["ANTHROPIC_SMALL_FAST_MODEL": "vertex-haiku-id"]) == "vertex-haiku-id")
    }
}
