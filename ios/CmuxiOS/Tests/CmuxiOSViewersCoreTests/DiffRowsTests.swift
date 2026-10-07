import CmuxiOSViewersCore
import Testing

@Suite struct DiffRowsTests {
    let document = UnifiedDiffParser().parse("""
    @@ -1,4 +1,4 @@
     a
    -b
    -c
    +B
     d
    @@ -10,2 +10,3 @@
     x
    +y
    +z
    """)

    @Test func unifiedRowsKeepEveryLineAndMarkHunks() {
        let rows = DiffRows(document, layout: .unified)
        #expect(rows.rows.count == 2 + 5 + 3)
        #expect(rows.hunkRows == [0, 6])
        guard case .hunk(let index, _, _) = rows.rows[6] else {
            Issue.record("row 6 is not a hunk")
            return
        }
        #expect(index == 1)
    }

    @Test func splitRowsPairRemovalsWithAdditions() {
        let rows = DiffRows(document, layout: .split)
        let firstHunk = Array(rows.rows[1..<4])
        #expect(firstHunk == [
            .split(old: document.hunks[0].lines[0], new: document.hunks[0].lines[0]),
            .split(old: document.hunks[0].lines[1], new: document.hunks[0].lines[3]),
            .split(old: document.hunks[0].lines[2], new: nil),
        ])
        #expect(rows.rows[4] == .split(old: document.hunks[0].lines[4], new: document.hunks[0].lines[4]))
        // Additions with no removal before them stand alone on the right.
        #expect(rows.rows.last == .split(old: nil, new: document.hunks[1].lines[2]))
    }

    @Test func jumpsBetweenHunks() {
        let rows = DiffRows(document, layout: .unified)
        #expect(rows.nextHunk(after: 0) == 6)
        #expect(rows.nextHunk(after: 6) == nil)
        #expect(rows.previousHunk(before: 8) == 6)
        #expect(rows.previousHunk(before: 6) == 0)
        #expect(rows.previousHunk(before: 0) == nil)
    }
}
