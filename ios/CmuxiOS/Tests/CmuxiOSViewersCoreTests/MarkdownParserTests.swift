import CmuxiOSViewersCore
import Testing

@Suite struct MarkdownParserTests {
    @Test func headingsParagraphsAndBreaks() {
        let blocks = MarkdownParser().parse("""
        # Title #
        Some *text*
        continued  
        on a new line

        Setext
        ======
        ***
        ####### not a heading
        """)
        #expect(blocks == [
            .heading(level: 1, text: "Title"),
            .paragraph("Some *text* continued\non a new line"),
            .heading(level: 1, text: "Setext"),
            .thematicBreak,
            .paragraph("####### not a heading"),
        ])
    }

    @Test func fencedAndIndentedCode() {
        let blocks = MarkdownParser().parse("""
        ```swift title
        let x = 1
          indented
        ```
        text

            plain code
            more
        ~~~
        unterminated
        """)
        #expect(blocks == [
            .code(language: "swift", text: "let x = 1\n  indented"),
            .paragraph("text"),
            .code(language: nil, text: "plain code\nmore"),
            .code(language: nil, text: "unterminated"),
        ])
    }

    @Test func nestedListsWithTasks() {
        let document = MarkdownDocument(parsing: """
        - [x] done
        - [ ] open
          - [ ] nested
          - plain
        - item
          continued

        3. three
        4) four
        """)
        guard case .list(let list) = document.blocks.first else {
            Issue.record("no list: \(document.blocks)")
            return
        }
        #expect(!list.ordered && list.items.count == 3)
        #expect(list.items.map(\.isChecked) == [true, false, nil])
        #expect(list.items[0].blocks == [.paragraph("done")])
        #expect(list.items[2].blocks == [.paragraph("item continued")])
        guard case .list(let nested) = list.items[1].blocks.last else {
            Issue.record("no nested list: \(list.items[1].blocks)")
            return
        }
        #expect(nested.items.map(\.isChecked) == [false, nil])
        #expect(document.taskProgress == (1, 3))
        guard case .list(let ordered) = document.blocks.last else {
            Issue.record("no ordered list")
            return
        }
        #expect(ordered.ordered && ordered.start == 3 && ordered.items.count == 2)
    }

    @Test func tablesAndQuotes() {
        let blocks = MarkdownParser().parse("""
        | Layout | Width | n |
        | :----- | :---: | -: |
        | Unified | compact | 1 |
        | a \\| b |

        > quoted **bold**
        > - item
        """)
        #expect(blocks.first == .table(MarkdownTable(
            header: ["Layout", "Width", "n"], alignments: [.leading, .center, .trailing],
            rows: [["Unified", "compact", "1"], ["a | b", "", ""]])))
        #expect(blocks.last == .quote([.paragraph("quoted **bold**"), .list(MarkdownList(ordered: false, items: [
            MarkdownListItem(blocks: [.paragraph("item")]),
        ]))]))
    }

    @Test func aPipeWithoutADelimiterRowIsText() {
        #expect(MarkdownParser().parse("a | b\nc | d") == [.paragraph("a | b c | d")])
    }
}
