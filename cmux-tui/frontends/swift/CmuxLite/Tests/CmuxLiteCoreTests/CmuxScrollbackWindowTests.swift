@testable import CmuxLiteCore
import Testing

@Suite
struct CmuxScrollbackWindowTests {
    @Test
    func newestPageLoadsFirstAndOlderPagesLoadOnDemand() {
        let empty = CmuxScrollbackWindow(total: 300, pageSize: 100, maxRows: 250)
        #expect(empty.latestRequest == CmuxScrollbackRequest(start: 200, count: 100))

        let latest = empty.merging(page(start: 200, total: 300, count: 100))
        #expect(latest.previousRequest == CmuxScrollbackRequest(start: 100, count: 100))
    }

    @Test
    func relativeResponseRowsBecomeSortedAbsoluteIndexes() {
        let merged = CmuxScrollbackWindow(total: 20, pageSize: 10, maxRows: 20).merging(
            CmuxReadScrollbackResponse(
                rows: [row(2, "twelve"), row(0, "ten")],
                start: 10,
                total: 20
            )
        )

        #expect(merged.rows.map(\.row) == [10, 12])
        #expect(merged.rows.map(\.text) == ["ten", "twelve"])
    }

    @Test
    func cacheStaysBoundedWhenOlderPagesArePrepended() {
        let initial = CmuxScrollbackWindow(total: 400, pageSize: 100, maxRows: 150)
        let latest = initial.merging(page(start: 300, total: 400, count: 100))
        let prepended = latest.merging(page(start: 200, total: 400, count: 100))

        #expect(prepended.rows.count == 150)
        #expect(prepended.rows.first?.row == 200)
        #expect(prepended.rows.last?.row == 349)
        #expect(latest.anchorDelta(to: prepended, direction: .previous) == 100)
    }

    @Test
    func growthKeepsCachedRowsAndPosition() {
        let cached = CmuxScrollbackWindow(total: 300, pageSize: 100, maxRows: 250)
            .merging(page(start: 200, total: 300, count: 100))
        let reconciled = cached.reconciling(previousTotal: 300, nextTotal: 340, resized: false)

        #expect(!reconciled.invalidated)
        #expect(reconciled.window.rows == cached.rows)
        #expect(reconciled.window.total == 340)
        #expect(cached.anchorDelta(to: reconciled.window, direction: .previous) == 0)
        #expect(reconciled.window.nextRequest == CmuxScrollbackRequest(start: 300, count: 40))
    }

    @Test
    func shrinkAndResizeInvalidateAbsoluteIndexes() {
        let cached = CmuxScrollbackWindow(total: 300, pageSize: 100, maxRows: 250)
            .merging(page(start: 200, total: 300, count: 100))
        let shrunk = cached.reconciling(previousTotal: 300, nextTotal: 25, resized: false)
        let resized = cached.reconciling(previousTotal: 300, nextTotal: 300, resized: true)

        #expect(shrunk.invalidated)
        #expect(shrunk.window.rows.isEmpty)
        #expect(shrunk.window.latestRequest == CmuxScrollbackRequest(start: 0, count: 25))
        #expect(resized.invalidated)
        #expect(resized.window.rows.isEmpty)
    }

    @Test
    func newerPagesReachTheLiveBoundaryAfterPrependEviction() {
        var cached = CmuxScrollbackWindow(total: 1_024, pageSize: 128, maxRows: 512)
        for start: UInt32 in [896, 768, 640, 512, 384, 256, 128, 0] {
            cached = cached.merging(page(start: start, total: 1_024, count: 128))
        }
        #expect(cached.rows.first?.row == 0)
        #expect(cached.rows.last?.row == 511)

        var newerPages = 0
        while let request = cached.nextRequest {
            let newer = cached.merging(page(
                start: request.start,
                total: 1_024,
                count: Int(request.count)
            ))
            #expect(cached.anchorDelta(to: newer, direction: .next) == -128)
            cached = newer
            newerPages += 1
        }

        #expect(newerPages == 4)
        #expect(cached.rows.first?.row == 512)
        #expect(cached.rows.last?.row == 1_023)
    }

    private func page(start: UInt32, total: UInt32, count: Int) -> CmuxReadScrollbackResponse {
        CmuxReadScrollbackResponse(
            rows: (0..<count).map { row($0, String(Int(start) + $0)) },
            start: start,
            total: total
        )
    }

    private func row(_ relative: Int, _ text: String) -> CmuxRenderRow {
        CmuxRenderRow(row: relative, runs: [CmuxRenderRun(
            text: text,
            foreground: nil,
            background: nil,
            attributes: []
        )])
    }
}
