import CoreGraphics
import Testing
@testable import CnxTerminal

/// Verifier defect V2-3 (VERIFY-round2.md, T-LIFE-09): a link drop while
/// reading brought the page back at the live bottom. The reattach's replay
/// rebuilds the scrollback, so the reader's rows are found again by their
/// text, nearest to where they were counted from the end.
@Suite struct TerminalReadingMarkTests {
    private func history(_ count: Int, prefix: String = "line") -> [String] {
        (0..<count).map { "\(prefix) \($0)" }
    }

    private func mark(in rows: [String], at row: Int) -> TerminalReadingMark? {
        TerminalReadingMark(anchor: .init(row: row, delta: 5), totalRows: rows.count) { rows.indices.contains($0) ? rows[$0] : nil }
    }

    private func locate(_ mark: TerminalReadingMark, in rows: [String]) -> TerminalScrollModel.Anchor? {
        mark.locate(totalRows: rows.count) { rows.indices.contains($0) ? rows[$0] : nil }
    }

    @Test func theSameHistoryKeepsTheSameRow() throws {
        let rows = history(500)
        let m = try #require(mark(in: rows, at: 200))
        #expect(locate(m, in: rows) == .init(row: 200, delta: 5))
    }

    @Test func outputDuringTheDropKeepsTheReadersRows() throws {
        let before = history(500)
        let m = try #require(mark(in: before, at: 200))
        // 40 new rows arrived while the link was down.
        let after = history(540)
        #expect(locate(m, in: after) == .init(row: 200, delta: 5))
    }

    @Test func aShorterReplayFindsTheRowsByText() throws {
        // The Mac's history starts later than the phone's did (V2-5): the
        // same rows sit 300 rows higher in the replay.
        let before = history(500)
        let m = try #require(mark(in: before, at: 400))
        let after = Array(before.dropFirst(300))
        #expect(locate(m, in: after) == .init(row: 100, delta: 5))
    }

    @Test func repeatedLinesPickTheNearestMatch() throws {
        var rows = Array(repeating: "same", count: 600)
        for i in stride(from: 0, to: 600, by: 7) { rows[i] = "mark \(i % 3)" }
        let m = try #require(mark(in: rows, at: 301))
        #expect(locate(m, in: rows)?.row == 301)
    }

    @Test func goneRowsFallBackToTheDistanceFromTheEnd() throws {
        let m = try #require(mark(in: history(500), at: 450))
        let after = history(500, prefix: "other")
        #expect(locate(m, in: after) == .init(row: 450, delta: 5))
    }

    @Test func blankRowsAloneAreNoMark() {
        let rows = Array(repeating: "", count: 100)
        #expect(mark(in: rows, at: 50) == nil)
    }

    /// Verifier V2-3 (round 3): once the replay's row count differed from the
    /// phone's, 5 of 5 read-drops lost the place: one changed row among the six
    /// read (a line the replay serializes differently, a redrawn status row)
    /// and the exact match failed, falling back to the distance from the end.
    /// The rows read and their neighbours vote; a few changed rows do not lose
    /// the place.
    @Test func aChangedRowAmongTheReadRowsStillFindsThem() throws {
        let before = history(1118)
        let m = try #require(mark(in: before, at: 835))
        // The Mac's history starts 120 rows later and grew 220 rows; one row
        // just below the anchor reads differently in the replay.
        var after = Array(before.dropFirst(120)) + history(220, prefix: "new")
        after[835 - 120 + 2] = "line 837 (redrawn)"
        #expect(locate(m, in: after)?.row == 835 - 120)
    }

    /// Rows read that are blank at the anchor are found by their neighbours.
    @Test func blankRowsUnderTheAnchorAreFoundByTheirNeighbours() throws {
        var before = history(600)
        for row in 300..<310 { before[row] = "" }
        let m = try #require(mark(in: before, at: 300))
        let after = Array(before.dropFirst(50)) + history(80, prefix: "new")
        #expect(locate(m, in: after)?.row == 250)
    }
}
