/// A pipe table.
public struct MarkdownTable: Hashable, Sendable {
    public enum Alignment: Hashable, Sendable {
        case leading
        case center
        case trailing
    }

    public var header: [String]
    public var alignments: [Alignment]
    /// Every row has `header.count` cells (padded or cut).
    public var rows: [[String]]

    public init(header: [String], alignments: [Alignment], rows: [[String]]) {
        self.header = header
        self.alignments = alignments
        self.rows = rows
    }
}
