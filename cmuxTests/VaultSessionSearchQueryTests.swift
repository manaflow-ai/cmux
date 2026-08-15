import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private func makeEntry(
    id: String = "claude:/tmp/a.jsonl",
    agent: SessionAgent = .claude,
    title: String = "Fix the flaky test",
    cwd: String? = "/Users/dev/projects/cmux",
    branch: String? = "issue-1-fix",
    modified: Date = Date(timeIntervalSince1970: 1_755_000_000)
) -> SessionEntry {
    SessionEntry(
        id: id,
        agent: agent,
        sessionId: id,
        title: title,
        cwd: cwd,
        gitBranch: branch,
        pullRequest: nil,
        modified: modified,
        fileURL: nil,
        specifics: .claude(model: nil, permissionMode: nil, configDirectoryForResume: nil)
    )
}

@Suite
struct VaultSessionSearchQueryTests {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test
    func parsesFreeTextAndOperators() {
        let query = VaultSessionSearchQuery.parse("agent:claude repo:cmux ws:projects fix bug")
        #expect(query.agentTerms == ["claude"])
        #expect(query.repoTerms == ["cmux"])
        #expect(query.workspaceTerms == ["projects"])
        #expect(query.textTerms == ["fix", "bug"])
        #expect(query.residualText == "fix bug")
    }

    @Test
    func parsesQuotedPhrasesIncludingOperatorValues() {
        let query = VaultSessionSearchQuery.parse(#""multi word phrase" repo:"my project""#)
        #expect(query.textTerms == ["multi word phrase"])
        #expect(query.repoTerms == ["my project"])
    }

    @Test
    func invalidDateFallsBackToFreeText() {
        let query = VaultSessionSearchQuery.parse("before:notadate after:2026-13-99")
        #expect(query.before == nil)
        #expect(query.after == nil)
        #expect(query.textTerms == ["before:notadate", "after:2026-13-99"])
    }

    @Test
    func beforeAndAfterUseStartOfDaySemantics() {
        let calendar = utcCalendar
        let query = VaultSessionSearchQuery.parse("after:2026-08-01 before:2026-08-10", calendar: calendar)
        let expectedAfter = calendar.date(from: DateComponents(year: 2026, month: 8, day: 1))!
        let expectedBefore = calendar.date(from: DateComponents(year: 2026, month: 8, day: 10))!
        #expect(query.after == expectedAfter)
        #expect(query.before == expectedBefore)

        // modified exactly at the after boundary is included; at the before
        // boundary it is excluded.
        let atAfter = makeEntry(modified: expectedAfter)
        let atBefore = makeEntry(modified: expectedBefore)
        #expect(query.matchesOperators(atAfter))
        #expect(!query.matchesOperators(atBefore))
    }

    @Test
    func unknownOperatorPrefixStaysFreeText() {
        let query = VaultSessionSearchQuery.parse("foo:bar")
        #expect(query.textTerms == ["foo:bar"])
        #expect(query.agentTerms.isEmpty)
    }

    @Test
    func agentOperatorMatchesRawValueAndDisplayNameCaseInsensitively() {
        let query = VaultSessionSearchQuery.parse("agent:Claude")
        #expect(query.matchesOperators(makeEntry(agent: .claude)))
        #expect(!query.matchesOperators(makeEntry(agent: .codex)))

        // Multiple agent: values OR together.
        let multi = VaultSessionSearchQuery.parse("agent:claude agent:codex")
        #expect(multi.matchesOperators(makeEntry(agent: .claude)))
        #expect(multi.matchesOperators(makeEntry(agent: .codex)))
        #expect(!multi.matchesOperators(makeEntry(agent: .opencode)))
    }

    @Test
    func repoMatchesCwdBasenameOnly() {
        let query = VaultSessionSearchQuery.parse("repo:cmux")
        #expect(query.matchesOperators(makeEntry(cwd: "/Users/dev/projects/cmux121")))
        #expect(!query.matchesOperators(makeEntry(cwd: "/Users/dev/cmux-stuff/other")))
    }

    @Test
    func workspaceMatchesFullCwd() {
        let query = VaultSessionSearchQuery.parse("ws:dev")
        #expect(query.matchesOperators(makeEntry(cwd: "/Users/dev/projects/cmux")))
        #expect(!query.matchesOperators(makeEntry(cwd: "/opt/elsewhere")))
    }

    @Test
    func metadataMatchRequiresEveryTextTerm() {
        let query = VaultSessionSearchQuery.parse("flaky test")
        #expect(query.matchesMetadata(makeEntry(title: "Fix the flaky test")))
        #expect(!query.matchesMetadata(makeEntry(title: "Fix the slow build")))
        // Branch and cwd count as metadata haystack.
        let branchHit = VaultSessionSearchQuery.parse("issue-1")
        #expect(branchHit.matchesMetadata(makeEntry(title: "unrelated")))
    }

    @Test
    func emptyQueryIsEmpty() {
        #expect(VaultSessionSearchQuery.parse("   ").isEmpty)
        #expect(!VaultSessionSearchQuery.parse("agent:claude").isEmpty)
    }
}

@Suite
struct VaultSessionSearchRankingTests {
    @Test
    func ranksByRecencyFirst() {
        let old = makeEntry(id: "a", modified: Date(timeIntervalSince1970: 100))
        let new = makeEntry(id: "b", modified: Date(timeIntervalSince1970: 200))
        let query = VaultSessionSearchQuery.parse("fix")
        let ranked = VaultSessionSearchRanking.rank([old, new], query: query)
        #expect(ranked.map(\.id) == ["b", "a"])
    }

    @Test
    func titleMatchBreaksRecencyTies() {
        let sameDate = Date(timeIntervalSince1970: 500)
        let transcriptHit = makeEntry(id: "a", title: "unrelated title", modified: sameDate)
        let titleHit = makeEntry(id: "b", title: "fix crash", modified: sameDate)
        let query = VaultSessionSearchQuery.parse("fix")
        let ranked = VaultSessionSearchRanking.rank([transcriptHit, titleHit], query: query)
        #expect(ranked.map(\.id) == ["b", "a"])
    }

    @Test
    func dedupesByIdKeepingFirstOccurrence() {
        let first = makeEntry(id: "a", title: "metadata copy")
        let duplicate = makeEntry(id: "a", title: "transcript copy")
        let ranked = VaultSessionSearchRanking.rank(
            [first, duplicate],
            query: VaultSessionSearchQuery.parse("copy")
        )
        #expect(ranked.count == 1)
        #expect(ranked[0].title == "metadata copy")
    }

    @Test
    func deterministicFinalTieBreakOnId() {
        let sameDate = Date(timeIntervalSince1970: 500)
        let a = makeEntry(id: "a", title: "same", modified: sameDate)
        let b = makeEntry(id: "b", title: "same", modified: sameDate)
        let ranked = VaultSessionSearchRanking.rank([b, a], query: VaultSessionSearchQuery.parse("same"))
        #expect(ranked.map(\.id) == ["a", "b"])
    }
}
