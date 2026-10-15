import CoreGraphics

/// Where the reader was before a mirror reset, so the reset's replay can put
/// them back (verifier V2-3, T-LIFE-09: a link drop while reading brought the
/// page back at the live bottom).
///
/// The replay rebuilds the scrollback from the Mac's history, which need not
/// match the phone's row for row (output during the drop appends; the Mac's
/// history can start later than the phone's did). So the anchored row is
/// found again by content, not by index:
/// 1. the anchor's own rows, exactly, at the same row and then nearest-first
///    around the row the same distance from the end;
/// 2. else every row read (the screen around the anchor, neighbours above
///    included) votes for where the window starts in the replay; the best
///    supported start wins, so a few rows that read differently in the replay
///    (a redrawn status row, a line serialized another way) or blank rows at
///    the anchor do not lose the place (round 3: 5 of 5 read-drops lost it
///    once the row counts differed);
/// 3. else the same distance from the end.
struct TerminalReadingMark: Equatable {
    /// The rows read, from `rowsBefore` rows above the anchor down (text,
    /// trailing blanks trimmed).
    let rows: [String]
    /// The anchor's index in `rows`.
    let anchorIndex: Int
    let rowsFromEnd: Int
    /// The anchor's row as it was, and its pixel remainder.
    let row: Int
    let delta: CGFloat

    /// Rows of the exact match at the anchor.
    static let length = 6
    /// Neighbours kept above the anchor, and rows from the anchor down (a screen).
    static let rowsBefore = 8
    static let rowsAfter = 48
    /// How far from the expected row the text is searched (rows).
    static let searchRows = 2000
    /// A text that repeats more than this in the window does not vote.
    static let maxRepeats = 3

    /// Nil when the rows read are all blank (nothing to find them by) or
    /// cannot be read.
    init?(anchor: TerminalScrollModel.Anchor, totalRows: Int, rowText: (Int) -> String?) {
        guard anchor.row >= 0, anchor.row < totalRows else { return nil }
        let first = max(0, anchor.row - Self.rowsBefore)
        var rows: [String] = []
        for row in first..<min(totalRows, anchor.row + Self.rowsAfter) {
            guard let text = rowText(row) else { return nil }
            rows.append(Self.normalized(text))
        }
        guard rows.contains(where: { !$0.isEmpty }) else { return nil }
        self.rows = rows
        self.anchorIndex = anchor.row - first
        self.rowsFromEnd = totalRows - anchor.row
        self.row = anchor.row
        self.delta = anchor.delta
    }

    /// The anchor in a rebuilt scrollback of `totalRows` rows.
    func locate(totalRows: Int, rowText: (Int) -> String?) -> TerminalScrollModel.Anchor? {
        guard totalRows > 0 else { return nil }
        let byEnd = totalRows - rowsFromEnd
        var cache: [Int: String] = [:]
        func text(_ row: Int) -> String? {
            if let hit = cache[row] { return hit }
            let value = rowText(row).map(Self.normalized)
            if let value { cache[row] = value }
            return value
        }
        // 1. The anchor's rows, exactly (when they have text).
        let head = Array(rows[anchorIndex..<min(rows.count, anchorIndex + Self.length)])
        if head.contains(where: { !$0.isEmpty }) {
            func matches(_ start: Int) -> Bool {
                guard start >= 0, start + head.count <= totalRows else { return false }
                for (index, expected) in head.enumerated() where text(start + index) != expected { return false }
                return true
            }
            if matches(row) { return .init(row: row, delta: delta) }
            for distance in 0...Self.searchRows {
                for candidate in distance == 0 ? [byEnd] : [byEnd - distance, byEnd + distance] where matches(candidate) {
                    return .init(row: candidate, delta: delta)
                }
            }
        }
        // 2. Every distinctive row read votes for the window's start.
        var positions: [String: [Int]] = [:]
        for (index, value) in rows.enumerated() where !value.isEmpty { positions[value, default: []].append(index) }
        positions = positions.filter { $0.value.count <= Self.maxRepeats }
        let voters = positions.values.reduce(0) { $0 + $1.count }
        if voters > 0 {
            let expectedStart = byEnd - anchorIndex
            let low = max(0, expectedStart - Self.searchRows)
            let high = min(totalRows - 1, expectedStart + Self.searchRows + rows.count)
            var votes: [Int: Int] = [:]
            if low <= high {
                for row in low...high {
                    guard let value = text(row), let indices = positions[value] else { continue }
                    for index in indices { votes[row - index, default: 0] += 1 }
                }
            }
            let needed = max(2, Int((Double(voters) * 0.4).rounded(.up)))
            let best = votes.filter { $0.value >= needed }.max { a, b in
                a.value != b.value ? a.value < b.value : abs(a.key - expectedStart) > abs(b.key - expectedStart)
            }
            if let best {
                let anchor = min(max(0, best.key + anchorIndex), totalRows - 1)
                return .init(row: anchor, delta: delta)
            }
        }
        // 3. The same distance from the end.
        let fallback = min(max(0, byEnd), totalRows - 1)
        return .init(row: fallback, delta: delta)
    }

    private static func normalized(_ text: String) -> String {
        var trimmed = Substring(text)
        while let last = trimmed.last, last == " " || last == "\n" || last == "\r" || last == "\t" { trimmed = trimmed.dropLast() }
        return String(trimmed)
    }
}
