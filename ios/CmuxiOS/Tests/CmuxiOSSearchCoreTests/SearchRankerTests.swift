import CmuxiOSFeatureKit
@testable import CmuxiOSSearchCore
import Testing

@Suite("SearchRanker")
struct SearchRankerTests {
    let ranker = SearchRanker()

    func item(_ id: String, _ title: String, _ category: SearchCategory = .workspaces, subtitle: String? = nil,
              keywords: [String] = [], details: [SearchField] = [], boost: Int = 0) -> SearchItem {
        SearchItem(id: id, category: category, title: title, subtitle: subtitle, symbolName: "square",
                   destination: .feedItem(id), keywords: keywords, details: details, boost: boost)
    }

    func ids(_ results: SearchResults) -> [String] { results.flat.map(\.id) }

    @Test func emptyQueryHasNoResults() {
        #expect(ranker.rank([item("a", "deploy")], query: SearchQuery("   ")).sections.isEmpty)
    }

    @Test func ordersPrefixThenWordStartThenSubsequence() {
        let items = [
            item("sub", "d e p l o y x"),
            item("word", "api deploy"),
            item("prefix", "deploy api"),
            item("none", "build"),
        ]
        #expect(ids(ranker.rank(items, query: SearchQuery("depl"))) == ["prefix", "word", "sub"])
    }

    @Test func titleOutweighsDetailOfSameTier() {
        let items = [
            item("detail", "something", details: [SearchField(SearchText("deploy"), weight: SearchField.contextWeight)]),
            item("title", "deploy"),
        ]
        #expect(ids(ranker.rank(items, query: SearchQuery("deploy"))) == ["title", "detail"])
    }

    @Test func everyTokenMustMatch() {
        let items = [
            item("both", "api deploy", subtitle: "MacBook"),
            item("one", "api build"),
        ]
        #expect(ids(ranker.rank(items, query: SearchQuery("api deploy"))) == ["both"])
        #expect(ids(ranker.rank(items, query: SearchQuery("deploy macbook"))) == ["both"])
    }

    @Test func wholeQueryCanBeatTokenMean() throws {
        let result = try #require(ranker.score(item("a", "new task"), query: SearchQuery("new task")))
        #expect(result.score == 1000)
        #expect(result.titleRanges == [0..<8])
    }

    @Test func boostsBreakTiesAndUnreadNeedsInputRiseFirst() {
        let items = [
            item("plain", "deploy"),
            item("needs", "deploy", .feed, boost: 50),
        ]
        #expect(ids(ranker.rank(items, query: SearchQuery("deploy"))).first == "needs")
    }

    @Test func groupsByCategoryOrderedByBestScore() {
        let items = [
            item("ws", "api deploy", .workspaces),
            item("feed", "deploy", .feed),
            item("host", "deploybox", .hosts),
        ]
        let results = ranker.rank(items, query: SearchQuery("deploy"))
        #expect(results.sections.map(\.category) == [.feed, .hosts, .workspaces])
    }

    @Test func equalScoresFallBackToFixedCategoryOrder() {
        let items = [item("s", "deploy", .settings), item("a", "deploy", .actions)]
        #expect(ranker.rank(items, query: SearchQuery("deploy")).sections.map(\.category) == [.actions, .settings])
    }

    @Test func capsEachGroupAndCountsHidden() {
        let items = (0..<9).map { item("w\($0)", "deploy \($0)") }
        let results = ranker.rank(items, query: SearchQuery("deploy"))
        #expect(results.sections.count == 1)
        #expect(results.sections[0].results.count == 6)
        #expect(results.sections[0].hiddenCount == 3)
        #expect(results.matchCount == 9)
    }

    @Test func tiesSortByTitleThenID() {
        let items = [item("b", "deploy b"), item("a2", "deploy a"), item("a1", "deploy a")]
        #expect(ids(ranker.rank(items, query: SearchQuery("deploy"))) == ["a1", "a2", "b"])
    }

    @Test func subtitleRangesHighlightSubtitleMatches() throws {
        let result = try #require(ranker.score(item("a", "Workspace", subtitle: "MacBook · npm run dev"),
                                               query: SearchQuery("npm")))
        #expect(result.titleRanges.isEmpty)
        #expect(result.subtitleRanges == [10..<13])
    }

    @Test func keywordsFindCatalogEntries() {
        let catalog = SearchCatalog()
        let results = ranker.rank(catalog.actions + catalog.settings, query: SearchQuery("qr"))
        #expect(results.flat.first?.item.destination == .action(.pairMac))
    }
}
