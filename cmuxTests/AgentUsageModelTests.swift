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
        let events = AgentUsageLogParser.parseCodexSession(lines: lines).events

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
        let events = AgentUsageLogParser.parseCodexSession(lines: lines).events

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].model, "codex", "Model defaults when no turn_context precedes the event")
        XCTAssertEqual(events[0].tokens.input, 1000)
        XCTAssertEqual(events[0].tokens.output, 50)
        XCTAssertEqual(events[1].tokens.input, 600, "Second event counts only the cumulative delta")
        XCTAssertEqual(events[1].tokens.output, 40)
    }

    func testParseCodexSessionCountsFullTotalAfterCounterReset() {
        let lines = [
            #"{"timestamp":"2026-06-10T08:00:10.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":50,"total_tokens":1050}}}}"#,
            #"{"timestamp":"2026-06-10T08:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":300,"cached_input_tokens":0,"output_tokens":20,"total_tokens":320}}}}"#,
        ]
        let events = AgentUsageLogParser.parseCodexSession(lines: lines).events

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[1].tokens.input, 300, "A cumulative counter reset must count the new total, not clamp to zero")
        XCTAssertEqual(events[1].tokens.output, 20)
    }

    func testParseCodexSessionExtractsLatestRateLimits() throws {
        let lines = [
            #"{"timestamp":"2026-06-10T08:00:10.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":10,"total_tokens":110}},"rate_limits":{"primary":{"used_percent":12.5,"window_minutes":300,"resets_in_seconds":14400},"secondary":{"used_percent":3.0,"window_minutes":10080,"resets_in_seconds":500000}}}}"#,
            #"{"timestamp":"2026-06-10T09:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":200,"cached_input_tokens":0,"output_tokens":20,"total_tokens":220}},"rate_limits":{"primary":{"used_percent":31.0,"window_minutes":300,"resets_in_seconds":10800},"secondary":{"used_percent":4.5,"window_minutes":10080,"resets_in_seconds":496400}}}}"#,
        ]
        let observation = try XCTUnwrap(AgentUsageLogParser.parseCodexSession(lines: lines).rateLimits)

        XCTAssertEqual(observation.observedAt, AgentUsageLogParser.parseTimestamp("2026-06-10T09:00:00.000Z"))
        XCTAssertEqual(observation.primary?.usedPercent, 31.0)
        XCTAssertEqual(observation.primary?.windowMinutes, 300)
        XCTAssertEqual(observation.primary?.resetsInSeconds, 10800)
        XCTAssertEqual(observation.secondary?.usedPercent, 4.5)
    }

    // MARK: - OpenCode message parsing

    func testParseOpenCodeMessageFoldsReasoningAndMapsCache() throws {
        let json = #"""
        {"role":"assistant","modelID":"claude-sonnet-4-20250514","providerID":"anthropic","cost":0,"time":{"created":1749560096000,"completed":1749560100000},"tokens":{"input":10,"output":200,"reasoning":20,"cache":{"read":4000,"write":300}}}
        """#
        let event = try XCTUnwrap(AgentUsageLogParser.parseOpenCodeMessage(json))

        XCTAssertEqual(event.source, .openCode)
        XCTAssertEqual(event.model, "claude-sonnet-4-20250514")
        XCTAssertEqual(event.tokens.input, 10)
        XCTAssertEqual(event.tokens.output, 220, "Reasoning tokens fold into output")
        XCTAssertEqual(event.tokens.cacheRead, 4000)
        XCTAssertEqual(event.tokens.cacheWrite, 300)
        XCTAssertNil(event.recordedCostUSD, "A cost of 0 is treated as unpriced so it gets estimated")
        XCTAssertEqual(event.timestamp, Date(timeIntervalSince1970: 1_749_560_100), "time.completed is epoch milliseconds")
    }

    func testParseOpenCodeMessageSkipsNonAssistantAndEmptyUsage() {
        XCTAssertNil(
            AgentUsageLogParser.parseOpenCodeMessage(#"{"role":"user","tokens":{"input":5}}"#),
            "Only assistant messages carry billable usage"
        )
        XCTAssertNil(
            AgentUsageLogParser.parseOpenCodeMessage(#"{"role":"assistant","time":{"completed":1749560100000},"tokens":{"input":0,"output":0,"cache":{"read":0,"write":0}}}"#),
            "Zero-token assistant messages carry no usage"
        )
        XCTAssertNil(AgentUsageLogParser.parseOpenCodeMessage("not json"))
    }

    func testParseOpenCodeMessagePrefersPositiveRecordedCost() throws {
        let json = #"""
        {"role":"assistant","modelID":"some-local-model","cost":0.0731,"time":{"completed":1749560100000},"tokens":{"input":100,"output":50,"cache":{"read":0,"write":0}}}
        """#
        let event = try XCTUnwrap(AgentUsageLogParser.parseOpenCodeMessage(json))
        XCTAssertEqual(event.recordedCostUSD, 0.0731)
    }

    // MARK: - OpenRouter activity mapping

    func testOpenRouterActivityMapsToEvents() throws {
        let json = Data(#"""
        {"data":[
          {"date":"2026-06-10","model":"openai/gpt-4.1","model_permaslug":"openai/gpt-4.1@2025","endpoint_id":"ep","provider_name":"OpenAI","prompt_tokens":1000,"completion_tokens":200,"reasoning_tokens":50,"requests":5,"usage":0.1234,"byok_usage_inference":0},
          {"date":"bad-date","model":"x","model_permaslug":"x","endpoint_id":"ep","provider_name":"p","prompt_tokens":1,"completion_tokens":1,"reasoning_tokens":0,"requests":1,"usage":0.01,"byok_usage_inference":0}
        ]}
        """#.utf8)

        let events = OpenRouterUsageClient.events(fromActivityJSON: json)
        XCTAssertEqual(events.count, 1, "Rows with an unparseable date are dropped")

        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.source, .openRouter)
        XCTAssertEqual(event.model, "openai/gpt-4.1")
        XCTAssertEqual(event.tokens.input, 1000)
        XCTAssertEqual(event.tokens.output, 250, "Reasoning tokens fold into output")
        XCTAssertEqual(event.recordedCostUSD, 0.1234, "OpenRouter's reported usage cost is authoritative")

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        XCTAssertEqual(utc.component(.year, from: event.timestamp), 2026)
        XCTAssertEqual(utc.component(.month, from: event.timestamp), 6)
        XCTAssertEqual(utc.component(.day, from: event.timestamp), 10)
    }

    // MARK: - Rate windows

    private func usageEvent(
        _ timestamp: String,
        source: AgentUsageSource = .claudeCode,
        model: String = "claude-sonnet-4",
        input: Int = 100,
        output: Int = 50
    ) throws -> AgentUsageEvent {
        AgentUsageEvent(
            source: source,
            timestamp: try XCTUnwrap(AgentUsageLogParser.parseTimestamp(timestamp)),
            model: model,
            tokens: AgentUsageTokens(input: input, output: output, cacheRead: 0, cacheWrite: 0),
            recordedCostUSD: nil
        )
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testCurrentFiveHourWindowFloorsStartToHourAndSumsBlockEvents() throws {
        let now = try XCTUnwrap(AgentUsageLogParser.parseTimestamp("2026-06-11T13:00:00Z"))
        let events = [
            try usageEvent("2026-06-11T09:05:00Z"),
            try usageEvent("2026-06-11T10:30:00Z"),
        ]
        let window = try XCTUnwrap(
            AgentUsageAggregator.currentFiveHourWindow(events: events, source: .claudeCode, calendar: utcCalendar, now: now)
        )

        XCTAssertEqual(window.windowStart, AgentUsageLogParser.parseTimestamp("2026-06-11T09:00:00Z"))
        XCTAssertEqual(window.windowEnd, AgentUsageLogParser.parseTimestamp("2026-06-11T14:00:00Z"))
        XCTAssertEqual(window.tokens.input, 200)
        XCTAssertEqual(window.tokens.output, 100)
        XCTAssertFalse(window.isProviderReported)
        XCTAssertNil(window.usedPercent)
    }

    func testCurrentFiveHourWindowExpiresAndRestartsOnLaterEvent() throws {
        let events = [
            try usageEvent("2026-06-11T09:05:00Z"),
            try usageEvent("2026-06-11T15:30:00Z"),
        ]

        let betweenBlocks = try XCTUnwrap(AgentUsageLogParser.parseTimestamp("2026-06-11T14:30:00Z"))
        XCTAssertNil(
            AgentUsageAggregator.currentFiveHourWindow(
                events: [events[0]], source: .claudeCode, calendar: utcCalendar, now: betweenBlocks
            ),
            "No window is active once the 5-hour block has elapsed"
        )

        let inSecondBlock = try XCTUnwrap(AgentUsageLogParser.parseTimestamp("2026-06-11T16:00:00Z"))
        let window = try XCTUnwrap(
            AgentUsageAggregator.currentFiveHourWindow(events: events, source: .claudeCode, calendar: utcCalendar, now: inSecondBlock)
        )
        XCTAssertEqual(window.windowStart, AgentUsageLogParser.parseTimestamp("2026-06-11T15:00:00Z"))
        XCTAssertEqual(window.tokens.input, 100, "Second block only counts its own events")
    }

    func testRateWindowsOverlayCodexReportedPercentAndDropStaleResets() throws {
        let now = try XCTUnwrap(AgentUsageLogParser.parseTimestamp("2026-06-11T12:00:00Z"))
        let events = [
            try usageEvent("2026-06-11T11:00:00Z", source: .codex, model: "gpt-5-codex"),
            try usageEvent("2026-06-09T11:00:00Z", source: .codex, model: "gpt-5-codex"),
        ]
        let observation = CodexRateLimitsObservation(
            observedAt: try XCTUnwrap(AgentUsageLogParser.parseTimestamp("2026-06-11T11:30:00Z")),
            primary: CodexRateLimitWindow(usedPercent: 42, windowMinutes: 300, resetsInSeconds: 7200),
            secondary: CodexRateLimitWindow(usedPercent: 9, windowMinutes: 10080, resetsInSeconds: 60)
        )

        let windows = AgentUsageAggregator.rateWindows(
            events: events, codexRateLimits: observation, calendar: utcCalendar, now: now
        )
        let fiveHour = try XCTUnwrap(windows.first { $0.source == .codex && $0.kind == .fiveHour })
        XCTAssertEqual(fiveHour.usedPercent, 42)
        XCTAssertTrue(fiveHour.isProviderReported)
        XCTAssertEqual(fiveHour.windowEnd, AgentUsageLogParser.parseTimestamp("2026-06-11T13:30:00Z"))

        let weekly = try XCTUnwrap(windows.first { $0.source == .codex && $0.kind == .weekly })
        XCTAssertNil(
            weekly.usedPercent,
            "A reset that elapsed before now means the reported percent is stale and must not be shown"
        )
        XCTAssertFalse(weekly.isProviderReported)
        XCTAssertEqual(weekly.tokens.input, 200, "Rolling 7-day window still sums local events")
    }

    func testRollingWeeklyWindowSumsOnlyLastSevenDays() throws {
        let now = try XCTUnwrap(AgentUsageLogParser.parseTimestamp("2026-06-11T12:00:00Z"))
        let events = [
            try usageEvent("2026-06-10T12:00:00Z"),
            try usageEvent("2026-06-05T12:00:00Z"),
            try usageEvent("2026-06-01T12:00:00Z"),
        ]
        let window = try XCTUnwrap(
            AgentUsageAggregator.rollingWeeklyWindow(events: events, source: .claudeCode, now: now)
        )
        XCTAssertEqual(window.tokens.input, 200, "Event older than 7 days is excluded")
        XCTAssertEqual(window.kind, .weekly)
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

    // MARK: - No installed tools

    func testScannerWithNoInstalledToolsProducesEmptySnapshot() throws {
        // A home directory where none of Claude Code, Codex, or OpenCode have
        // written anything: the scanner must find nothing and never throw.
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentusage-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let scanner = AgentUsageScanner(homeDirectory: tempHome)
        let raw = scanner.collectLocalUsage()
        XCTAssertTrue(raw.events.isEmpty, "Missing tool directories must yield no events")
        XCTAssertEqual(raw.scannedFileCount, 0)
        XCTAssertNil(raw.codexRateLimits)

        let snapshot = AgentUsageAggregator.aggregate(
            events: raw.events,
            codexRateLimits: raw.codexRateLimits,
            scannedFileCount: raw.scannedFileCount
        )
        XCTAssertTrue(snapshot.days.isEmpty)
        XCTAssertTrue(snapshot.modelTotals.isEmpty)
        XCTAssertEqual(snapshot.totals.total, 0)
        XCTAssertNil(snapshot.totalCostUSD)
        XCTAssertTrue(snapshot.rateWindows.isEmpty)
        XCTAssertTrue(snapshot.sourcesFound.isEmpty)
        XCTAssertNil(snapshot.openRouterCredits, "No OpenRouter key means no balance")
    }
}
