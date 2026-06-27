import CmuxBrowser
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Guards the omnibar suggestion candidate cache added to ``BrowserHistoryStore``.
///
/// The store now precomputes each entry's lowercased/parsed match fields once
/// and rebuilds that cache only when `entries` changes, instead of re-parsing
/// every URL on every keystroke. These tests pin the behavioral contract that
/// matters for correctness: the cache must invalidate whenever history mutates,
/// so a warmed cache never hides a newly recorded visit or a stale ranking.
@MainActor
@Suite struct BrowserHistorySuggestionCacheTests {
    private func makeStore() -> (store: BrowserHistoryStore, fileURL: URL) {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-history-suggest-\(UUID().uuidString).json")
        return (BrowserHistoryStore(fileURL: fileURL), fileURL)
    }

    @Test func suggestionsMatchHostAndTitleAfterCaching() {
        let (store, fileURL) = makeStore()
        defer { store.clearHistory(); try? FileManager.default.removeItem(at: fileURL) }

        store.recordVisit(url: URL(string: "https://github.com/manaflow-ai/cmux/issues"), title: "cmux issues")
        store.recordVisit(url: URL(string: "https://example.com/docs"), title: "Example Docs")

        // First query warms the candidate cache.
        let results = store.suggestions(for: "github", limit: 8).map(\.url)
        #expect(results.contains("https://github.com/manaflow-ai/cmux/issues"))
        #expect(!results.contains("https://example.com/docs"))
    }

    @Test func newlyRecordedVisitInvalidatesWarmedCache() {
        let (store, fileURL) = makeStore()
        defer { store.clearHistory(); try? FileManager.default.removeItem(at: fileURL) }

        store.recordVisit(url: URL(string: "https://example.com/start"), title: "Start")
        // Warm the candidate cache with a query that does not match the URL we
        // are about to add.
        _ = store.suggestions(for: "example", limit: 8)

        store.recordVisit(url: URL(string: "https://manaflow.ai/pricing"), title: "Pricing")
        let results = store.suggestions(for: "manaflow", limit: 8).map(\.url)
        #expect(results.contains("https://manaflow.ai/pricing"))
    }

    @Test func repeatedVisitRefreshesCachedRanking() throws {
        let (store, fileURL) = makeStore()
        defer { store.clearHistory(); try? FileManager.default.removeItem(at: fileURL) }

        store.recordVisit(url: URL(string: "https://news.ycombinator.com/news"), title: "HN")
        // Warm the cache while the entry has visitCount == 1.
        _ = store.suggestions(for: "news", limit: 8)

        for _ in 0..<5 {
            store.recordVisit(url: URL(string: "https://news.ycombinator.com/news"), title: "HN")
        }

        let top = try #require(store.suggestions(for: "news", limit: 8).first)
        #expect(top.url == "https://news.ycombinator.com/news")
        #expect(top.visitCount == 6)
    }

    @Test func clearingHistoryDropsResidentSuggestionCache() {
        let (store, fileURL) = makeStore()
        defer { store.clearHistory(); try? FileManager.default.removeItem(at: fileURL) }

        store.recordVisit(url: URL(string: "https://secret.example.com/private-page"), title: "secret")
        // Warm the cache so the parsed/lowercased URL strings become resident.
        _ = store.suggestions(for: "secret", limit: 8)
        #expect(store.residentSuggestionCandidateCount > 0)

        // Clearing history must drop the cached candidates immediately, without
        // waiting for the next omnibar query, so cleared browsing history is not
        // left resident in memory.
        store.clearHistory()
        #expect(store.residentSuggestionCandidateCount == 0)
    }
}
