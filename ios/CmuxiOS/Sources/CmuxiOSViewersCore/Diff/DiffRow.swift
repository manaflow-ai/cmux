/// One row of a laid-out diff: what a list cell shows.
public enum DiffRow: Hashable, Sendable {
    /// A hunk header; `hunk` indexes `DiffDocument.hunks`.
    case hunk(index: Int, header: String, section: String?)
    /// Unified layout: one line.
    case line(DiffLine)
    /// Split layout: the old side and the new side (either may be empty).
    case split(old: DiffLine?, new: DiffLine?)
}
