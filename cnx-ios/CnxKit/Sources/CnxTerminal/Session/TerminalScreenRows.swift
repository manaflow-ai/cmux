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
        rows = []
        wraps = []
    }

    public var count: Int { rows.count }

    /// Text from `start` to `end` (inclusive cells), joined at soft wraps
    /// only; nil when `start` is past the rows read.
    public func text(from start: TerminalCellPoint, to end: TerminalCellPoint) -> String? {
        nil
    }
}
