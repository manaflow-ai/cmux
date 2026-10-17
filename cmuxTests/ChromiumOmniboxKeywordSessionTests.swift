import Testing
import CmuxBrowser

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A Chromium page's extensions as the address bar sees them.
@MainActor
private final class RecordingKeywordProvider: BrowserPageOmniboxKeywordProviding {
    var keywords = [BrowserOmniboxKeyword(extensionID: "abc", keyword: "nt", name: "Notes")]
    private(set) var events: [String] = []

    func omniboxKeywords() -> [BrowserOmniboxKeyword] { keywords }
    func omniboxKeywordStarted(_ extensionID: String) { events.append("started \(extensionID)") }
    func omniboxKeywordSuggestions(_ extensionID: String, text: String) async -> [BrowserOmniboxKeywordSuggestion] { [] }
    func omniboxKeywordEntered(_ extensionID: String, text: String, disposition: BrowserOmniboxKeywordDisposition) {
        events.append("entered \(extensionID) \(text)")
    }
    func omniboxKeywordEnded(_ extensionID: String) { events.append("cancelled \(extensionID)") }
}

/// chrome.omnibox in a Chromium panel's address bar: the keyword and a space
/// start a session, Return hands the rest to the extension instead of
/// loading it, and leaving the keyword cancels the session.
@MainActor
@Suite struct ChromiumOmniboxKeywordSessionTests {
    @Test func returnInAKeywordSessionGoesToTheExtension() {
        let provider = RecordingKeywordProvider()
        let session = ChromiumOmniboxKeywordSession()

        #expect(session.update(text: "nt ", provider: provider)?.rest == "")
        #expect(session.update(text: "nt milk", provider: provider)?.rest == "milk")
        #expect(session.enter(text: "nt milk", provider: provider))

        #expect(provider.events == ["started abc", "entered abc milk"])
        // Entered, not cancelled: closing the address bar sends nothing more.
        session.end()
        #expect(provider.events.count == 2)
    }

    @Test func leavingTheKeywordCancelsTheSession() {
        let provider = RecordingKeywordProvider()
        let session = ChromiumOmniboxKeywordSession()

        _ = session.update(text: "nt milk", provider: provider)
        #expect(session.update(text: "ntmilk", provider: provider) == nil)
        _ = session.update(text: "nt again", provider: provider)
        session.end()

        #expect(provider.events == ["started abc", "cancelled abc", "started abc", "cancelled abc"])
    }

    @Test func plainTextAndWebKitPanelsAreNotIntercepted() {
        let provider = RecordingKeywordProvider()
        let session = ChromiumOmniboxKeywordSession()

        #expect(!session.enter(text: "example.com", provider: provider))
        // A WebKit panel has no keyword provider.
        #expect(!session.enter(text: "nt milk", provider: nil))
        #expect(provider.events.isEmpty)
    }

    @Test func chosenSuggestionRowStartsItsSessionWhenNeeded() {
        let provider = RecordingKeywordProvider()
        let session = ChromiumOmniboxKeywordSession()

        #expect(session.enter(extensionID: "abc", content: "milk tea", provider: provider))

        #expect(provider.events == ["started abc", "entered abc milk tea"])
        #expect(session.activeExtensionID == nil)
    }

    @Test func keywordRowShowsTheDescriptionAndFillsKeywordAndContent() {
        let row = OmnibarSuggestion(kind: .extensionKeyword(extensionID: "abc", keyword: "nt", name: "Notes",
                                                            content: "milk tea", description: "Milk tea"))
        #expect(row.completion == "nt milk tea")
        #expect(row.primaryText == "Milk tea")
        #expect(row.trailingBadgeText == "Notes")
    }
}
