import Foundation
import Testing
@testable import CmuxNative

struct MarkdownHTMLTests {
    @Test func inlineCodeIsRestored() {
        let html = MarkdownHTML.inline("Kept `-terminal.scrollSync` and `a<b` for **comparison**")
        #expect(html == "Kept <code>-terminal.scrollSync</code> and <code>a&lt;b</code> for <strong>comparison</strong>")
        #expect(!html.contains("\u{1}"))
    }

    @Test func codeSpansAreNotStyled() {
        #expect(MarkdownHTML.inline("`**not bold**`") == "<code>**not bold**</code>")
    }

    @Test func listsTablesAndFencesRender() {
        let html = MarkdownHTML.render("""
        - one
        - two

        | A | B |
        | --- | --- |
        | 1 | 2 |

        ```swift
        let x = 1
        ```
        """)
        #expect(html.contains("<ul><li>one</li><li>two</li></ul>"))
        #expect(html.contains("<td>1</td><td>2</td>"))
        #expect(html.contains("<pre><code>let x = 1</code></pre>"))
    }

    @Test func estimateGrowsWithText() {
        #expect(MarkdownHeightCache.estimate(for: "short") < MarkdownHeightCache.estimate(for: String(repeating: "long line ", count: 40)))
    }
}
