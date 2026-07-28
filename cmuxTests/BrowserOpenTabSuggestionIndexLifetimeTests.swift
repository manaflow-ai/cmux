import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct BrowserOpenTabSuggestionIndexLifetimeTests {
    @Test func suggestionIndexesArePerManagerAndDeallocateIndependently() {
        var firstManager: TabManager? = TabManager(autoWelcomeIfNeeded: false)
        var secondManager: TabManager? = TabManager(autoWelcomeIfNeeded: false)
        weak var firstSuggestionIndex: BrowserOpenTabSuggestionIndex?
        weak var secondSuggestionIndex: BrowserOpenTabSuggestionIndex?
        firstSuggestionIndex = firstManager?.browserOpenTabSuggestionIndex
        secondSuggestionIndex = secondManager?.browserOpenTabSuggestionIndex

        #expect(firstSuggestionIndex != nil)
        #expect(secondSuggestionIndex != nil)
        #expect(firstSuggestionIndex !== secondSuggestionIndex)

        firstManager = nil

        #expect(firstSuggestionIndex == nil)
        #expect(secondSuggestionIndex != nil)

        secondManager = nil

        #expect(secondSuggestionIndex == nil)
    }
}
