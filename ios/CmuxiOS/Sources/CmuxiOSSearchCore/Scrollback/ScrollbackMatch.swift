/// One scrollback line that matched, escapes stripped.
public struct ScrollbackMatch: Hashable, Sendable {
    public var line: String
    /// Lines above the bottom of the screen (0 is the last line).
    public var lineFromBottom: Int
    /// Character ranges of `line` to highlight.
    public var ranges: [Range<Int>]

    public init(line: String, lineFromBottom: Int, ranges: [Range<Int>]) {
        self.line = line
        self.lineFromBottom = lineFromBottom
        self.ranges = ranges
    }
}
