@testable import CNBrowserUI
import CNCore
import Testing

struct HistoryMenuRowTests {
    /// The new tab's about:blank is the Start Page, never a raw address.
    @Test func blankEntryIsTheStartPage() {
        let blank = BrowserHistoryEntry(id: 1, url: "about:blank", title: "")
        #expect(blank.isStartPage && blank.menuTitle == "Start Page" && blank.menuSubtitle == nil)
        let page = BrowserHistoryEntry(id: 2, url: "https://www.example.com/", title: "Example Domain")
        #expect(page.menuTitle == "Example Domain" && page.menuSubtitle == "example.com")
        let untitled = BrowserHistoryEntry(id: 3, url: "https://example.org/a/", title: "")
        #expect(untitled.menuTitle == "example.org/a" && untitled.menuSubtitle == nil)
    }
}
