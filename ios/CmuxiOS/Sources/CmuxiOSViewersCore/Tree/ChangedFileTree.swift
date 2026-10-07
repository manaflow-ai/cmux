import CmuxMobileWire
import Foundation

/// Folders from changed paths: folders first then files, each by name
/// (case-insensitive, numbers in order), and a folder with a single child
/// folder and no files merged into one row (`Sources/App`).
public struct ChangedFileTree: Sendable {
    private final class Node {
        var folders: [String: Node] = [:]
        var files: [GitChangedFile] = []
        var count = 0
    }

    public let rows: [ChangedFileTreeRow]

    public init(_ files: [GitChangedFile]) {
        let root = Node()
        for file in files {
            var node = root
            node.count += 1
            let parts = file.path.split(separator: "/").map(String.init)
            for part in parts.dropLast() {
                let next = node.folders[part] ?? Node()
                node.folders[part] = next
                node = next
                node.count += 1
            }
            node.files.append(file)
        }
        var rows: [ChangedFileTreeRow] = []
        Self.emit(root, path: "", depth: 0, into: &rows)
        self.rows = rows
    }

    private static func emit(_ node: Node, path: String, depth: Int, into rows: inout [ChangedFileTreeRow]) {
        for name in node.folders.keys.sorted(by: Self.order) {
            var folder = node.folders[name]!
            var label = name
            var folderPath = path.isEmpty ? name : path + "/" + name
            while folder.files.isEmpty, folder.folders.count == 1, let (child, next) = folder.folders.first {
                label += "/" + child
                folderPath += "/" + child
                folder = next
            }
            rows.append(ChangedFileTreeRow(id: folderPath, name: label, depth: depth, kind: .folder(fileCount: folder.count)))
            emit(folder, path: folderPath, depth: depth + 1, into: &rows)
        }
        for file in node.files.sorted(by: { order(name($0.path), name($1.path)) }) {
            rows.append(ChangedFileTreeRow(id: file.path, name: name(file.path), depth: depth, kind: .file(file)))
        }
    }

    static func name(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    static func order(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedAscending
    }
}
