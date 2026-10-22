import CmuxTextMatching
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Matching for find-window: fzf-scored names and titles, tmux glob and regex,
/// and a literal smart-case content search over each pane's whole history.
@Suite struct RemoteTmuxFindWindowSearchTests {
    @Test func fuzzyWindowNamesRankWordStartsAboveScatteredLetters() throws {
        let candidates = [
            Self.pane(window: 1, name: "bisect-runs", order: 0),
            Self.pane(window: 2, name: "build-server", order: 1),
            Self.pane(window: 3, name: "logs", order: 2),
        ]
        let search = try RemoteTmuxFindWindowSearch(query: "bs", options: Self.namesOnly)

        let results = search.nameAndTitleResults(in: candidates)

        // fzf v2: b and s both on word starts in "build-server" beats "bisect".
        #expect(results.map(\.candidate.windowName) == ["build-server", "bisect-runs"])
        #expect(results.first?.match == .windowName(highlights: [0..<1, 6..<7]))
        #expect(results[0].score > results[1].score)
    }

    @Test func fuzzyQueriesUseFzfExtendedSyntaxAndSmartCase() throws {
        let candidates = [
            Self.pane(window: 1, name: "api-server", order: 0),
            Self.pane(window: 2, name: "API-docs", order: 1),
            Self.pane(window: 3, name: "web-server", order: 2),
        ]
        let exactAndNot = try RemoteTmuxFindWindowSearch(query: "'server !web", options: Self.namesOnly)
        #expect(exactAndNot.nameAndTitleResults(in: candidates).map(\.candidate.windowName) == ["api-server"])

        let capital = try RemoteTmuxFindWindowSearch(query: "API", options: Self.namesOnly)
        #expect(capital.nameAndTitleResults(in: candidates).map(\.candidate.windowName) == ["API-docs"])
    }

    @Test func fuzzyTitlesSkipTheHostNameDefaultButGlobSeesIt() throws {
        let candidates = [
            Self.pane(window: 1, name: "one", paneTitle: "devbox", intentionalTitle: nil, order: 0),
            Self.pane(window: 2, name: "two", paneId: 9, paneTitle: "deploy watcher", intentionalTitle: "deploy watcher", order: 1),
        ]
        var options = Self.namesOnly
        options.matchesWindowNames = false
        options.matchesPaneTitles = true

        let fuzzy = try RemoteTmuxFindWindowSearch(query: "dev", options: options)
        #expect(fuzzy.nameAndTitleResults(in: candidates).isEmpty)

        options.syntax = .glob
        let glob = try RemoteTmuxFindWindowSearch(query: "dev*", options: options)
        let hits = glob.nameAndTitleResults(in: candidates)
        #expect(hits.map(\.candidate.paneId) == [107])
        // The highlight is the shortest span the glob matches from its leftmost start.
        #expect(hits.first?.match == .paneTitle(title: "devbox", highlights: [0..<3]))
    }

    @Test func contentHitsComeNewestFirstWithTheirDistanceFromTheBottom() throws {
        let candidate = Self.pane(window: 1, name: "shell", order: 0)
        let text = RemoteTmuxPaneText(lines: ["first Error here", "nothing", "second error: disk full", "prompt $"], paneWidth: 80, isTruncated: false)
        let search = try RemoteTmuxFindWindowSearch(query: "error", options: Self.contentsOnly)

        let hits = search.contentResults(for: candidate, text: text)

        guard case let .content(newest) = hits.first?.match,
              case let .content(oldest) = hits.last?.match else {
            Issue.record("expected two content hits, got \(hits)")
            return
        }
        #expect(hits.count == 2)
        #expect(newest.linesFromBottom == 1)
        #expect(newest.matchedText == "error")
        #expect(newest.snippet == "second error: disk full")
        #expect(newest.highlights == [7..<12])
        // Smart case: an all-lowercase query ignores case.
        #expect(oldest.linesFromBottom == 3)
        #expect(oldest.matchedText == "Error")
    }

    @Test func aCapitalInTheQueryMakesTheContentSearchCaseSensitive() throws {
        let candidate = Self.pane(window: 1, name: "shell", order: 0)
        let text = RemoteTmuxPaneText(lines: ["error", "Error"], paneWidth: 80, isTruncated: false)
        let search = try RemoteTmuxFindWindowSearch(query: "Error", options: Self.contentsOnly)

        let hits = search.contentResults(for: candidate, text: text)

        #expect(hits.count == 1)
        guard case let .content(hit) = hits.first?.match else { return }
        #expect(hit.linesFromBottom == 0)
    }

