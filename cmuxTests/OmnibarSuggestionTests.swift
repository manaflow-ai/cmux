import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Omnibar Suggestion Merge & Ranking
final class OmnibarRemoteSuggestionMergeTests: XCTestCase {
    func testMergeRemoteSuggestionsInsertsBelowSearchAndDedupes() {
        let now = Date()
        let entries: [BrowserHistoryStore.Entry] = [
            BrowserHistoryStore.Entry(
                id: UUID(),
                url: "https://go.dev/",
                title: "The Go Programming Language",
                lastVisited: now,
                visitCount: 10
            ),
        ]

        let merged = buildOmnibarSuggestions(
            query: "go",
            engineName: "Google",
            historyEntries: entries,
            openTabMatches: [],
            remoteQueries: ["go tutorial", "go.dev", "go json"],
            resolvedURL: nil,
            limit: 8
        )

        let completions = merged.compactMap { $0.completion }
        XCTAssertGreaterThanOrEqual(completions.count, 5)
        XCTAssertEqual(completions[0], "https://go.dev/")
        XCTAssertEqual(completions[1], "go")

        let remoteCompletions = Array(completions.dropFirst(2))
        XCTAssertEqual(Set(remoteCompletions), Set(["go tutorial", "go.dev", "go json"]))
        XCTAssertEqual(remoteCompletions.count, 3)
    }

    func testStaleRemoteSuggestionsKeptForNearbyEdits() {
        let stale = staleOmnibarRemoteSuggestionsForDisplay(
            query: "go t",
            previousRemoteQuery: "go",
            previousRemoteSuggestions: ["go tutorial", "go json", "golang tips"],
            limit: 8
        )

        XCTAssertEqual(stale, ["go tutorial", "go json", "golang tips"])
    }

    func testStaleRemoteSuggestionsTrimAndRespectLimit() {
        let stale = staleOmnibarRemoteSuggestionsForDisplay(
            query: "gooo",
            previousRemoteQuery: "goo",
            previousRemoteSuggestions: [" go tutorial ", "", "go json", "   ", "go fmt"],
            limit: 2
        )

        XCTAssertEqual(stale, ["go tutorial", "go json"])
    }

    func testStaleRemoteSuggestionsDroppedForUnrelatedQuery() {
        let stale = staleOmnibarRemoteSuggestionsForDisplay(
            query: "python",
            previousRemoteQuery: "go",
            previousRemoteSuggestions: ["go tutorial", "go json"],
            limit: 8
        )

        XCTAssertTrue(stale.isEmpty)
    }
}


final class OmnibarSuggestionRankingTests: XCTestCase {
    private var fixedNow: Date {
        Date(timeIntervalSinceReferenceDate: 10_000_000)
    }

    func testSingleCharacterQueryPromotesAutocompletionMatchToFirstRow() {
        let entries: [BrowserHistoryStore.Entry] = [
            .init(
                id: UUID(),
                url: "https://news.ycombinator.com/",
                title: "News.YC",
                lastVisited: fixedNow,
                visitCount: 12,
                typedCount: 1,
                lastTypedAt: fixedNow
            ),
            .init(
                id: UUID(),
                url: "https://www.google.com/",
                title: "Google",
                lastVisited: fixedNow - 200,
                visitCount: 8,
                typedCount: 2,
                lastTypedAt: fixedNow - 200
            ),
        ]

        let results = buildOmnibarSuggestions(
            query: "n",
            engineName: "Google",
            historyEntries: entries,
            openTabMatches: [],
            remoteQueries: ["search google for n", "news"],
            resolvedURL: nil,
            limit: 8,
            now: fixedNow
        )

        XCTAssertEqual(results.first?.completion, "https://news.ycombinator.com/")
        XCTAssertNotEqual(results.map(\.completion).first, "n")
        XCTAssertTrue(results.first.map { omnibarSuggestionSupportsAutocompletion(query: "n", suggestion: $0) } ?? false)
    }

    func testGmAutocompleteCandidateIsFirstOnExactQueryMatch() {
        let entries: [BrowserHistoryStore.Entry] = [
            .init(
                id: UUID(),
                url: "https://google.com/",
                title: "Google",
                lastVisited: fixedNow,
                visitCount: 4,
                typedCount: 1,
                lastTypedAt: fixedNow
            ),
            .init(
                id: UUID(),
                url: "https://gmail.com/",
                title: "Gmail",
                lastVisited: fixedNow,
                visitCount: 10,
                typedCount: 2,
                lastTypedAt: fixedNow
            ),
        ]

        let results = buildOmnibarSuggestions(
            query: "gm",
            engineName: "Google",
            historyEntries: entries,
            openTabMatches: [],
            remoteQueries: ["gmail", "gmail.com", "google mail"],
            resolvedURL: nil,
            limit: 8,
            now: fixedNow
        )

        XCTAssertEqual(results.first?.completion, "https://gmail.com/")
        XCTAssertTrue(omnibarSuggestionSupportsAutocompletion(query: "gm", suggestion: results[0]))

        let inlineCompletion = omnibarInlineCompletionForDisplay(
            typedText: "gm",
            suggestions: results,
            isFocused: true,
            selectionRange: NSRange(location: 2, length: 0),
            hasMarkedText: false
        )
        XCTAssertNotNil(inlineCompletion)
    }

