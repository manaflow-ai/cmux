/// A parsed patch of one file.
public struct DiffDocument: Hashable, Sendable {
    public var hunks: [DiffHunk]
    /// The Mac cut the patch at its byte budget.
    public var isTruncated: Bool
    public var isBinary: Bool

    public init(hunks: [DiffHunk] = [], isTruncated: Bool = false, isBinary: Bool = false) {
        self.hunks = hunks
        self.isTruncated = isTruncated
        self.isBinary = isBinary
    }

    public var additions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .addition }.count } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .removal }.count } }
    public var isEmpty: Bool { hunks.isEmpty }
}
