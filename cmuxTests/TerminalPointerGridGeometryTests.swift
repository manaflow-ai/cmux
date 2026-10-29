import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Terminal pointer grid geometry")
struct TerminalPointerGridGeometryTests {
    /// A 61-row split on a 2x display: Ghostty reports 16x34 backing-pixel
    /// cells, which are 8x17 points.
    private func retinaSplit() throws -> TerminalPointerGridGeometry {
        try #require(
            TerminalPointerGridGeometry(
                columns: 100,
                rows: 61,
                cellWidth: 8,
                cellHeight: 17,
                paddingLeft: 4,
                paddingTop: 2,
                viewHeight: 1041
            )
        )
    }

    @Test func pointerOnRowTwentyNineResolvesRowTwentyNineNotFourteen() throws {
        let geometry = try retinaSplit()
        // Middle of row 29, column 6, as AppKit reports a mouse location.
        let yFromTop: CGFloat = 2 + 29 * 17 + 8.5
        let point = CGPoint(x: 4 + 6 * 8 + 4, y: 1041 - yFromTop)

        let cell = geometry.cell(at: point)

        #expect(cell.row == 29)
        #expect(cell.column == 6)
    }

    @Test func cellBoundariesBelongToTheCellBelowAndRight() throws {
        let geometry = try retinaSplit()
        let point = CGPoint(x: 4 + 10 * 8, y: 1041 - (2 + 3 * 17))

        let cell = geometry.cell(at: point)

        #expect(cell.row == 3)
        #expect(cell.column == 10)
    }

    @Test func pointsInPaddingAndOutsideTheGridClamp() throws {
        let geometry = try retinaSplit()

        let topLeftPadding = geometry.cell(at: CGPoint(x: 1, y: 1040))
        #expect(topLeftPadding.row == 0)
        #expect(topLeftPadding.column == 0)

        let pastBottomRight = geometry.cell(at: CGPoint(x: 5000, y: -50))
        #expect(pastBottomRight.row == 60)
        #expect(pastBottomRight.column == 99)
    }

    @Test func cellCenterMapsBackToTheSameCell() throws {
        let geometry = try retinaSplit()

        for (row, column) in [(0, 0), (29, 6), (60, 99), (17, 42)] {
            let center = geometry.cellCenterFromTop(row: row, column: column)
            let cell = geometry.cell(at: CGPoint(x: center.x, y: 1041 - center.yFromTop))
            #expect(cell.row == row)
            #expect(cell.column == column)
        }
    }

    @Test func rejectsUnusableMetrics() {
        #expect(
            TerminalPointerGridGeometry(
                columns: 80, rows: 24, cellWidth: 0, cellHeight: 17,
                paddingLeft: 0, paddingTop: 0, viewHeight: 400
            ) == nil
        )
        #expect(
            TerminalPointerGridGeometry(
                columns: 0, rows: 24, cellWidth: 8, cellHeight: 17,
                paddingLeft: 0, paddingTop: 0, viewHeight: 400
            ) == nil
        )
        #expect(
            TerminalPointerGridGeometry(
                columns: 80, rows: 24, cellWidth: 8, cellHeight: .nan,
                paddingLeft: 0, paddingTop: 0, viewHeight: 400
            ) == nil
        )
    }
}
