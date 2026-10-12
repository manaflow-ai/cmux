import Foundation
import CmuxNativeWire
import UniformTypeIdentifiers

/// `fs.list`, `fs.stat`, `fs.read`.
public struct FileService: Sendable {
    public static let defaultReadLength = 256 * 1024
    public static let maximumReadLength = 4 * 1024 * 1024
    public static let maximumListEntries = 5000

    public let guardrail: PathGuard

    public init(guardrail: PathGuard) {
        self.guardrail = guardrail
    }

    public func list(_ params: PathParams) throws -> FSListResult {
        let path = try guardrail.resolve(params.path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { throw ServiceError.notFound("\(params.path) does not exist") }
        guard isDir.boolValue else { throw ServiceError.badRequest("\(params.path) is not a directory") }
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: path) } catch {
            throw ServiceError.forbidden("cannot list \(params.path): \(error.localizedDescription)")
        }
        let showHidden = params.showHidden ?? true
        var entries: [FileEntry] = []
        for name in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            if !showHidden, name.hasPrefix(".") { continue }
            if let entry = Self.entry(at: (path as NSString).appendingPathComponent(name)) { entries.append(entry) }
            if entries.count >= Self.maximumListEntries { break }
        }
        // Directories first, then files, each in Finder order.
        entries.sort { ($0.kind == .dir ? 0 : 1, $0.name.lowercased()) < ($1.kind == .dir ? 0 : 1, $1.name.lowercased()) }
        return FSListResult(path: path, entries: entries, truncated: names.count > entries.count && entries.count >= Self.maximumListEntries)
    }

    public func stat(_ params: PathParams) throws -> FileEntry {
        let path = try guardrail.resolve(params.path)
        guard let entry = Self.entry(at: path) else { throw ServiceError.notFound("\(params.path) does not exist") }
        return entry
    }

    public func read(_ params: FSReadParams) throws -> FSReadResult {
        let path = try guardrail.resolve(params.path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { throw ServiceError.notFound("\(params.path) does not exist") }
        guard !isDir.boolValue else { throw ServiceError.badRequest("\(params.path) is a directory") }
        let length = min(max(params.length ?? Self.defaultReadLength, 0), Self.maximumReadLength)
        let offset = max(params.offset ?? 0, 0)
        guard let handle = FileHandle(forReadingAtPath: path) else { throw ServiceError.forbidden("cannot read \(params.path)") }
        defer { try? handle.close() }
        let size = Int64((try? handle.seekToEnd()) ?? 0)
        try handle.seek(toOffset: UInt64(min(offset, size)))
        let data = try handle.read(upToCount: length) ?? Data()
        return FSReadResult(
            path: path, offset: offset, length: data.count, size: size,
            eof: offset + Int64(data.count) >= size, mime: Self.mime(forPath: path), data: data.base64EncodedString()
        )
    }

    static func entry(at path: String) -> FileEntry? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let type = attrs[.type] as? FileAttributeType
        var kind: FileEntry.Kind = .file
        var size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        if type == .typeDirectory {
            kind = .dir
        } else if type == .typeSymbolicLink {
            kind = .symlink
            // Report the target's kind and size where it resolves.
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
                if isDir.boolValue { kind = .dir }
                if let target = try? FileManager.default.attributesOfItem(atPath: (path as NSString).resolvingSymlinksInPath) {
                    size = (target[.size] as? NSNumber)?.int64Value ?? size
                }
                if !isDir.boolValue { kind = .symlink }
            }
        }
        let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let name = (path as NSString).lastPathComponent
        return FileEntry(name: name, path: path, kind: kind, size: kind == .dir ? 0 : size, modified: modified,
                         mime: kind == .dir ? nil : mime(forPath: path), hidden: name.hasPrefix("."))
    }

    static let mimeOverrides: [String: String] = [
        "md": "text/markdown", "markdown": "text/markdown", "txt": "text/plain", "log": "text/plain",
        "json": "application/json", "jsonl": "application/x-ndjson", "yaml": "application/yaml", "yml": "application/yaml",
        "toml": "application/toml", "swift": "text/x-swift", "rs": "text/x-rust", "ts": "text/typescript",
        "tsx": "text/typescript", "js": "text/javascript", "jsx": "text/javascript", "mjs": "text/javascript",
        "py": "text/x-python", "rb": "text/x-ruby", "go": "text/x-go", "c": "text/x-c", "h": "text/x-c",
        "cc": "text/x-c++", "cpp": "text/x-c++", "hpp": "text/x-c++", "m": "text/x-objc", "mm": "text/x-objc",
        "sh": "text/x-shellscript", "zsh": "text/x-shellscript", "bash": "text/x-shellscript", "zig": "text/x-zig",
        "html": "text/html", "css": "text/css", "csv": "text/csv", "xml": "application/xml", "svg": "image/svg+xml",
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
        "heic": "image/heic", "pdf": "application/pdf", "diff": "text/x-diff", "patch": "text/x-diff",
        "mov": "video/quicktime", "mp4": "video/mp4", "zip": "application/zip",
    ]

    static let plainTextNames: Set<String> = ["Makefile", "Dockerfile", "LICENSE", "README", "Podfile", "Gemfile", ".gitignore", ".env"]

    public static func mime(forPath path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        if let known = mimeOverrides[ext] { return known }
        if ext.isEmpty, plainTextNames.contains(name) { return "text/plain" }
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
            if let mime = type.preferredMIMEType { return mime }
            if type.conforms(to: .text) || type.conforms(to: .sourceCode) { return "text/plain" }
        }
        return "application/octet-stream"
    }
}
