@testable import CmuxiOSSearchCore
import Testing

@Suite("SearchMatcher")
struct SearchMatcherTests {
    let matcher = SearchMatcher()

    func match(_ query: String, _ text: String, fuzzy: Bool = true) -> SearchMatch? {
        matcher.match(SearchText(query), in: SearchText(text), fuzzy: fuzzy)
    }

    @Test func exactBeatsPrefix() throws {
        let exact = try #require(match("deploy", "Deploy"))
        let prefix = try #require(match("deploy", "deploy api"))
        #expect(exact.tier == .exact)
        #expect(exact.score == 1000)
        #expect(prefix.tier == .prefix)
        #expect(exact.score > prefix.score)
    }

    @Test func prefixPrefersShorterField() throws {
        let short = try #require(match("dep", "deploy"))
        let long = try #require(match("dep", "deployment pipeline"))
        #expect(short.tier == .prefix && long.tier == .prefix)
        #expect(short.score > long.score)
    }

    @Test func wordStartTier() throws {
        let result = try #require(match("dep", "api deploy"))
        #expect(result.tier == .wordStart)
        #expect(result.ranges == [4..<7])
    }

    @Test func wordStartsAfterSeparatorsCamelCaseAndDigits() throws {
        #expect(try #require(match("task", "newTask")).tier == .wordStart)
        #expect(try #require(match("build", "ci/build")).tier == .wordStart)
        #expect(try #require(match("run", "cargo_run")).tier == .wordStart)
        #expect(try #require(match("2", "tab2")).tier == .wordStart)
    }

    @Test func wordStartPrefersLaterWordStartOverEarlierSubstring() throws {
        // "log" occurs inside "catalog" first, then at the start of "logs".
        let result = try #require(match("log", "catalog logs"))
        #expect(result.tier == .wordStart)
        #expect(result.ranges == [8..<11])
    }

    @Test func initialsTier() throws {
        let result = try #require(match("nt", "New Task"))
        #expect(result.tier == .initials)
        #expect(result.ranges == [0..<1, 4..<5])
    }

    @Test func substringTier() throws {
        let result = try #require(match("ploy", "redeployed"))
        #expect(result.tier == .substring)
        #expect(result.ranges == [4..<8])
    }

    @Test func subsequenceTierPrefersTighterSpan() throws {
        let tight = try #require(match("dpy", "deploy"))
        let loose = try #require(match("dpy", "dxxxxxxxxpxxxxxxxxy"))
        #expect(tight.tier == .subsequence && loose.tier == .subsequence)
        #expect(tight.score > loose.score)
        #expect(tight.ranges == [0..<1, 2..<3, 5..<6])
    }

    @Test func tiersAreOrdered() throws {
        let scores = try [
            #require(match("abc", "abc")),
            #require(match("abc", "abcdef")),
            #require(match("abc", "x abc")),
            #require(match("abc", "a big cat")),
            #require(match("abc", "xxabcxx")),
            #require(match("abc", "axxbxxc")),
        ].map(\.score)
        #expect(scores == scores.sorted(by: >))
        #expect(Set(scores).count == scores.count)
        // The worst score of a tier beats the best of the tier below.
        for tier in SearchMatchTier.allCases.dropFirst() {
            #expect(tier.base > SearchMatchTier(rawValue: tier.rawValue - 1)!.base + 99)
        }
    }

    @Test func fuzzyOffDisablesInitialsAndSubsequence() {
        #expect(match("nt", "New Task", fuzzy: false) == nil)
        #expect(match("dpy", "deploy", fuzzy: false) == nil)
        #expect(match("ploy", "redeployed", fuzzy: false)?.tier == .substring)
    }

    @Test func noMatch() {
        #expect(match("zzz", "deploy") == nil)
        #expect(match("deployment", "deploy") == nil)
        #expect(match("", "deploy") == nil)
    }

    @Test func foldsCaseDiacriticsWidthAndKana() throws {
        #expect(try #require(match("cafe", "Café")).tier == .exact)
        #expect(try #require(match("abc", "ＡＢＣ")).tier == .exact)
        #expect(try #require(match("ターミナル", "たーみなる")).tier == .exact)
        #expect(try #require(match("たーみ", "ターミナル設定")).tier == .prefix)
    }

    @Test func expandedFoldKeepsCharacterRanges() throws {
        // "ß" folds to two units; the highlight still covers one character.
        let result = try #require(match("strasse", "Straße 1"))
        #expect(result.tier == .prefix)
        #expect(result.ranges == [0..<6])
    }

    @Test func longTextLimitCutsIndex() {
        let text = SearchText(String(repeating: "a", count: 50) + "needle", limit: 40)
        #expect(matcher.match(SearchText("needle"), in: text) == nil)
    }
}
