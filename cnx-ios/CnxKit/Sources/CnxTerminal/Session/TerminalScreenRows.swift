import Foundation

/// Every row of the screen (scrollback and active area) as text, numbered
/// like the scrollbar (`TerminalAbsoluteRow`: 0 = the oldest kept row), with
/// each row's soft wrap. Built from two whole-screen reads Ghostty does not
/// clamp (round 8: an exact screen point's y is clamped to the grid's last
/// row, so rows past the first `grid.rows` cannot be addressed one by one):
/// a rectangle read (one line per row, wraps not joined) and the plain read
/// (soft-wrapped rows joined into one line). A copy of rows anywhere in the
/// scrollback joins rows only at soft wraps (G-14, T-SEL-01).
public struct TerminalScreenRows: Equatable, Sendable {
    /// Row text, trailing blanks trimmed (as Ghostty formats it).
    public private(set) var rows: [String]
    /// `wraps[i]`: row i continues on row i + 1 (a soft wrap).
    public private(set) var wraps: [Bool]

    public init(rectangle: String, logical: String, columns: Int) {
        rows = rectangle.split(separator: "\n", omittingEmptySubsequences: false).map(Self.trimmed)
        wraps = Array(repeating: false, count: rows.count)
        let lines = logical.split(separator: "\n", omittingEmptySubsequences: false).map(Self.trimmed)
        // Align each logical line with the rows it spans. A row continues
        // when the line goes on past it: as read, or (a row that ended in
        // blanks, which the rectangle trims) padded to the grid's width.
        let width = max(1, columns)
        var r = 0
        for line in lines {
            // Where the next row starts in the line (linear: a 1 MB line is
            // thousands of rows).
            var cursor = line.startIndex
            while r < rows.count {
                let row = rows[r]
                let padded = row.count < width ? row + String(repeating: " ", count: width - row.count) : row
                r += 1
                guard r < rows.count else { break }
                let rest = line[cursor...]
                // The line goes on past this row: as padded (its trimmed
                // blanks were text) or as read (wide characters: fewer
                // characters than cells).
                if rest.hasPrefix(padded), let next = line.index(cursor, offsetBy: padded.count, limitedBy: line.endIndex),
                   next < line.endIndex {
                    rows[r - 1] = padded
                    wraps[r - 1] = true
                    cursor = next
                } else if rest.hasPrefix(row), let next = line.index(cursor, offsetBy: row.count, limitedBy: line.endIndex),
                          next < line.endIndex {
                    wraps[r - 1] = true
                    cursor = next
                } else {
                    break
                }
            }
        }
    }

    /// The text as lines: soft-wrapped rows joined, one line per hard line
    /// (the rig's text export, G-09).
    public var logicalText: String {
        var out = ""
        for (index, row) in rows.enumerated() {
            out += row
            if !wraps[index] { out += "\n" }
        }
        return out
    }

    private static func trimmed(_ line: Substring) -> String {
        var line = line
        while let last = line.last, last == " " || last == "\r" { line = line.dropLast() }
        return String(line)
    }

    public var count: Int { rows.count }

    /// Text from `start` to `end` (inclusive cells), joined at soft wraps
    /// only; nil when `start` is past the rows read.
    public func text(from start: TerminalCellPoint, to end: TerminalCellPoint) -> String? {
        guard start.row >= 0, start.row < rows.count, end >= start else { return nil }
        let last = min(end.row, rows.count - 1)
        var text = ""
        for row in start.row...last {
            let cells = Array(rows[row])
            let lower = row == start.row ? min(start.column, cells.count) : 0
            let upper = row == end.row ? min(end.column + 1, cells.count) : cells.count
            text += String(cells[lower..<max(lower, upper)])
            if row < last, !wraps[row] { text += "\n" }
        }
        return text
    }
}
