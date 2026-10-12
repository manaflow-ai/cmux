import Foundation
import UniformTypeIdentifiers

/// Session references grouped as Files, Folders and Links. Pure.
struct SessionRefGroup: Sendable, Hashable, Identifiable {
    enum Kind: Int, Sendable, Hashable, CaseIterable {
        case files, folders, links

        var title: String {
            switch self {
            case .files: String(localized: "Files")
            case .folders: String(localized: "Folders")
            case .links: String(localized: "Links")
            }
        }
    }

    var kind: Kind
    var refs: [HostFileRef]
    var id: Kind { kind }

    /// Dedupes by path (normalizing a trailing slash), drops missing files,
    /// filters by `query` (case-insensitive on the path), and keeps the
    /// session's order within each group (most recent mention last in the
    /// scrollback, so reversed to put it first).
    static func make(_ refs: [HostFileRef], query: String = "") -> [SessionRefGroup] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var seen: Set<String> = []
        var buckets: [Kind: [HostFileRef]] = [:]
        for ref in refs.reversed() {
            let key = normalized(ref.path)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            if ref.exists == false { continue }
            if !needle.isEmpty, !ref.path.lowercased().contains(needle) { continue }
            buckets[kind(of: ref), default: []].append(ref)
        }
        return Kind.allCases.compactMap { kind in
            guard let refs = buckets[kind], !refs.isEmpty else { return nil }
            return SessionRefGroup(kind: kind, refs: refs)
        }
    }

    static func kind(of ref: HostFileRef) -> Kind {
        if ref.isURL || ref.path.hasPrefix("http://") || ref.path.hasPrefix("https://") { return .links }
        if ref.isDirectory || ref.kind == "directory" { return .folders }
        return .files
    }

    static func normalized(_ path: String) -> String {
        var path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

/// How a file is best previewed, from its name and the host's MIME type.
enum FilePreviewKind: String, Sendable, Hashable {
    case image, video, audio, pdf, html, markdown, svg, json, text, other

    static func detect(path: String, mime: String? = nil) -> FilePreviewKind {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        switch ext {
        case "svg": return .svg
        case "md", "markdown", "mdx": return .markdown
        case "html", "htm", "xhtml": return .html
        case "json", "jsonc", "geojson", "webmanifest": return .json
        case "pdf": return .pdf
        case "heic", "heif", "png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "ico": return .image
        default: break
        }
        if let type = UTType(filenameExtension: ext), !ext.isEmpty {
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
            if type.conforms(to: .audio) { return .audio }
            if type.conforms(to: .pdf) { return .pdf }
            if type.conforms(to: .sourceCode) || type.conforms(to: .plainText) || type.conforms(to: .script)
                || type.conforms(to: .xml) || type.conforms(to: .yaml) {
                return .text
            }
        }
        if let mime = mime?.lowercased() {
            if mime == "image/svg+xml" { return .svg }
            if mime.hasPrefix("image/") { return .image }
            if mime.hasPrefix("video/") { return .video }
            if mime.hasPrefix("audio/") { return .audio }
            if mime == "application/pdf" { return .pdf }
            if mime == "text/html" { return .html }
            if mime == "text/markdown" { return .markdown }
            if mime == "application/json" { return .json }
            if mime.hasPrefix("text/") || mime.hasSuffix("+json") || mime.hasSuffix("+xml")
                || mime == "application/javascript" || mime == "application/x-sh" || mime == "application/xml" {
                return .text
            }
        }
        if textNames.contains(name) || textExtensions.contains(ext) { return .text }
        return .other
    }

    /// Code and config files UTType doesn't classify as text.
    static let textExtensions: Set<String> = [
        "swift", "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "rs", "go", "zig", "zon", "c", "h", "m", "mm", "cpp", "cc", "hpp",
        "java", "kt", "cs", "rb", "php", "lua", "sh", "bash", "zsh", "fish", "toml", "yaml", "yml", "ini", "cfg", "conf", "env",
        "txt", "log", "csv", "tsv", "sql", "graphql", "proto", "css", "scss", "less", "xml", "plist", "lock", "gitignore",
        "gitattributes", "editorconfig", "diff", "patch", "vue", "svelte", "astro", "dockerfile", "make", "cmake", "gradle",
    ]
    static let textNames: Set<String> = [
        "makefile", "dockerfile", "readme", "license", "changelog", ".gitignore", ".env", "gemfile", "procfile", "brewfile",
    ]

    /// Text-like kinds that can also be shown as source.
    var hasSourceToggle: Bool { self == .html || self == .markdown || self == .svg }
    var isTextual: Bool { self == .text || self == .json || hasSourceToggle }
}

/// SF Symbol for a file or reference by kind/extension.
enum FileSymbol {
    static func symbol(path: String, isDirectory: Bool = false, isURL: Bool = false) -> String {
        if isURL { return "link" }
        if isDirectory { return "folder" }
        switch FilePreviewKind.detect(path: path) {
        case .image, .svg: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .pdf: return "doc.richtext"
        case .html: return "globe"
        case .markdown: return "doc.plaintext"
        case .json: return "curlybraces"
        case .text: return "chevron.left.forwardslash.chevron.right"
        case .other: return "doc"
        }
    }
}

enum FileFormat {
    static func size(_ bytes: Int?) -> String? {
        guard let bytes else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func modified(_ seconds: Double?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        let date = Date(timeIntervalSince1970: seconds)
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    /// Path shown relative to `base` when inside it, with `~` for home-like roots.
    static func display(_ path: String, relativeTo base: String?) -> String {
        if let base, !base.isEmpty {
            let prefix = base.hasSuffix("/") ? base : base + "/"
            if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        }
        if let range = path.range(of: #"^/Users/[^/]+"#, options: .regularExpression) {
            return "~" + path[range.upperBound...]
        }
        return path
    }
}

/// One `git.status` entry, decoded from the host's JSON.
struct GitChangedFile: Sendable, Hashable, Identifiable {
    var path: String
    var oldPath: String?
    var status: String
    var staged: Bool
    var unstaged: Bool
    var id: String { path }

    /// M, A, D, R, C, U (unmerged), ? (untracked), T.
    var badge: String {
        switch status {
        case "added": "A"
        case "deleted": "D"
        case "renamed": "R"
        case "copied": "C"
        case "untracked": "U"
        case "unmerged": "!"
        case "typechange": "T"
        default: "M"
        }
    }

    static func parse(_ value: JSONValue) -> (root: String?, files: [GitChangedFile]) {
        let files = (value["files"]?.array ?? []).compactMap { item -> GitChangedFile? in
            guard let path = item["path"]?.string else { return nil }
            return GitChangedFile(
                path: path,
                oldPath: item["old_path"]?.string ?? item["oldPath"]?.string,
                status: item["status"]?.string ?? "modified",
                staged: item["staged"]?.bool ?? false,
                unstaged: item["unstaged"]?.bool ?? true
            )
        }
        return (value["root"]?.string, files)
    }
}