    @Test func globMatchesAnywhereInALineLikeFindWindow() throws {
        let candidate = Self.pane(window: 1, name: "shell", order: 0)
        let text = RemoteTmuxPaneText(lines: ["GET /api/v1/users 200", "GET /api/v2/users 500", "POST /login 500"], paneWidth: 80, isTruncated: false)
        var options = Self.contentsOnly
        options.syntax = .glob

        let search = try RemoteTmuxFindWindowSearch(query: "/api/v[0-9]/* 5??", options: options)
        let hits = search.contentResults(for: candidate, text: text)

        #expect(hits.count == 1)
        guard case let .content(hit) = hits.first?.match else { return }
        #expect(hit.matchedText == "/api/v2/users 500")
    }

    @Test func regexModeMatchesAndAnInvalidRegexIsReported() throws {
        let candidate = Self.pane(window: 1, name: "shell", order: 0)
        let text = RemoteTmuxPaneText(lines: ["took 1532ms", "took 87ms"], paneWidth: 80, isTruncated: false)
        var options = Self.contentsOnly
        options.syntax = .regex

        let search = try RemoteTmuxFindWindowSearch(query: "[0-9]{4,}ms", options: options)
        let hits = search.contentResults(for: candidate, text: text)
        #expect(hits.count == 1)
        guard case let .content(hit) = hits.first?.match else { return }
        #expect(hit.matchedText == "1532ms")

        #expect(throws: PaneContentMatcherError.self) {
            _ = try RemoteTmuxFindWindowSearch(query: "([unclosed", options: options)
        }
    }

    @Test func turningContentsOffLeavesOnlyNamesAndTitles() throws {
        let candidate = Self.pane(window: 1, name: "deploy", order: 0)
        let text = RemoteTmuxPaneText(lines: ["deploy finished"], paneWidth: 80, isTruncated: false)
        var options = RemoteTmuxFindWindowOptions()
        options.matchesContents = false

        let search = try RemoteTmuxFindWindowSearch(query: "deploy", options: options)
        let results = search.results(candidates: [candidate], texts: [candidate.id: text])

        #expect(results.count == 1)
        #expect(results.first?.match == .windowName(highlights: [0..<6]))
    }

    @Test func anEmptyQueryListsEachWindowOnceInTabOrder() throws {
        let candidates = [
            Self.pane(window: 2, name: "second", paneId: 4, paneIndex: 0, order: 10),
            Self.pane(window: 2, name: "second", paneId: 5, paneIndex: 1, order: 11),
            Self.pane(window: 1, name: "first", paneId: 3, order: 0),
        ]
        let search = try RemoteTmuxFindWindowSearch(query: "  ", options: RemoteTmuxFindWindowOptions())

        let results = search.results(candidates: candidates, texts: [:])

        #expect(results.map(\.candidate.windowName) == ["first", "second"])
        #expect(results.map(\.candidate.paneId) == [3, 4])
        #expect(results.allSatisfy { $0.match == .window })
    }

    @Test func eachPaneKeepsAtMostTheNewestFiftyContentHits() throws {
        let candidate = Self.pane(window: 1, name: "shell", order: 0)
        let text = RemoteTmuxPaneText(lines: (0..<200).map { "line \($0) match" }, paneWidth: 80, isTruncated: false)
        let search = try RemoteTmuxFindWindowSearch(query: "match", options: Self.contentsOnly)

        let hits = search.contentResults(for: candidate, text: text)

        #expect(hits.count == RemoteTmuxFindWindowSearch.maximumContentHitsPerPane)
        guard case let .content(first) = hits.first?.match,
              case let .content(last) = hits.last?.match else { return }
        #expect(first.snippet == "line 199 match")
        #expect(last.linesFromBottom == 49)
    }

    @Test func aLongLineIsCutToASnippetThatKeepsTheMatch() throws {
        let candidate = Self.pane(window: 1, name: "shell", order: 0)
        let line = String(repeating: "a", count: 300) + " needle " + String(repeating: "b", count: 300)
        let search = try RemoteTmuxFindWindowSearch(query: "needle", options: Self.contentsOnly)

        let hits = search.contentResults(for: candidate, text: RemoteTmuxPaneText(lines: [line], paneWidth: 80, isTruncated: false))

        guard case let .content(hit) = hits.first?.match else {
            Issue.record("no hit")
            return
        }
        #expect(hit.snippet.hasPrefix("…"))
        #expect(hit.snippet.hasSuffix("…"))
        let characters = Array(hit.snippet)
        let highlighted = hit.highlights.first.map { String(characters[$0]) }
        #expect(highlighted == "needle")
    }

    @Test func matchCaseAppliesToFuzzyNamesAndTitles() throws {
        let candidates = [Self.pane(window: 1, name: "Build", order: 0)]
        var options = Self.namesOnly
        options.caseMode = .respect
        #expect(try RemoteTmuxFindWindowSearch(query: "build", options: options).nameAndTitleResults(in: candidates).isEmpty)
        options.caseMode = .ignore
        #expect(try RemoteTmuxFindWindowSearch(query: "BUILD", options: options).nameAndTitleResults(in: candidates).count == 1)
    }

    @Test(arguments: [(PaneContentSyntax.regex, "^"), (.regex, "\\s+indented"), (.glob, " *")])
    func aMatchThatStartsInLeadingSpaceIsCutWithoutTrapping(syntax: PaneContentSyntax, query: String) throws {
        var options = Self.contentsOnly
        options.syntax = syntax
        let search = try RemoteTmuxFindWindowSearch(query: query, options: options)
        let text = Self.text(["    indented"])

        let hits = search.contentResults(for: Self.pane(window: 1, name: "shell", order: 0), text: text)

        guard case let .content(hit) = hits.first?.match else {
            Issue.record("no hit for \(query)")
            return
        }
        #expect(hit.snippet == "indented")
    }

    /// Every range on Unicode scalar boundaries (what the glob and regex matchers return)
    /// over lines of spaces, tabs, combining marks, emoji, flags and wide characters.
    @Test func contentHitsNeverTrapAndHighlightTheMatchedText() {
        let pieces = [" ", "\t", "a", "Z", "-", "\u{e9}", "e\u{301}", "\u{1F44D}\u{1F3FD}", "\u{1F1EF}\u{1F1F5}", "\u{4E2D}", "\u{301}"]
        var random = SplitMix64(seed: 0x5EED)
        var lines = ["", " ", "\t \t", "x", "\u{301}", "\u{1F44D}\u{1F3FD}", "  a  "]
        for _ in 0..<200 {
            let count = Int(random.next() % 12)
            lines.append((0..<count).map { _ in pieces[Int(random.next() % UInt64(pieces.count))] }.joined())
        }
        for line in lines {
            let boundaries = Set(Array(line.indices) + [line.endIndex])
            let firstVisible = line.firstIndex { !$0.isWhitespace } ?? line.endIndex
            let visibleEnd = line.lastIndex { !$0.isWhitespace }.map { line.index(after: $0) } ?? firstVisible
            let scalars = Array(line.unicodeScalars.indices) + [line.endIndex]
            for (offset, lower) in scalars.enumerated() {
                for upper in scalars[offset...] {
                    let hit = RemoteTmuxFindWindowSearch.contentHit(
                        line: line, match: lower..<upper, linesFromBottom: 0, rowsFromBottom: 0
                    )
                    let snippet = Array(hit.snippet)
                    for range in hit.highlights {
                        #expect(
                            range.lowerBound >= 0 && range.upperBound <= snippet.count && !range.isEmpty,
                            "\(line.debugDescription) \(range) in \(hit.snippet.debugDescription)"
                        )
                    }
                    guard boundaries.contains(lower), boundaries.contains(upper), lower < upper,
                          lower >= firstVisible, upper <= visibleEnd else { continue }
                    // Whole characters inside the visible text are highlighted exactly.
                    let highlighted = hit.highlights.first.map { String(snippet[$0]) }
                    #expect(
                        hit.highlights.count == 1 && highlighted == hit.matchedText,
                        "\(line.debugDescription): \(String(line[lower..<upper]).debugDescription) -> \(String(describing: highlighted))"
                    )
                }
            }
        }
    }

    /// The real glob and regex content path over the same kinds of lines.
    @Test func globAndRegexContentSearchesNeverTrap() throws {
        let pieces = [" ", "\t", "a", "-", "e\u{301}", "\u{1F44D}\u{1F3FD}", "\u{4E2D}", "\u{301}"]
        var random = SplitMix64(seed: 0xC0FFEE)
        let lines = (0..<200).map { _ in
            (0..<Int(random.next() % 12)).map { _ in pieces[Int(random.next() % UInt64(pieces.count))] }.joined()
        }
        let queries: [(PaneContentSyntax, String)] = [
            (.regex, "^"), (.regex, "$"), (.regex, "\\s+"), (.regex, "\\s*"), (.regex, "."),
            (.regex, "\u{301}"), (.regex, "\\p{M}"), (.regex, "(?=a)"), (.regex, "a|\\s"),
            (.glob, "*"), (.glob, "?"), (.glob, " *"), (.glob, "* "), (.glob, "[ \t]"), (.glob, "*\u{301}*"),
            (.text, "\u{301}"), (.text, "e"),
        ]
        let candidate = Self.pane(window: 1, name: "shell", order: 0)
        for (syntax, query) in queries {
            var options = Self.contentsOnly
            options.syntax = syntax
            options.caseMode = .respect
            let search = try RemoteTmuxFindWindowSearch(query: query, options: options)
            for result in search.contentResults(for: candidate, text: Self.text(lines)) {
                guard case let .content(hit) = result.match else { continue }
                let snippet = Array(hit.snippet)
                for range in hit.highlights {
                    #expect(range.lowerBound >= 0 && range.upperBound <= snippet.count && !range.isEmpty)
                }
            }
        }
    }

    @Test func distanceFromTheBottomCountsWrappedRows() throws {
        // At 10 columns the 60,000-character line under the match fills 6,000 rows, so
        // the match is past the attach seed's rows though it is one line from the bottom.
        let text = RemoteTmuxPaneText(
            lines: ["needle", String(repeating: "x", count: 60_000)],
            paneWidth: 10,
            isTruncated: false
        )
        let hit = try #require(Self.firstContentHit("needle", in: text))
        #expect(hit.linesFromBottom == 1)
        #expect(hit.rowsFromBottom == 6_000)
        #expect(hit.isBeyondAttachSeed)
    }

    @Test func aWideCharacterTakesTwoColumns() throws {
        // 3,000 wide characters are 6,000 columns: six rows at 1,000 columns.
        let text = RemoteTmuxPaneText(
            lines: ["needle", String(repeating: "\u{4E2D}", count: 3_000)],
            paneWidth: 1_000,
            isTruncated: false
        )
        let hit = try #require(Self.firstContentHit("needle", in: text))
        #expect(hit.rowsFromBottom == 6)
        #expect(!hit.isBeyondAttachSeed)
    }

    // MARK: - Fixtures

    static func text(_ lines: [String]) -> RemoteTmuxPaneText {
        RemoteTmuxPaneText(lines: lines, paneWidth: 80, isTruncated: false)
    }

    private static func firstContentHit(_ query: String, in text: RemoteTmuxPaneText) -> RemoteTmuxFindWindowContentHit? {
        let search = try? RemoteTmuxFindWindowSearch(query: query, options: contentsOnly)
        guard case let .content(hit) = search?.contentResults(for: pane(window: 1, name: "shell", order: 0), text: text).first?.match
        else { return nil }
        return hit
    }

    private static var namesOnly: RemoteTmuxFindWindowOptions {
        var options = RemoteTmuxFindWindowOptions()
        options.matchesPaneTitles = false
        options.matchesContents = false
        return options
    }

    private static var contentsOnly: RemoteTmuxFindWindowOptions {
        var options = RemoteTmuxFindWindowOptions()
        options.matchesWindowNames = false
        options.matchesPaneTitles = false
        return options
    }

    static func pane(
        window: Int,
        name: String,
        paneId: Int? = nil,
        paneIndex: Int = 0,
        paneTitle: String = "",
        intentionalTitle: String? = nil,
        order: Int,
        host: String = "build-host"
    ) -> RemoteTmuxFindWindowCandidate {
        let paneId = paneId ?? window * 100 + 7
        return RemoteTmuxFindWindowCandidate(
            id: .init(hostKey: host, paneId: paneId),
            hostLabel: host,
            sessionName: "work",
            windowId: window,
            windowName: name,
            paneId: paneId,
            paneIndex: paneIndex,
            windowPaneCount: 1,
            paneTitle: paneTitle,
            intentionalPaneTitle: intentionalTitle,
            workspaceId: UUID(),
            surfaceId: nil,
            order: order
        )
    }
}

/// A seeded generator, so a failing case reproduces.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
