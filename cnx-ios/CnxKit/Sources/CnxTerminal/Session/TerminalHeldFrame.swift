import Foundation

/// When the frame held over a resize's mirror reset is let go (design/terminal
/// R3-2, R4): not before the new screen has a meaningful amount of content.
/// A TUI's replay at a new size can be an empty or near-empty alternate
/// screen until the program repaints (macOS `top` waits for its 1 s tick), and
/// releasing earlier showed a black band for a quarter of a second. Capped,
/// so a screen that stays empty is shown as it is.
public struct TerminalHeldFrame: Sendable {
    /// Share of the rows that must have text on the alternate screen.
    public static let minimumShare = 0.3
    /// The longest a frame is held.
    public static let cap: TimeInterval = 1.5

    public init() {}

    /// `nonBlankRows` of `rows` have text (`isAlternate`: a TUI's screen).
    public func shouldRelease(isAlternate: Bool, nonBlankRows: Int, rows: Int, elapsed: TimeInterval) -> Bool {
        if elapsed >= Self.cap { return true }
        guard isAlternate else { return nonBlankRows > 0 || rows == 0 }
        guard rows > 0 else { return true }
        return Double(nonBlankRows) >= max(1, Double(rows) * Self.minimumShare)
    }

    /// Rows with text in Ghostty's plain text of a screen (one line per row;
    /// soft-wrapped rows joined count once, which only errs toward holding).
    public static func nonBlankRows(in text: String, limit: Int) -> Int {
        var count = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(limit)
            where line.contains(where: { !$0.isWhitespace }) {
            count += 1
        }
        return count
    }
}
