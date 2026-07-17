import Foundation

/// Maintains a bounded, absolute-indexed window over retained terminal scrollback.
public struct CmuxScrollbackWindow: Sendable, Equatable {
    /// The latest known retained-row count.
    public let total: UInt32

    /// The preferred protocol page size.
    public let pageSize: UInt32

    /// The maximum number of cached rows.
    public let maxRows: Int

    /// Sorted rows whose `row` fields are absolute retained-buffer indexes.
    public let rows: [CmuxRenderRow]

    /// Creates an empty bounded window.
    /// - Parameters:
    ///   - total: The latest retained-row count.
    ///   - pageSize: The preferred page size, clamped to at least one.
    ///   - maxRows: The cache bound, clamped to at least one.
    public init(total: UInt32, pageSize: UInt32 = 128, maxRows: Int = 512) {
        self.init(
            total: total,
            pageSize: max(1, pageSize),
            maxRows: max(1, maxRows),
            rows: []
        )
    }

    private init(total: UInt32, pageSize: UInt32, maxRows: Int, rows: [CmuxRenderRow]) {
        self.total = total
        self.pageSize = pageSize
        self.maxRows = maxRows
        self.rows = rows
    }

    /// Requests the newest page when the cache is empty.
    public var latestRequest: CmuxScrollbackRequest? {
        guard total > 0, rows.isEmpty else { return nil }
        let start = total > pageSize ? total - pageSize : 0
        return CmuxScrollbackRequest(start: start, count: total - start)
    }

    /// Requests the page immediately older than the cached window.
    public var previousRequest: CmuxScrollbackRequest? {
        guard let first = rows.first else { return latestRequest }
        let firstIndex = UInt32(clamping: first.row)
        guard firstIndex > 0 else { return nil }
        let start = firstIndex > pageSize ? firstIndex - pageSize : 0
        return CmuxScrollbackRequest(start: start, count: firstIndex - start)
    }

    /// Requests the page immediately newer than the cached window.
    public var nextRequest: CmuxScrollbackRequest? {
        guard let last = rows.last else { return latestRequest }
        let start = UInt32(clamping: last.row + 1)
        guard start < total else { return nil }
        return CmuxScrollbackRequest(start: start, count: min(pageSize, total - start))
    }

    /// Reconciles retained-row growth, shrink, or resize reflow.
    /// - Parameters:
    ///   - previousTotal: The prior model count.
    ///   - nextTotal: The next model count.
    ///   - resized: Whether the delta resized and reflowed the surface.
    /// - Returns: A retained cache for growth or an empty invalidated cache.
    public func reconciling(
        previousTotal: UInt32,
        nextTotal: UInt32,
        resized: Bool
    ) -> CmuxScrollbackReconciliation {
        if resized || nextTotal < previousTotal {
            return CmuxScrollbackReconciliation(
                window: Self(total: nextTotal, pageSize: pageSize, maxRows: maxRows),
                invalidated: true
            )
        }
        guard nextTotal > total else {
            return CmuxScrollbackReconciliation(window: self, invalidated: false)
        }
        return CmuxScrollbackReconciliation(
            window: Self(total: nextTotal, pageSize: pageSize, maxRows: maxRows, rows: rows),
            invalidated: false
        )
    }

    /// Merges a relative-indexed response into the absolute bounded cache.
    /// - Parameter page: One atomic server scrollback response.
    /// - Returns: A sorted, deduplicated, bounded window.
    public func merging(_ page: CmuxReadScrollbackResponse) -> Self {
        let existing = page.total < total ? [] : rows
        var byIndex = Dictionary(uniqueKeysWithValues: existing.map { ($0.row, $0) })
        for row in page.rows {
            let absolute = Int(page.start) + row.row
            guard absolute >= 0, absolute < Int(page.total) else { continue }
            byIndex[absolute] = CmuxRenderRow(row: absolute, runs: row.runs)
        }

        var merged = byIndex.values.sorted { $0.row < $1.row }
        if merged.count > maxRows {
            let prepended = existing.first.map { Int(page.start) < $0.row } ?? false
            merged = prepended ? Array(merged.prefix(maxRows)) : Array(merged.suffix(maxRows))
        }
        return Self(total: page.total, pageSize: pageSize, maxRows: maxRows, rows: merged)
    }

    /// Calculates the row offset needed to retain an edge anchor after a merge.
    /// - Parameters:
    ///   - next: The window after merging a page.
    ///   - direction: The edge whose row should remain visually stable.
    /// - Returns: The signed row-index adjustment for the viewport.
    public func anchorDelta(to next: Self, direction: CmuxScrollbackDirection) -> Int {
        guard !rows.isEmpty, !next.rows.isEmpty else { return 0 }
        let oldIndex = direction == .previous ? 0 : rows.count - 1
        let anchor = rows[oldIndex]
        guard let newIndex = next.rows.firstIndex(where: { $0.row == anchor.row }) else { return 0 }
        return newIndex - oldIndex
    }
}
