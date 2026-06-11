import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class AgentUsageModelTests: XCTestCase {

    // MARK: - Claude Code transcript parsing

    private func claudeLine(
        messageId: String = "msg_1",
        requestId: String = "req_1",
        model: String = "claude-sonnet-4-20250514",
        input: Int = 10,
        output: Int = 200,
        cacheRead: Int = 4_000,
        cacheWrite: Int = 300,
        costUSD: Double? = nil,
        timestamp: String = "2026-06-10T12:34:56.789Z"
    ) -> String {
        let cost = costUSD.map { ",\"costUSD\":\($0)" } ?? ""
        return """
        {"timestamp":"\(timestamp)","type":"assistant","requestId":"\(requestId)"\(cost),"message":{"id":"\(messageId)","model":"\(model)","usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":\(cacheRead),"cache_creation_input_tokens":\(cacheWrite)}}}
        """
    }

    func testParseClaudeLineExtractsTokensModelAndTimestamp() throws {
        var seen: Set<String> = []
        let event = try XCTUnwrap(AgentUsageLogParser.parseClaudeLine(claudeLine(), seenRequestKeys: &seen))

        XCTAssertEqual(event.source, .claudeCode)
        XCTAssertEqual(event.model, "claude-sonnet-4-20250514")
        XCTAssertEqual(event.tokens.input, 10)
        XCTAssertEqual(event.tokens.output, 200)
        XCTAssertEqual(event.tokens.cacheRead, 4_000)
        XCTAssertEqual(event.tokens.cacheWrite, 300)
        XCTAssertEqual(event.tokens.total, 4_510)
        XCTAssertNil(event.recordedCostUSD)

        let expected = try XCTUnwrap(AgentUsageLogParser.parseTimestamp("2026-06-10T12:34:56.789Z"))
        XCTAssertEqual(event.timestamp, expected)
    }

    func testParseClaudeLineDeduplicatesRepeatedRequests() {
        var seen: Set<String> = []
        XCTAssertNotNil(AgentUsageLogParser.parseClaudeLine(claudeLine(), seenRequestKeys: &seen))
        XCTAssertNil(
            AgentUsageLogParser.parseClaudeLine(claudeLine(), seenRequestKeys: &seen),
            "Replaying the same messageId/requestId pair must not double-count"
        )
        XCTAssertNotNil(
            AgentUsageLogParser.parseClaudeLine(claudeLine(messageId: "msg_2", requestId: "req_2"), seenRequestKeys: &seen)
        )
    }

    func testParseClaudeLineSkipsSyntheticAndNonUsageLines() {
        var seen: Set<String> = []
        XCTAssertNil(AgentUsageLogParser.parseClaudeLine(claudeLine(model: "<synthetic>"), seenRequestKeys: &seen))
        XCTAssertNil(AgentUsageLogParser.parseClaudeLine("{\"type\":\"user\",\"message\":{\"role\":\"user\"}}", seenRequestKeys: &seen))
        XCTAssertNil(AgentUsageLogParser.parseClaudeLine("not json", seenRequestKeys: &seen))
        XCTAssertNil(
            AgentUsageLogParser.parseClaudeLine(
                claudeLine(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
                seenRequestKeys: &seen
            ),
            "Zero-token usage entries carry no usage signal"
        )
    }

    func testParseClaudeLinePrefersRecordedCost() throws {
        var seen: Set<String> = []
        let event = try XCTUnwrap(
            AgentUsageLogParser.parseClaudeLine(claudeLine(costUSD: 0.42), seenRequestKeys: &seen)
        )
        XCTAssertEqual(event.recordedCostUSD, 0.42)
        XCTAssertEqual(AgentUsagePricing.estimatedCost(for: event), 0.42)
    }

    // MARK: - Codex rollout parsing

    func testParseCodexSessionUsesLastTokenUsagePerEvent() throws {
        let lines = [
            #"{"timestamp":"2026-06-10T08:00:00.000Z","type":"turn_context","payload":{"model":"gpt-5-codex"}}"#,
            #"{"timestamp":"2026-06-10T08:00:10.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":50,"total_tokens":1050},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":50,"total_tokens":1050}}}}"#,
            #"{"timestamp":"2026-06-10T08:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1500,"cached_input_tokens":700,"output_tokens":80,"total_tokens":1580},"last_token_usage":{"input_tokens":500,"cached_input_tokens":300,"output_tokens":30,"total_tokens":530}}}}"#,
        ]
        let events = AgentUsageLogParser.parseCodexSession(lines: lines)

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].source, .codex)
        XCTAssertEqual(events[0].model, "gpt-5-codex")
        XCTAssertEqual(events[0].tokens.input, 600, "Cached input tokens split out of raw input")
        XCTAssertEqual(events[0].tokens.cacheRead, 400)
        XCTAssertEqual(events[0].tokens.output, 50)
        XCTAssertEqual(events[1].tokens.input, 200)
        XCTAssertEqual(events[1].tokens.cacheRead, 300)
        XCTAssertEqual(events[1].tokens.output, 30)
    }

    func testParseCodexSessionFallsBackToTotalDeltas() {
        let lines = [
            #"{"timestamp":"2026-06-10T08:00:10.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":50,"total_tokens":1050}}}}"#,
            #"{"timestamp":"2026-06-10T08:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1600,"cached_input_tokens":0,"output_tokens":90,"total_tokens":1690}}}}"#,
        ]
        let events = AgentUsageLogParser.parseCodexSession(lines: lines)

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].model, "codex", "Model defaults when no turn_context precedes the event")
        XCTAssertEqual(events[0].tokens.input, 1000)
        XCTAssertEqual(events[0].tokens.output, 50)
        XCTAssertEqual(events[1].tokens.input, 600, "Second event counts only the cumulative delta")
        XCTAssertEqual(events[1].tokens.output, 40)
    }

    // MARK: - Pricing

    func testPricingMatchesKnownModelFamiliesAndRejectsUnknown() {
        XCTAssertNotNil(AgentUsagePricing.pricing(forModel: "claude-opus-4-8"))
        XCTAssertNotNil(AgentUsagePricing.pricing(forModel: "claude-sonnet-4-20250514"))
        XCTAssertNotNil(AgentUsagePricing.pricing(forModel: "claude-haiku-4-5-20251001"))
        XCTAssertNotNil(AgentUsagePricing.pricing(forModel: "gpt-5-codex"))
        XCTAssertNil(AgentUsagePricing.pricing(forModel: "some-unknown-model"))
    }

    func testPricingCostComputation() {
        let pricing = AgentUsagePricing(inputPerMTok: 3, outputPerMTok: 15, cacheReadPerMTok: 0.3, cacheWritePerMTok: 3.75)
        let tokens = AgentUsageTokens(input: 1_000_000, output: 200_000, cacheRead: 500_000, cacheWrite: 100_000)
        // 3 + 3 + 0.15 + 0.375
        XCTAssertEqual(pricing.cost(for: tokens), 6.525, accuracy: 0.0001)
    }

    // MARK: - Aggregation

    func testAggregateGroupsByDayAndModelAndDropsOldEvents() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(AgentUsageLogParser.parseTimestamp("2026-06-11T12:00:00Z"))

        func event(_ timestamp: String, source: AgentUsageSource, model: String, output: Int) throws -> AgentUsageEvent {
            AgentUsageEvent(
                source: source,
                timestamp: try XCTUnwrap(AgentUsageLogParser.parseTimestamp(timestamp)),
                model: model,
                tokens: AgentUsageTokens(input: 100, output: output, cacheRead: 0, cacheWrite: 0),
                recordedCostUSD: nil
            )
        }

        let events = [
            try event("2026-06-11T09:00:00Z", source: .claudeCode, model: "claude-sonnet-4", output: 100),
            try event("2026-06-11T10:00:00Z", source: .claudeCode, model: "claude-sonnet-4", output: 200),
            try event("2026-06-11T11:00:00Z", source: .codex, model: "gpt-5-codex", output: 50),
            try event("2026-06-10T11:00:00Z", source: .claudeCode, model: "claude-opus-4-8", output: 400),
            try event("2025-01-01T00:00:00Z", source: .claudeCode, model: "claude-sonnet-4", output: 999_999),
        ]

        let snapshot = AgentUsageAggregator.aggregate(events: events, calendar: calendar, now: now, windowDays: 30)

        XCTAssertEqual(snapshot.days.count, 2)
        XCTAssertEqual(snapshot.sourcesFound, [.claudeCode, .codex])

        let newestDay = snapshot.days[0]
        XCTAssertTrue(newestDay.day > snapshot.days[1].day, "Days are sorted newest first")
        XCTAssertEqual(newestDay.tokens.input, 300)
        XCTAssertEqual(newestDay.tokens.output, 350)
        XCTAssertEqual(newestDay.models.count, 2)

        XCTAssertEqual(snapshot.totals.input, 400, "Event outside the 30-day window must be dropped")
        XCTAssertEqual(snapshot.totals.output, 750)

        let modelIds = Set(snapshot.modelTotals.map(\.id))
        XCTAssertEqual(modelIds, [
            "claudeCode|claude-sonnet-4",
            "claudeCode|claude-opus-4-8",
            "codex|gpt-5-codex",
        ])
        XCTAssertNotNil(snapshot.totalCostUSD)
    }

    func testAggregateLeavesCostNilForUnknownModels() throws {
        let now = try XCTUnwrap(AgentUsageLogParser.parseTimestamp("2026-06-11T12:00:00Z"))
        let events = [
            AgentUsageEvent(
                source: .codex,
                timestamp: now,
                model: "mystery-model",
                tokens: AgentUsageTokens(input: 100, output: 100, cacheRead: 0, cacheWrite: 0),
                recordedCostUSD: nil
            )
        ]
        let snapshot = AgentUsageAggregator.aggregate(events: events, now: now, windowDays: 30)
        XCTAssertNil(snapshot.totalCostUSD)
        XCTAssertEqual(snapshot.totals.total, 200)
    }
}
