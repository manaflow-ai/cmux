import CoreGraphics

/// Where the reader was before a mirror reset, so the reset's replay can put
/// them back (verifier V2-3, T-LIFE-09: a link drop while reading brought the
/// page back at the live bottom).
///
/// The replay rebuilds the scrollback from the Mac's history, which need not
/// match the phone's row for row (output during the drop appends; the Mac's
/// history can start later than the phone's did). So the anchored row is
/// found again by the text of the rows from it down, searched nearest-first
/// around the row the same distance from the end; if the rows are gone, the
/// same distance from the end.
struct TerminalReadingMark: Equatable {
    /// The anchored row and the rows below it (text), up to the first
    /// `length` rows; blank rows match only blank rows.
    let rows: [String]
    let rowsFromEnd: Int
    /// The anchor's row as it was, and its pixel remainder.
    let row: Int
    let delta: CGFloat

    static let length = 6
    /// How far from the expected row the text is searched (rows).
    static let searchRows = 2000

    /// Nil when the rows read are all blank (nothing to find them by) or
    /// cannot be read.
    init?(anchor: TerminalScrollModel.Anchor, totalRows: Int, rowText: (Int) -> String?) {
        guard anchor.row >= 0, anchor.row < totalRows else { return nil }
        var rows: [String] = []
        for row in anchor.row..<min(totalRows, anchor.row + Self.length) {
            guard let text = rowText(row) else { return nil }
            rows.append(Self.normalized(text))
        }
        guard rows.contains(where: { !$0.isEmpty }) else { return nil }
        self.rows = rows
        self.rowsFromEnd = totalRows - anchor.row
        self.row = anchor.row
        self.delta = anchor.delta
    }

    /// The anchor in a rebuilt scrollback of `totalRows` rows.
    func locate(totalRows: Int, rowText: (Int) -> String?) -> TerminalScrollModel.Anchor? {
        guard totalRows > 0 else { return nil }
        // Output during the drop only appends: the same absolute row is the
        // likeliest; then nearest to the same distance from the end.
        let byEnd = totalRows - rowsFromEnd
        var cache: [Int: String] = [:]
        func text(_ row: Int) -> String? {
            if let hit = cache[row] { return hit }
            let value = rowText(row).map(Self.normalized)
            if let value { cache[row] = value }
            return value
        }
        func matches(_ start: Int) -> Bool {
            guard start >= 0, start + rows.count <= totalRows else { return false }
            for (index, expected) in rows.enumerated() where text(start + index) != expected { return false }
            return true
        }
        if matches(row) { return .init(row: row, delta: delta) }
        for distance in 0...Self.searchRows {
            for candidate in distance == 0 ? [byEnd] : [byEnd - distance, byEnd + distance] where matches(candidate) {
                return .init(row: candidate, delta: delta)
            }
        }
        let fallback = min(max(0, byEnd), totalRows - 1)
        return .init(row: fallback, delta: delta)
    }

    private static func normalized(_ text: String) -> String {
        var trimmed = Substring(text)
        while let last = trimmed.last, last == " " || last == "\n" || last == "\r" || last == "\t" { trimmed = trimmed.dropLast() }
        return String(trimmed)
    }
}
