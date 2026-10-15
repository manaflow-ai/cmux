@testable import CNBrowserUI
import CNCore
import Testing

struct StartPageFavoritesTests {
    /// example.com, example.net and example.org were all "Example": each
    /// tile now reads differently, one per site.
    @Test func collidingNamesUseTheHost() {
        let tabs = ["https://example.com/", "https://example.net/a", "https://www.example.org/", "https://example.org/b", "https://github.com/x"]
            .enumerated().map { BrowserTab(id: "t\($0.offset)", url: $0.element, title: "Example Domain") }
        let sites = FavoriteSite.from(tabs)
        #expect(sites.map(\.name) == ["example.com", "example.net", "example.org", "Github"])
        #expect(Set(sites.map(\.name)).count == sites.count)
        #expect(sites.map(\.monogram) == ["E", "E", "E", "G"])
    }

    @Test func distinctSitesKeepShortNames() {
        let tabs = [BrowserTab(id: "a", url: "https://cmux.dev/", title: ""), BrowserTab(id: "b", url: "about:blank", title: "")]
        #expect(FavoriteSite.from(tabs).map(\.name) == ["Cmux"])
    }
}
