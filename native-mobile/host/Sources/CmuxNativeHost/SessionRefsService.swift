import Foundation
import CmuxNativeWire

/// `session.refs`: finds file paths and URLs mentioned in terminal text.
/// Paths are kept only when they exist (relative to `cwd`) inside the path
/// guard; URLs are always returned.
public struct SessionRefsService: Sendable {
    public static let maximumRefs = 200
    public static let maximumTextBytes = 2 << 20

    public let guardrail: PathGuard

    public init(guardrail: PathGuard) {
        self.guardrail = guardrail
    }

    public func refs(_ params: SessionRefsParams) throws -> SessionRefsResult {
        guard params.text.utf8.count <= Self.maximumTextBytes else { throw ServiceError.badRequest("text exceeds 2 MiB") }
        let cwd = try guardrail.resolve(params.cwd ?? "~")
        var seen = Set<String>()
        var refs: [SessionRef] = []
        for token in Self.candidates(in: params.text) {
            if refs.count >= Self.maximumRefs { break }
            if token.hasPrefix("http://") || token.hasPrefix("https://") {
                if seen.insert(token).inserted {
                    refs.append(SessionRef(path: token, match: token, kind: .url, exists: true, size: nil))
                }
                continue
            }
            let path = Self.stripLocation(token)
            guard Self.looksLikePath(path), let resolved = try? guardrail.resolve(path, relativeTo: cwd) else { continue }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir) else { continue }
            guard seen.insert(resolved).inserted else { continue }
            let size = isDir.boolValue ? nil : ((try? FileManager.default.attributesOfItem(atPath: resolved))?[.size] as? NSNumber)?.int64Value
            refs.append(SessionRef(path: resolved, match: token, kind: isDir.boolValue ? .dir : .file, exists: true, size: size))
        }
        return SessionRefsResult(refs: refs)
    }

    /// Whitespace/quote-delimited tokens with surrounding punctuation trimmed.
    static func candidates(in text: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`<>()[]{}|,;"))
        let trim = CharacterSet(charactersIn: ".:,;!?")
        var out: [String] = []
        for raw in text.components(separatedBy: separators) where !raw.isEmpty {
            var token = raw
            // Strip ANSI escapes that survived into the text.
            if token.contains("\u{1b}") {
                token = token.replacingOccurrences(of: "\u{1b}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            }
            token = token.trimmingCharacters(in: trim)
            if token.count >= 2, token.count <= 1024 { out.append(token) }
        }
        return out
    }

    /// Drops `:line` / `:line:col` suffixes (compiler and grep output).
    static func stripLocation(_ token: String) -> String {
        token.replacingOccurrences(of: "(:[0-9]+){1,2}$", with: "", options: .regularExpression)
    }

    static func looksLikePath(_ token: String) -> Bool {
        if token.contains("://") { return false }
        if token.hasPrefix("/") || token.hasPrefix("~/") || token.hasPrefix("./") || token.hasPrefix("../") { return true }
        if token.contains("/") { return true }
        // A bare file name with an extension, e.g. "README.md".
        let ext = (token as NSString).pathExtension
        return !ext.isEmpty && ext.count <= 10 && ext.allSatisfy { $0.isLetter || $0.isNumber }
            && !token.allSatisfy { $0.isNumber || $0 == "." }
    }
}
