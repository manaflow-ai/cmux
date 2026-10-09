import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Global search snippet")
struct GlobalSearchSnippetTests {
    @Test
    func excerptCentersOnTheLongestTokenAtAWordStart() {
        let text = String(repeating: "filler ", count: 30)
            + "the retoken step, then the token spend report for delphi"
            + String(repeating: " tail", count: 40)
        let excerpt = GlobalSearchSnippet.excerpt(text: text, tokens: ["token", "spend"])
        #expect(excerpt.hasPrefix("..."))
        #expect(excerpt.hasSuffix("..."))
        #expect(excerpt.contains("token spend report"))
        let tokenRange = excerpt.range(of: "token spend")
        let retokenRange = excerpt.range(of: "retoken")
        #expect(tokenRange != nil)
        // The word-start match wins over the earlier mid-word "retoken".
        if let retokenRange, let tokenRange {
            #expect(retokenRange.lowerBound < tokenRange.lowerBound)
        }
    }

    @Test
    func matchIgnoresCaseAndDiacritics() {
        let excerpt = GlobalSearchSnippet.excerpt(text: "Notes on the Café DEPLOY plan", tokens: ["cafe", "deploy"])
        #expect(excerpt == "Notes on the Café DEPLOY plan")
    }

    @Test
    func titleOnlyMatchShowsTheStartOfTheText() {
        let text = "first line of the session\n\n  second line"
        #expect(GlobalSearchSnippet.excerpt(text: text, tokens: ["absent"]) == "first line of the session second line")
    }

    @Test
    func emptyTextGivesAnEmptyExcerpt() {
        #expect(GlobalSearchSnippet.excerpt(text: "", tokens: ["token"]).isEmpty)
    }
}
