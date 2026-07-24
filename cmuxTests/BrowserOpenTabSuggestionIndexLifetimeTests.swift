import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct BrowserOpenTabSuggestionIndexLifetimeTests {
    @Test func suggestionIndexDeallocatesWithTabManager() {
        var manager: TabManager? = TabManager(autoWelcomeIfNeeded: false)
        weak var suggestionIndex: BrowserOpenTabSuggestionIndex?
        suggestionIndex = manager?.browserOpenTabSuggestionIndex

        #expect(suggestionIndex != nil)
        manager = nil

        #expect(suggestionIndex == nil)
    }
}