    func testAutocompletionCandidateWinsOverRemoteAndSearchRowsForTwoLetterQuery() {
        let entries: [BrowserHistoryStore.Entry] = [
            .init(
                id: UUID(),
                url: "https://google.com/",
                title: "Google",
                lastVisited: fixedNow,
                visitCount: 4,
                typedCount: 1,
                lastTypedAt: fixedNow
            ),
            .init(
                id: UUID(),
                url: "https://gmail.com/",
                title: "Gmail",
                lastVisited: fixedNow,
                visitCount: 10,
                typedCount: 2,
                lastTypedAt: fixedNow
            ),
        ]

        let results = buildOmnibarSuggestions(
            query: "gm",
            engineName: "Google",
            historyEntries: entries,
            openTabMatches: [
                .init(
                    tabId: UUID(),
                    panelId: UUID(),
                    url: "https://gmail.com/",
                    title: "Gmail",
                    isKnownOpenTab: true
                ),
            ],
            remoteQueries: ["Search google for gm", "gmail", "gmail.com", "Google mail"],
            resolvedURL: nil,
            limit: 8,
            now: fixedNow
        )

        XCTAssertTrue(omnibarSuggestionSupportsAutocompletion(query: "gm", suggestion: results[0]))
        XCTAssertEqual(results.first?.completion, "https://gmail.com/")
    }

