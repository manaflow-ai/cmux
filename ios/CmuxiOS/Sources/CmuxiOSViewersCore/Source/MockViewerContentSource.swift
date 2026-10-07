import CmuxiOSFeatureKit
import CmuxMobileWire
import Foundation

/// Canned content for mock workspaces (DEV, App Review demo, tests): every
/// mock workspace shares one small repository with uncommitted changes.
public struct MockViewerContentSource: ViewerContentSource {
    let files = MockViewerFiles()
    let workspaces: [String: String]
    let directory: URL

    /// `workspaces` maps workspace ids to folder names.
    public init(workspaces: [String: String]? = nil, directory: URL? = nil) {
        self.workspaces = workspaces ?? Dictionary(
            MockFixtures.hostWorkspaces().flatMap(\.workspaces).map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        self.directory = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("cmux-viewers-mock", isDirectory: true)
    }

    static let home = "/Users/demo"

    public func roots(host: HostID) async throws -> [FilesRoot] {
        [FilesRoot(id: "inbox", name: "cmux-phone", path: Self.home + "/Downloads/cmux-phone", writable: true)]
            + workspaces.keys.sorted().map { FilesRoot(id: $0, name: workspaces[$0]!, path: folder($0), writable: true) }
    }

    public func list(host: HostID, path: String, after: String?) async throws -> FilesListResult {
        guard let relative = relativePath(path) else { throw ViewerSourceError.forbidden }
        let entries = files.entries(in: relative)
            .filter { entry in after.map { entry.name > $0 } ?? true }
            .map { FilesListEntry(name: $0.name, kind: $0.isDirectory ? .dir : .file, size: UInt64($0.size), modifiedAt: 1_791_331_000_000) }
        return FilesListResult(entries: entries)
    }

    public func status(host: HostID, path: String) async throws -> GitStatusResult {
        guard let root = repository(of: path) else { throw ViewerSourceError.notARepository }
        return GitStatusResult(root: root, branch: "feat-viewers", head: "c9d94829df6a", upstream: "origin/feat-viewers",
                               base: "main", ahead: 2, behind: 1)
    }

    public func diff(host: HostID, params: GitDiffParams) async throws -> GitDiffResult {
        guard let root = repository(of: params.path) else { throw ViewerSourceError.notARepository }
        var changed = Self.changes(scope: params.scope)
        if let paths = params.paths {
            changed = changed.filter { file in paths.contains { file.path == $0 || file.path.hasPrefix($0 + "/") } }
        }
        if params.includePatch != true { changed = changed.map { var file = $0; file.patch = nil; return file } }
        return GitDiffResult(scope: params.scope, root: root, head: "c9d94829df6a", files: changed,
                             additions: changed.reduce(0) { $0 + $1.additions }, deletions: changed.reduce(0) { $0 + $1.deletions },
                             totalFiles: changed.count)
    }

    public func fetch(host: HostID, path: String, size: UInt64?) async throws -> URL {
        guard let relative = relativePath(path), let data = files.contents[relative] else { throw ViewerSourceError.notFound }
        let url = directory.appendingPathComponent(String(relative.hashValue & 0xFFFFFF), isDirectory: true)
            .appendingPathComponent((relative as NSString).lastPathComponent)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: Paths

    func folder(_ workspace: String) -> String {
        Self.home + "/src/" + (workspaces[workspace] ?? workspace)
    }

    /// The workspace folder containing `path`.
    func repository(of path: String) -> String? {
        workspaces.keys.map(folder).first { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// `path` relative to its workspace folder, nil outside every folder.
    func relativePath(_ path: String) -> String? {
        guard let root = repository(of: path) else { return nil }
        return path == root ? "" : String(path.dropFirst(root.count + 1))
    }

    static func changes(scope: GitDiffScope) -> [GitChangedFile] {
        let viewer = GitChangedFile(path: "Sources/App/Viewer.swift", status: .modified, additions: 4, deletions: 2, patch: """
        @@ -2,9 +2,11 @@ import UIKit
         
         /// Shows a diff, one row per line.
         final class Viewer {
        -    let mode = "unified"
        -    var hunks = 1
        +    let mode = "split"
        +    var hunks = 2
         
        +    /* A block comment
        +       across two lines. */
             func render(_ lines: [String]) -> Int {
                 lines.count + hunks // rows
             }
        @@ -20,3 +22,3 @@ final class Viewer {
         // footer
        -let version = 1
        +let version = 2
        """)
        let readme = GitChangedFile(path: "README.md", status: .modified, additions: 2, deletions: 0, patch: """
        @@ -5,4 +5,6 @@ Changes, files and documents
         ## Tasks
         
         - [x] Parse unified diffs
        +- [x] Split layout on wide screens
        +- [ ] Stream git changes live
        """)
        let row = GitChangedFile(path: "Sources/App/DiffRow.swift", status: .added, additions: 5, patch: """
        @@ -0,0 +1,5 @@
        +/// One row of a diff.
        +enum DiffRow {
        +    case hunk(Int)
        +    case line(String)
        +}
        """)
        let renamed = GitChangedFile(path: "docs/notes.txt", previousPath: "docs/todo.txt", status: .renamed)
        let image = GitChangedFile(path: "assets/dot.png", status: .added, binary: true)
        switch scope {
        case .staged: return [readme]
        case .unstaged: return [viewer, row]
        case .committed: return [renamed]
        case .uncommitted, .branch: return [readme, viewer, row, renamed, image]
        }
    }
}
