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
}
