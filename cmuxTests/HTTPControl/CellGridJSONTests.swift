import CmuxTerminalAccess
import Foundation
import Testing
@testable import cmux

@Suite struct CellGridJSONTests {
    @Test func encodesWideSpacerSemanticHyperlinkUnderline() throws {
        let g = CellGrid(
            cols: 4,
            rows: 1,
            altScreen: false,
            title: "t",
            cursor: CursorState(row: 0, col: 0, visible: true, style: .block),
            semanticAvailable: true,
            rowsData: [
                CellRow(
                    wrap: false,
                    wrapContinuation: false,
                    cells: [
                        Cell(
                            t: "a",
                            wide: .narrow,
                            fg: .default,
                            bg: .default,
                            attrs: [.bold],
                            underlineKind: nil,
                            underlineColor: nil,
                            hyperlink: nil,
                            semantic: .input
                        ),
                        Cell(
                            t: "\u{4E16}",
                            wide: .wide,
                            fg: .default,
                            bg: .default,
                            attrs: [],
                            underlineKind: .curly,
                            underlineColor: .rgb(r: 10, g: 20, b: 30),
                            hyperlink: nil,
                            semantic: nil
                        ),
                        Cell(
                            t: "",
                            wide: .spacerTail,
                            fg: .default,
                            bg: .default,
                            attrs: [],
                            underlineKind: nil,
                            underlineColor: nil,
                            hyperlink: nil,
                            semantic: nil
                        ),
                        Cell(
                            t: " ",
                            wide: .narrow,
                            fg: .rgb(r: 1, g: 2, b: 3),
                            bg: .palette(7),
                            attrs: [],
                            underlineKind: nil,
                            underlineColor: nil,
                            hyperlink: "https://example/",
                            semantic: nil
                        ),
                    ]
                )
            ]
        )
        let json = CellGridJSON.encode(g, region: "viewport")
        let data = try JSONSerialization.data(
            withJSONObject: json,
            options: [.sortedKeys]
        )
        let s = String(data: data, encoding: .utf8) ?? ""
        #expect(s.contains("\"format\":\"cells\""))
        #expect(s.contains("\"semantic_available\":true"))
        #expect(s.contains("\"wide\":\"wide\""))
        #expect(s.contains("\"wide\":\"spacer_tail\""))
        #expect(s.contains("\"underline_kind\":\"curly\""))
        #expect(s.contains("\"underline_color\":\"#0A141E\""))
        #expect(s.contains("\"hyperlink\":\"https:\\/\\/example\\/\""))
        #expect(s.contains("\"attrs\":[\"bold\"]"))
        #expect(s.contains("#010203"))
    }
}
