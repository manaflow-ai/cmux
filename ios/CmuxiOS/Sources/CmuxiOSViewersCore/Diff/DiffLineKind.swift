/// What one line of a hunk is.
public enum DiffLineKind: Hashable, Sendable {
    case context
    case addition
    case removal
    /// `\ No newline at end of file` after the line above it.
    case noNewlineMarker
}
