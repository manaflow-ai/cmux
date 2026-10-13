import Foundation

/// A file, directory or link a session referenced: terminal output, or an
/// agent session's tool calls, attachments and answers. (The name predates
/// agent sessions; `SessionArtifact` is the same type.)
public struct TerminalArtifact: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case directory, image, video, html, markdown, code, text, pdf, binary, link
    }

    /// The reference as written, without a `:line:col` suffix.
    public var id: String { reference }
    public let reference: String
    public var kind: Kind
    /// The line from a `path:line[:col]` reference.
    public var line: Int?
    /// Order of first appearance.
    public var order: Int
    /// How the session referenced it ("Edited · +12 −4", "Attached", "Linked in the answer"); nil for terminal output.
    public var detail: String?

    public init(reference: String, kind: Kind, line: Int? = nil, order: Int = 0, detail: String? = nil) {
        self.reference = reference
        self.kind = kind
        self.line = line
        self.order = order
        self.detail = detail
    }

    public var name: String {
        if kind == .link { return URL(string: reference)?.host() ?? reference }
        let trimmed = reference.hasSuffix("/") ? String(reference.dropLast()) : reference
        return trimmed.split(separator: "/").last.map(String.init) ?? reference
    }

    public var fileExtension: String {
        guard kind != .link, let dot = name.lastIndex(of: ".") else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    public var systemImage: String {
        switch kind {
        case .directory: "folder.fill"
        case .image: "photo"
        case .video: "play.rectangle"
        case .html: "globe"
        case .markdown: "doc.richtext"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .text: "doc.text"
        case .pdf: "doc.fill"
        case .binary: "gearshape.2"
        case .link: "link"
        }
    }

    public static func kind(forExtension ext: String) -> Kind? {
        switch ext.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "svg": .image
        case "mp4", "mov", "m4v", "webm": .video
        case "html", "htm": .html
        case "md", "markdown": .markdown
        case "swift", "rs", "zig", "c", "h", "m", "go", "py", "js", "ts", "tsx", "jsx", "sh", "toml", "json", "yml",
             "yaml", "css", "sql", "rb", "java", "kt": .code
        case "txt", "log", "lock", "csv": .text
        case "pdf": .pdf
        default: nil
        }
    }
}

/// What an artifact preview shows.
public enum ArtifactContent: Sendable {
    case text(String)
    case image(Data)
    /// A playable local file (video).
    case file(URL)
    case web(URL)
    case directory([TerminalArtifact])
    case pdf(Data)
    case binary(description: String)
}

public typealias SessionArtifact = TerminalArtifact

/// Loads artifact contents: from the Mac over the `file` link service
/// (`LinkFileArtifactSource`), from inline data, or from the mock.
public protocol ArtifactSource: Sendable {
    func load(_ artifact: TerminalArtifact) async throws -> ArtifactContent
}

public struct ArtifactNotFound: Error, LocalizedError {
    public let reference: String
    public init(reference: String) { self.reference = reference }
    public var errorDescription: String? { "\(reference) is not available from this Mac." }
}

/// A preview that can't load, with the sentence to show.
public struct ArtifactUnavailable: Error, LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Finds paths and URLs in terminal output: strips escape sequences, keeps a
/// partial last line across chunks, and reports each reference once.
public struct ArtifactExtractor: Sendable {
    private var partial = ""
    private var seen: Set<String> = []
    private var count = 0

    public init() {}

    private static let url = try! NSRegularExpression(pattern: #"https?://[^\s'"<>`)\]]+"#)
    private static let path = try! NSRegularExpression(
        pattern: #"(?<![\w/.\-])((?:~|\.{1,2})?/?(?:[A-Za-z0-9_.@+\-]+/)*[A-Za-z0-9_@+\-][A-Za-z0-9_.@+\-]*(?:\.[A-Za-z][A-Za-z0-9]{0,7})?/?)(?::(\d+)(?::\d+)?)?"#)
    private static let escapes = try! NSRegularExpression(pattern: "\u{1B}(?:\\[[0-?]*[ -/]*[@-~]|\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)|[@-Z\\\\-_])")

    public mutating func scan(_ data: Data) -> [TerminalArtifact] {
        let text = partial + String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: CharacterSet.newlines)
        partial = lines.removeLast()
        if partial.count > 4096 { partial = "" }
        var found: [TerminalArtifact] = []
        for line in lines where !line.isEmpty {
            found += scanLine(line)
        }
        return found
    }

    public mutating func scanLine(_ raw: String) -> [TerminalArtifact] {
        let line = Self.escapes.stringByReplacingMatches(in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "")
        let ns = line as NSString
        var found: [TerminalArtifact] = []
        var covered: [NSRange] = []
        // `ls -l` rows: a directory's name is the last field.
        if line.hasPrefix("d"), line.count > 10, line.prefix(10).allSatisfy({ "drwxsStT-@+".contains($0) }),
           let name = line.split(separator: " ").last, name != ".", name != ".." {
            add(TerminalArtifact(reference: String(name) + "/", kind: .directory), to: &found)
            return found
        }
        for match in Self.url.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            var reference = ns.substring(with: match.range)
            while let last = reference.last, ".,;:".contains(last) { reference.removeLast() }
            covered.append(match.range)
            add(TerminalArtifact(reference: reference, kind: .link), to: &found)
        }
        for match in Self.path.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            let range = match.range(at: 1)
            if covered.contains(where: { NSIntersectionRange($0, range).length > 0 }) { continue }
            let reference = ns.substring(with: range)
            let lineNumber = match.range(at: 2).location != NSNotFound ? Int(ns.substring(with: match.range(at: 2))) : nil
            guard let kind = Self.classify(reference) else { continue }
            add(TerminalArtifact(reference: reference, kind: kind, line: lineNumber), to: &found)
        }
        return found
    }

    private mutating func add(_ artifact: TerminalArtifact, to found: inout [TerminalArtifact]) {
        guard seen.insert(artifact.reference).inserted else { return }
        var artifact = artifact
        artifact.order = count
        count += 1
        found.append(artifact)
    }

    /// Paths with a known extension, or slash paths with a letter in every
    /// component (directories and binaries). Versions, times and ratios fail both.
    public static func classify(_ reference: String) -> TerminalArtifact.Kind? {
        let trimmed = reference.hasSuffix("/") ? String(reference.dropLast()) : reference
        guard !trimmed.isEmpty, trimmed.contains(where: \.isLetter) else { return nil }
        let name = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            let ext = String(name[name.index(after: dot)...])
            if let kind = TerminalArtifact.kind(forExtension: ext) { return kind }
            if ["Cargo.lock", "Makefile", "Dockerfile"].contains(name) { return .text }
        }
        if ["Makefile", "Dockerfile", "LICENSE"].contains(name) { return .text }
        let components = trimmed.split(separator: "/")
        guard components.count >= 2 || reference.hasSuffix("/") else { return nil }
        guard components.allSatisfy({ $0.contains(where: \.isLetter) }) else { return nil }
        if reference.hasSuffix("/") { return .directory }
        if name.contains(".") { return nil }
        return trimmed.contains("/bin/") || trimmed.contains("/release/") || trimmed.contains("/debug/") ? .binary : .directory
    }
}
