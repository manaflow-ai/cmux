/// One `@@ -a,b +c,d @@ context` hunk.
public struct DiffHunk: Hashable, Sendable {
    /// The raw header line.
    public var header: String
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    /// The function or section after the second `@@`.
    public var section: String?
    public var lines: [DiffLine]

    public init(header: String, oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, section: String? = nil,
                lines: [DiffLine] = []) {
        self.header = header
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.section = section
        self.lines = lines
    }
}
