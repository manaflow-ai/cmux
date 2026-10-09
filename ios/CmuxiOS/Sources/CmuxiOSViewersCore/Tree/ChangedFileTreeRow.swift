import CmuxMobileWire

/// One visible row of the changed-file tree: a folder (possibly several
/// compressed single-child folders, `a/b/c`) or a file, with its depth.
public struct ChangedFileTreeRow: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        case folder(fileCount: Int)
        case file(GitChangedFile)
    }

    /// The repository-relative path (folders without a trailing slash).
    public var id: String
    public var name: String
    public var depth: Int
    public var kind: Kind

    public init(id: String, name: String, depth: Int, kind: Kind) {
        self.id = id
        self.name = name
        self.depth = depth
        self.kind = kind
    }
}
