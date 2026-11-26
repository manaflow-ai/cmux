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
    func promptIconGlyphsAreDropped() {
        let text = "\u{E0B6}\u{F07C} ~/code \u{E0B0} \u{2714} \u{F017} 16:44:11 $\u{FFFD} echo 4+4"
        let excerpt = GlobalSearchSnippet.excerpt(text: text, tokens: ["echo"])
        #expect(excerpt == "~/code \u{2714} 16:44:11 $ echo 4+4")
    }

    @Test
    func aPunctuatedQueryWordIsFoundWholeBeforeItsTokens() {
        let text = "lucas@Lucass-MacBook-Pro-4:~ 16:44:11" + String(repeating: " filler", count: 30) + " so 4+4 is 8"
        let excerpt = GlobalSearchSnippet.excerpt(text: text, tokens: ["4", "4"], phrases: ["4+4"])
        #expect(excerpt.contains("so 4+4 is 8"))
        #expect(!excerpt.contains("Pro-4"))
    }

    @Test
    func sessionMessagesAreJoinedWithASeparator() {
        let excerpt = GlobalSearchSnippet.excerpt(
            text: "2+2\n4\nwhat about 8+8",
            tokens: ["2"],
            lineSeparator: GlobalSearchSnippet.messageSeparator
        )
        #expect(excerpt == "2+2 \u{00B7} 4 \u{00B7} what about 8+8")
    }

    @Test
    func emptyTextGivesAnEmptyExcerpt() {
        #expect(GlobalSearchSnippet.excerpt(text: "", tokens: ["token"]).isEmpty)
    }
}
