/// What a line ends inside, carried to the next line.
public enum SyntaxLineState: Hashable, Sendable {
    case normal
    case blockComment
    /// Inside a multi-line string closed by `delimiter`.
    case string(delimiter: String)
}
