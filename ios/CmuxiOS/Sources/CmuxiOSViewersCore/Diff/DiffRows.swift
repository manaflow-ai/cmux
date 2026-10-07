/// A document laid out as rows, with the row of every hunk header so the
/// viewer can jump between hunks.
public struct DiffRows: Hashable, Sendable {
    public var rows: [DiffRow]
    /// Row indices of the hunk headers, ascending.
    public var hunkRows: [Int]

    public init(_ document: DiffDocument, layout: DiffLayout) {
        var rows: [DiffRow] = []
        var hunkRows: [Int] = []
        for (index, hunk) in document.hunks.enumerated() {
            hunkRows.append(rows.count)
            rows.append(.hunk(index: index, header: hunk.header, section: hunk.section))
            switch layout {
            case .unified: rows.append(contentsOf: hunk.lines.map(DiffRow.line))
            case .split: rows.append(contentsOf: Self.paired(hunk.lines))
            }
        }
        self.rows = rows
        self.hunkRows = hunkRows
    }

    /// Context lines sit on both sides; a run of removals and the additions
    /// that follow it share rows pairwise, the longer side continuing alone.
    static func paired(_ lines: [DiffLine]) -> [DiffRow] {
        var rows: [DiffRow] = []
        var removals: [DiffLine] = []
        var additions: [DiffLine] = []
        func flush() {
            for offset in 0..<max(removals.count, additions.count) {
                rows.append(.split(old: offset < removals.count ? removals[offset] : nil,
                                   new: offset < additions.count ? additions[offset] : nil))
            }
            removals.removeAll()
            additions.removeAll()
        }
        for line in lines {
            switch line.kind {
            case .removal:
                if !additions.isEmpty { flush() }
                removals.append(line)
            case .addition:
                additions.append(line)
            case .context:
                flush()
                rows.append(.split(old: line, new: line))
            case .noNewlineMarker:
                flush()
                rows.append(.split(old: line, new: nil))
            }
        }
        flush()
        return rows
    }

    /// The first hunk header after `row`, nil past the last.
    public func nextHunk(after row: Int) -> Int? {
        hunkRows.first { $0 > row }
    }

    /// The last hunk header before `row`, nil before the first.
    public func previousHunk(before row: Int) -> Int? {
        hunkRows.last { $0 < row }
    }
}
