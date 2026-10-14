@testable import CNAgentUI
import Testing

@Suite struct MarkdownPlainTextTests {
    let plain = MarkdownPlainText()

    @Test func codeFenceKeepsCodeOnly() {
        #expect(plain("```text\nv1c-out-42\n```") == "v1c-out-42")
        // A fence squeezed onto one line (as host previews arrive) is an inline code span.
        #expect(!plain("Updated `hello.txt` to: ```text hi there ```").contains("`"))
        #expect(plain("Updated `hello.txt` to:\n```text\nhi there\n```") == "Updated hello.txt to: hi there")
    }

    @Test func squeezedFenceDropsKnownLanguageOnly() {
        // Host previews fold newlines, so the fence lands on one line.
        #expect(plain("I'll run it. ```text v1c-out-42 ```") == "I'll run it. v1c-out-42")
        #expect(plain("Ran ```swift model.lastRefresh = .now ```") == "Ran model.lastRefresh = .now")
        // Not a language: the first word is kept.
        #expect(plain("Run ```npm test ``` now") == "Run npm test now")
    }

    @Test func emphasisLinksHeadingsAndLists() {
        #expect(plain("# Done\n**Root cause:** the _cache_ [never](https://example.com) evicts") == "Done Root cause: the cache never evicts")
        #expect(plain("- one\n- **two**\n1. three") == "one two three")
        #expect(plain("> quoted `code`") == "quoted code")
    }

    @Test func plainTextIsUnchangedAndWhitespaceCollapses() {
        #expect(plain("pong from the Mac") == "pong from the Mac")
        #expect(plain("a\n\n  b\tc") == "a b c")
    }

    @Test func tableBecomesWords() {
        #expect(plain("| Runs | After |\n| --- | --- |\n| 50 | 0 failures |") == "Runs After 50 0 failures")
    }
}
