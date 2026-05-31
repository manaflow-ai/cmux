import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Unit tests for the boundary-aware ranking layer (issue #5033).
@Suite struct CommandPaletteRankingContextTests {
    private func context(token: String, candidate: String) -> CommandPaletteRankingContext {
        let prepared = CommandPaletteFuzzyMatcher.prepareNormalizedCandidateText(candidate)!
        return CommandPaletteRankingContext(
            tokenChars: Array(token),
            candidateChars: prepared.characters,
            segments: prepared.wordSegments
        )
    }

    @Test func matchesMidWordAbbreviationAcrossWordBoundaries() {
        let features = context(token: "tgsb", candidate: "toggle sidebar").scoredFeatures()
        let unwrapped = try! #require(features)
        // t(0) g(2) s(7) b(11) — "t" and "s" start words.
        #expect(unwrapped.matchedIndices == [0, 2, 7, 11])
        #expect(unwrapped.boundaryHits == 2)
        #expect(context(token: "tgsb", candidate: "toggle sidebar").score() != nil)
    }

    @Test func rejectsGappyMatchWithoutTwoWordBoundaries() {
        // "abcd" is a subsequence of "axbxcxd" but only the leading "a" is a
        // word boundary, so the gap-penalty gate rejects it for length ≥ 4.
        let ctx = context(token: "abcd", candidate: "axbxcxd")
        #expect(ctx.boundaryAwareSubsequence() != nil)
        #expect(ctx.scoredFeatures() == nil)
        #expect(ctx.score() == nil)
    }

    @Test func shortTokensSkipTheTwoBoundaryGate() {
        // Length ≤ 3 is handled by the legacy subsequence path; the gate only
        // applies to length ≥ 4, so a short gappy match still scores.
        let ctx = context(token: "ab", candidate: "xaxb")
        #expect(ctx.scoredFeatures() != nil)
        #expect((ctx.score() ?? 0) > 0)
    }

    @Test func returnsNilWhenTokenIsNotASubsequence() {
        #expect(context(token: "zzzz", candidate: "toggle sidebar").score() == nil)
    }

    @Test func wordBoundaryHitsRaiseTheScore() {
        let boundaryRich = CommandPaletteRankingContext.Features(
            matchedIndices: [0, 7],
            boundaryHits: 2,
            gapTotal: 6,
            longestRun: 1,
            leadingBoundary: true
        )
        let boundaryPoor = CommandPaletteRankingContext.Features(
            matchedIndices: [1, 7],
            boundaryHits: 0,
            gapTotal: 5,
            longestRun: 1,
            leadingBoundary: false
        )
        let rich = CommandPaletteRankingContext.score(features: boundaryRich, tokenLength: 2, candidateLength: 14)
        let poor = CommandPaletteRankingContext.score(features: boundaryPoor, tokenLength: 2, candidateLength: 14)
        #expect(rich > poor)
    }
}
