@testable import CmuxLiteCore
import Testing

@Suite
struct CmuxRenderModelTests {
    @Test
    func dirtyRowsReplaceByIndexRegardlessOfEventOrder() {
        let initial = CmuxRenderModel.applySnapshot(snapshot(rows: [row(1, "two"), row(0, "one")]))
        let updated = initial.applyDelta(delta(rows: [row(1, "TWO"), row(0, "ONE")]))

        #expect(initial.rows.map(\.text) == ["one", "two"])
        #expect(updated.rows.map(\.text) == ["ONE", "TWO"])
    }

    @Test
    func resizeIsAFullViewportReplacement() {
        let initial = CmuxRenderModel.applySnapshot(snapshot())
        let resized = initial.applyDelta(delta(
            full: true,
            size: CmuxSurfaceSize(cols: 4, rows: 3),
            scrollbackRows: 20,
            rows: [row(2, "new2"), row(0, "new0"), row(1, "new1")]
        ))

        #expect(resized.size == CmuxSurfaceSize(cols: 4, rows: 3))
        #expect(resized.rows.map(\.text) == ["new0", "new1", "new2"])
        #expect(resized.scrollbackRows == 20)
    }

    @Test
    func cursorOnlyDeltaLeavesRowsUnchanged() {
        let initial = CmuxRenderModel.applySnapshot(snapshot())
        let cursor = CmuxRenderCursor(
            x: 2,
            y: 1,
            style: .bar,
            blink: false,
            visible: false,
            color: nil
        )
        let updated = initial.applyDelta(delta(cursor: cursor, defaultBackground: "#222222"))

        #expect(updated.rows == initial.rows)
        #expect(updated.cursor == cursor)
        #expect(updated.defaultBackground == "#222222")
    }

    @Test
    func outOfRangeRowsAreClampedOutAndStaleSurfacesAreIgnored() {
        let initial = CmuxRenderModel.applySnapshot(snapshot(rows: [
            row(-1, "bad"), row(8, "bad"), row(1, "two"), row(0, "one"),
        ]))
        let invalid = initial.applyDelta(delta(rows: [row(-1, "bad"), row(8, "bad")]))
        let stale = initial.applyDelta(delta(surface: 99, rows: [row(0, "stale")]))

        #expect(initial.rows.map(\.text) == ["one", "two"])
        #expect(invalid.rows == initial.rows)
        #expect(stale == initial)
    }

    @Test
    func fullRepaintWithoutResizeClearsMissingRows() {
        let initial = CmuxRenderModel.applySnapshot(snapshot())
        let replaced = initial.applyDelta(delta(full: true, rows: [row(0, "new")]))

        #expect(replaced.rows.map(\.text) == ["new", ""])
    }

    private func snapshot(rows: [CmuxRenderRow]? = nil) -> CmuxRenderStateEvent {
        CmuxRenderStateEvent(
            surface: 7,
            size: CmuxSurfaceSize(cols: 3, rows: 2),
            cursor: cursor(),
            defaultForeground: "#eeeeee",
            defaultBackground: "#111111",
            scrollbackRows: 12,
            rows: rows ?? [row(0, "one"), row(1, "two")]
        )
    }

    private func delta(
        surface: UInt64 = 7,
        cursor: CmuxRenderCursor? = nil,
        full: Bool = false,
        size: CmuxSurfaceSize? = nil,
        defaultBackground: String? = nil,
        scrollbackRows: UInt32? = nil,
        rows: [CmuxRenderRow] = []
    ) -> CmuxRenderDeltaEvent {
        CmuxRenderDeltaEvent(
            surface: surface,
            cursor: cursor ?? self.cursor(),
            full: full,
            size: size,
            defaultBackground: defaultBackground,
            scrollbackRows: scrollbackRows,
            rows: rows
        )
    }

    private func cursor() -> CmuxRenderCursor {
        CmuxRenderCursor(x: 1, y: 0, style: .block, blink: true, visible: true, color: nil)
    }

    private func row(_ index: Int, _ text: String) -> CmuxRenderRow {
        CmuxRenderRow(row: index, runs: [CmuxRenderRun(
            text: text,
            foreground: nil,
            background: nil,
            attributes: []
        )])
    }
}
