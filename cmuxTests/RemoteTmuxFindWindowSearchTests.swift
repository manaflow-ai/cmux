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
        let text = RemoteTmuxPaneText(
            lines: ["first Error here", "nothing", "second error: disk full", "prompt $"],
            isTruncated: false
        )
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
        let text = RemoteTmuxPaneText(lines: ["error", "Error"], isTruncated: false)
        let search = try RemoteTmuxFindWindowSearch(query: "Error", options: Self.contentsOnly)

        let hits = search.contentResults(for: candidate, text: text)

        #expect(hits.count == 1)
        guard case let .content(hit) = hits.first?.match else { return }
        #expect(hit.linesFromBottom == 0)
    }

    @Test func globMatchesAnywhereInALineLikeFindWindow() throws {
        let candidate = Self.pane(window: 1, name: "shell", order: 0)
        let text = RemoteTmuxPaneText(
            lines: ["GET /api/v1/users 200", "GET /api/v2/users 500", "POST /login 500"],
            isTruncated: false
        )
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
        let text = RemoteTmuxPaneText(lines: ["took 1532ms", "took 87ms"], isTruncated: false)
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
        let text = RemoteTmuxPaneText(lines: ["deploy finished"], isTruncated: false)
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
        let text = RemoteTmuxPaneText(lines: (0..<200).map { "line \($0) match" }, isTruncated: false)
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

        let hits = search.contentResults(for: candidate, text: RemoteTmuxPaneText(lines: [line], isTruncated: false))

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

    // MARK: - Fixtures

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
