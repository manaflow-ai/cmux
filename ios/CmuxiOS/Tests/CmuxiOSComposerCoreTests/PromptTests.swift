import CmuxiOSComposerCore
import Foundation
import Testing

@Suite("prompt tokens")
struct PromptTests {
    @Test func slashTriggersOnlyAtALineStart() {
        let trigger = PromptTrigger(text: "/rev", cursor: 4)
        #expect(trigger == PromptTrigger(kind: .template, range: NSRange(location: 0, length: 4), query: "rev"))
        #expect(PromptTrigger(text: "line\n/fi", cursor: 8)?.kind == .template)
        #expect(PromptTrigger(text: "a/b", cursor: 3) == nil)
        #expect(PromptTrigger(text: "/rev more", cursor: 9) == nil)
    }

    @Test func mentionsTriggerAfterWhitespace() {
        let text = "look at @Sources/Ap"
        let trigger = PromptTrigger(text: text, cursor: (text as NSString).length)
        #expect(trigger?.kind == .mention)
        #expect(trigger?.query == "Sources/Ap")
        #expect(PromptTrigger(text: "mail@host", cursor: 9) == nil)
    }

    @Test func applyingReplacesTheTriggerAndMovesTheCursor() throws {
        let text = "please @Sou"
        let trigger = try #require(PromptTrigger(text: text, cursor: (text as NSString).length))
        let applied = trigger.applying("@Sources/App.swift ", to: text)
        #expect(applied.text == "please @Sources/App.swift ")
        #expect(applied.cursor == (applied.text as NSString).length)
    }

    @Test func stylerFindsMarkdownLiteSpans() {
        let text = "# Goal\n- fix **sizing** in `Grid.swift` for @alice\n2. ship"
        let runs = PromptStyler(text).runs
        let kinds = runs.map(\.kind)
        #expect(kinds.contains(.heading))
        #expect(kinds.filter { $0 == .bullet }.count == 2)
        let source = text as NSString
        #expect(runs.first { $0.kind == .bold }.map { source.substring(with: $0.range) } == "**sizing**")
        #expect(runs.first { $0.kind == .code }.map { source.substring(with: $0.range) } == "`Grid.swift`")
        #expect(runs.first { $0.kind == .mention }.map { source.substring(with: $0.range) } == "@alice")
        #expect(runs.first { $0.kind == .heading }.map { source.substring(with: $0.range) } == "# Goal")
        #expect(PromptStyler("").runs.isEmpty)
    }
}
