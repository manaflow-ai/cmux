@testable import CmuxLiteCore
import Foundation
import Testing

@Suite
struct CmuxAttachEventTests {
    @Test
    func decodesRenderStateWithStyledRuns() throws {
        let json = Data(##"{"event":"render-state","surface":7,"size":{"cols":3,"rows":1},"cursor":{"x":2,"y":0,"style":"block","blink":true,"visible":true,"color":null},"default_fg":"#eeeeee","default_bg":"#111111","scrollback_rows":42,"rows":[{"row":0,"runs":[{"text":"$ ","fg":null,"bg":null,"attrs":0},{"text":"x","fg":"#ff0000","bg":null,"attrs":1,"underline":"curly","width_hint":1}]}]}"##.utf8)

        let event = try JSONDecoder().decode(CmuxAttachEvent.self, from: json)
        guard case let .renderState(state) = event else {
            Issue.record("expected render-state")
            return
        }
        #expect(state.surface == 7)
        #expect(state.size == CmuxSurfaceSize(cols: 3, rows: 1))
        #expect(state.cursor.x == 2)
        #expect(state.scrollbackRows == 42)
        #expect(state.rows[0].runs[1].underline == .curly)
        #expect(state.rows[0].runs[1].widthHint == 1)
    }

    @Test
    func decodesCursorOnlyRenderDelta() throws {
        let json = Data(##"{"event":"render-delta","surface":7,"cursor":{"x":1,"y":0,"style":"bar","blink":false,"visible":true,"color":"#abcdef"},"full":false,"rows":[]}"##.utf8)
        let event = try JSONDecoder().decode(CmuxAttachEvent.self, from: json)

        guard case let .renderDelta(delta) = event else {
            Issue.record("expected render-delta")
            return
        }
        #expect(delta.rows.isEmpty)
        #expect(delta.cursor.style == .bar)
        #expect(delta.cursor.color == "#abcdef")
        #expect(delta.size == nil)
    }
}
