public import CmuxMobileWire

/// Where a workspace keeps its todo list (e4-compose.md 5): cmux-next has
/// no todo surface kind or checklist op yet, so the list is a Markdown file
/// in the workspace's folder, the first of `candidates` that exists.
public struct WorkspaceTodoLocator: Hashable, Sendable {
    /// Paths relative to the workspace folder, in priority order.
    public var candidates: [String]

    public init(candidates: [String] = ["TODO.md", "todo.md", "TODOS.md", "todos.md", "TASKS.md", ".cmux/todo.md"]) {
        self.candidates = candidates
    }

    /// The folders below the root whose listing can hold a candidate.
    public var subfolders: [String] {
        var seen: [String] = []
        for candidate in candidates {
            guard let slash = candidate.lastIndex(of: "/") else { continue }
            let folder = String(candidate[..<slash])
            if !seen.contains(folder) { seen.append(folder) }
        }
        return seen
    }

    /// The best candidate among listed files: `listings` maps a folder
    /// relative to the root ("" for the root) to its entries. Names match
    /// exactly (file systems on the Mac may be case sensitive).
    public func pick(from listings: [String: [FilesListEntry]]) -> (path: String, size: UInt64)? {
        for candidate in candidates {
            let folder: String
            let name: String
            if let slash = candidate.lastIndex(of: "/") {
                folder = String(candidate[..<slash])
                name = String(candidate[candidate.index(after: slash)...])
            } else {
                folder = ""
                name = candidate
            }
            if let entry = listings[folder]?.first(where: { $0.name == name && $0.kind == .file }) {
                return (candidate, entry.size)
            }
        }
        return nil
    }
}