    func testSuggestionSelectionPrefersAutocompletionCandidateAfterSuggestionsUpdate() {
        let entries: [BrowserHistoryStore.Entry] = [
            .init(
                id: UUID(),
                url: "https://google.com/",
                title: "Google",
                lastVisited: fixedNow,
                visitCount: 4,
                typedCount: 1,
                lastTypedAt: fixedNow
            ),
            .init(
                id: UUID(),
                url: "https://gmail.com/",
                title: "Gmail",
                lastVisited: fixedNow,
                visitCount: 10,
                typedCount: 2,
                lastTypedAt: fixedNow
            ),
        ]

        let results = buildOmnibarSuggestions(
            query: "gm",
            engineName: "Google",
            historyEntries: entries,
            openTabMatches: [],
            remoteQueries: ["Search google for gm", "gmail", "gmail.com"],
            resolvedURL: nil,
            limit: 8,
            now: fixedNow
        )

        var state = OmnibarState()
        let _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: ""))
        let _ = omnibarReduce(state: &state, event: .bufferChanged("gm"))
        let _ = omnibarReduce(state: &state, event: .suggestionsUpdated(results))

        XCTAssertEqual(state.selectedSuggestionIndex, 0)
        XCTAssertEqual(state.selectedSuggestionID, results[0].id)
        XCTAssertTrue(omnibarSuggestionSupportsAutocompletion(query: "gm", suggestion: state.suggestions[0]))
    }

    func testTwoCharQueryWithRemoteSuggestionsStillPromotesAutocompletionMatch() {
        let entries: [BrowserHistoryStore.Entry] = [
            .init(
                id: UUID(),
                url: "https://news.ycombinator.com/",
                title: "News.YC",
                lastVisited: fixedNow,
                visitCount: 12,
                typedCount: 1,
                lastTypedAt: fixedNow
            ),
            .init(
                id: UUID(),
                url: "https://www.google.com/",
                title: "Google",
                lastVisited: fixedNow - 200,
                visitCount: 8,
                typedCount: 2,
                lastTypedAt: fixedNow - 200
            ),
        ]

        let results = buildOmnibarSuggestions(
            query: "ne",
            engineName: "Google",
            historyEntries: entries,
            openTabMatches: [],
            remoteQueries: ["netflix", "new york times", "newegg"],
            resolvedURL: nil,
            limit: 8,
            now: fixedNow
        )

        // The autocompletable history entry (news.ycombinator.com) should be first despite remote results.
        XCTAssertEqual(results.first?.completion, "https://news.ycombinator.com/")
        XCTAssertTrue(results.first.map { omnibarSuggestionSupportsAutocompletion(query: "ne", suggestion: $0) } ?? false)

        // Remote suggestions should still appear in the results (two-char queries include them).
        let remoteCompletions = results.filter {
            if case .remote = $0.kind { return true }
            return false
        }.map(\.completion)
        XCTAssertFalse(remoteCompletions.isEmpty, "Expected remote suggestions to be present for two-char query")
    }

    func testGmQueryWithRemoteSuggestionsAndOpenTabPromotesAutocompletionMatch() {
        let entries: [BrowserHistoryStore.Entry] = [
            .init(
                id: UUID(),
                url: "https://google.com/",
                title: "Google",
                lastVisited: fixedNow,
                visitCount: 4,
                typedCount: 1,
                lastTypedAt: fixedNow
            ),
            .init(
                id: UUID(),
                url: "https://gmail.com/",
                title: "Gmail",
                lastVisited: fixedNow,
                visitCount: 10,
                typedCount: 2,
                lastTypedAt: fixedNow
            ),
        ]

        let results = buildOmnibarSuggestions(
            query: "gm",
            engineName: "Google",
            historyEntries: entries,
            openTabMatches: [
                .init(
                    tabId: UUID(),
                    panelId: UUID(),
                    url: "https://google.com/maps",
                    title: "Google Maps",
                    isKnownOpenTab: true
                ),
            ],
            remoteQueries: ["gmail login", "gm stock price", "gmail.com"],
            resolvedURL: nil,
            limit: 8,
            now: fixedNow
        )

        // Gmail should be first (autocompletable + typed history).
        XCTAssertEqual(results.first?.completion, "https://gmail.com/")
        XCTAssertTrue(omnibarSuggestionSupportsAutocompletion(query: "gm", suggestion: results[0]))

        // Verify remote suggestions are present alongside history/tab matches.
        let remoteCompletions = results.filter {
            if case .remote = $0.kind { return true }
            return false
        }.map(\.completion)
        XCTAssertFalse(remoteCompletions.isEmpty, "Expected remote suggestions in results")
        let hasSearch = results.contains {
            if case .search = $0.kind { return true }
            return false
        }
        XCTAssertTrue(hasSearch, "Expected search row in results")
    }

    func testHistorySuggestionDisplaysTitleAndUrlOnSingleLine() {
        let row = OmnibarSuggestion.history(
            url: "https://www.example.com/path?q=1",
            title: "Example Domain"
        )
        XCTAssertEqual(row.listText, "Example Domain — example.com/path?q=1")
        XCTAssertFalse(row.listText.contains("\n"))
    }

    func testPublishedBufferTextUsesTypedPrefixWhenInlineSuffixIsSelected() {
        let inline = OmnibarInlineCompletion(
            typedText: "l",
            displayText: "localhost:3000",
            acceptedText: "https://localhost:3000/"
        )

        let published = omnibarPublishedBufferTextForFieldChange(
            fieldValue: inline.displayText,
            inlineCompletion: inline,
            selectionRange: inline.suffixRange,
            hasMarkedText: false
        )

        XCTAssertEqual(published, "l")
    }

    func testPublishedBufferTextKeepsUserTypedValueWhenDisplayDiffersFromInlineText() {
        let inline = OmnibarInlineCompletion(
            typedText: "l",
            displayText: "localhost:3000",
            acceptedText: "https://localhost:3000/"
        )

        let published = omnibarPublishedBufferTextForFieldChange(
            fieldValue: "la",
            inlineCompletion: inline,
            selectionRange: NSRange(location: 2, length: 0),
            hasMarkedText: false
        )

        XCTAssertEqual(published, "la")
    }

    func testInlineCompletionRenderIgnoresStaleTypedPrefixMismatch() {
        let staleInline = OmnibarInlineCompletion(
            typedText: "g",
            displayText: "github.com",
            acceptedText: "https://github.com/"
        )

        let active = omnibarInlineCompletionIfBufferMatchesTypedPrefix(
            bufferText: "l",
            inlineCompletion: staleInline
        )

        XCTAssertNil(active)
    }

    func testInlineCompletionRenderKeepsMatchingTypedPrefix() {
        let inline = OmnibarInlineCompletion(
            typedText: "l",
            displayText: "localhost:3000",
            acceptedText: "https://localhost:3000/"
        )

        let active = omnibarInlineCompletionIfBufferMatchesTypedPrefix(
            bufferText: "l",
            inlineCompletion: inline
        )

        XCTAssertEqual(active, inline)
    }

    func testInlineCompletionSkipsTitleMatchWhoseURLDoesNotStartWithTypedText() {
        // History entry: visited google.com/search?q=localhost:3000 with title
        // "localhost:3000 - Google Search". Typing "l" should NOT inline-complete
        // to "google.com/..." because that replaces the typed "l" with "g".
        let suggestions: [OmnibarSuggestion] = [
            .history(
                url: "https://www.google.com/search?q=localhost:3000",
                title: "localhost:3000 - Google Search"
            ),
        ]

        let result = omnibarInlineCompletionForDisplay(
            typedText: "l",
            suggestions: suggestions,
            isFocused: true,
            selectionRange: NSRange(location: 1, length: 0),
            hasMarkedText: false
        )

        XCTAssertNil(result, "Should not inline-complete when display text does not start with typed prefix")
    }
}
