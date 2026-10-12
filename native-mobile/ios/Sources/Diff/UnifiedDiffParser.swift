import Foundation

/// One file in a unified diff.
struct DiffFile: Sendable, Hashable, Identifiable {
    enum Status: String, Sendable, Hashable {
        case added, deleted, modified, renamed, copied
    }

    /// Position in the diff; stable for one parse.
    var index: Int
    /// The new path (the old path for deletions).
    var path: String
    /// The previous path for renames and copies.
    var oldPath: String?
    var status: Status = .modified
    var isBinary = false
    var oldMode: String?
    var newMode: String?
    /// Similarity percentage from `similarity index N%`.
    var similarity: Int?
    var hunks: [DiffHunk] = []
    var additions = 0
    var deletions = 0

    var id: Int { index }
    var lineCount: Int { hunks.reduce(0) { $0 + $1.lines.count } }
    var hasModeChange: Bool { oldMode != nil && newMode != nil && oldMode != newMode }
    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir + "/"
    }
}

struct DiffHunk: Sendable, Hashable {
    /// The full `@@ -a,b +c,d @@ heading` line.
    var header: String
    var oldStart: Int
    var oldCount: Int
    var newStart: Int
    var newCount: Int
    /// Text after the closing `@@` (usually the enclosing function).
    var section: String
    var lines: [DiffLine] = []
}

struct DiffLine: Sendable, Hashable {
    enum Kind: Sendable, Hashable { case context, add, del, noNewline }
    var kind: Kind
    var oldNumber: Int?
    var newNumber: Int?
    var text: String
}

/// Parses `git diff` (and plain `diff -u`) unified output into value types.
/// Pure and Sendable; safe to call off the main actor.
enum UnifiedDiffParser {
    static func parse(_ text: String) -> [DiffFile] {
        var parser = State()
        for line in splitLines(text) { parser.consume(line) }
        parser.flush()
        return parser.files
    }

    /// Splits on LF, removing a trailing CR (CRLF files) and the empty
    /// element after a final newline. Works on bytes because Swift treats
    /// `\r\n` as one Character.
    static func splitLines(_ text: String) -> [String] {
        var lines: [String] = []
        let utf8 = Array(text.utf8)
        var start = 0
        var i = 0
        while i <= utf8.count {
            if i == utf8.count || utf8[i] == 0x0A {
                if i == utf8.count, start == i { break }
                var end = i
                if end > start, utf8[end - 1] == 0x0D { end -= 1 }
                lines.append(String(decoding: utf8[start..<end], as: UTF8.self))
                start = i + 1
            }
            i += 1
        }
        return lines
    }

    private struct State {
        var files: [DiffFile] = []
        var current: DiffFile?
        var hunk: DiffHunk?
        var oldLeft = 0
        var newLeft = 0
        var oldLine = 0
        var newLine = 0
        /// Saw `--- ` for the current file; the next `+++ ` completes it.
        var sawMinus = false

        mutating func consume(_ line: String) {
            if hunk != nil {
                if oldLeft > 0 || newLeft > 0, consumeBody(line) { return }
                if line.hasPrefix("\\") {
                    appendNoNewline()
                    return
                }
                closeHunk()
            }
            if line.hasPrefix("diff --git ") || line.hasPrefix("diff --cc ") || line.hasPrefix("diff --combined ") {
                startFile()
                if let (a, b) = UnifiedDiffParser.gitHeaderPaths(String(line.drop(while: { $0 != " " }).dropFirst().drop(while: { $0 != " " }).dropFirst())) {
                    current?.oldPath = a
                    current?.path = b
                }
                return
            }
            if line.hasPrefix("@@") {
                if current == nil { startFile() }
                openHunk(line)
                return
            }
            if line.hasPrefix("--- ") {
                if current == nil || !(current?.hunks.isEmpty ?? true) || sawMinus { startFile() }
                sawMinus = true
                if let path = UnifiedDiffParser.headerPath(String(line.dropFirst(4))) {
                    current?.oldPath = path
                } else {
                    current?.status = .added
                }
                return
            }
            if line.hasPrefix("+++ "), current != nil {
                sawMinus = false
                if let path = UnifiedDiffParser.headerPath(String(line.dropFirst(4))) {
                    current?.path = path
                } else {
                    current?.status = .deleted
                    if let old = current?.oldPath { current?.path = old }
                }
                return
            }
            guard current != nil else { return }
            consumeExtendedHeader(line)
        }

        mutating func consumeExtendedHeader(_ line: String) {
            func value(_ prefix: String) -> String? {
                line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : nil
            }
            if let mode = value("new file mode ") {
                current?.status = .added
                current?.newMode = mode
            } else if let mode = value("deleted file mode ") {
                current?.status = .deleted
                current?.oldMode = mode
            } else if let mode = value("old mode ") {
                current?.oldMode = mode
            } else if let mode = value("new mode ") {
                current?.newMode = mode
            } else if let from = value("rename from ") {
                current?.status = .renamed
                current?.oldPath = UnifiedDiffParser.unquote(from)
            } else if let to = value("rename to ") {
                current?.status = .renamed
                current?.path = UnifiedDiffParser.unquote(to)
            } else if let from = value("copy from ") {
                current?.status = .copied
                current?.oldPath = UnifiedDiffParser.unquote(from)
            } else if let to = value("copy to ") {
                current?.status = .copied
                current?.path = UnifiedDiffParser.unquote(to)
            } else if let similarity = value("similarity index ") {
                current?.similarity = Int(similarity.trimmingCharacters(in: CharacterSet(charactersIn: "%")))
            } else if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
                current?.isBinary = true
                if line.hasPrefix("Binary files /dev/null and ") { current?.status = .added }
                if line.hasSuffix(" and /dev/null differ") { current?.status = .deleted }
            }
        }

        /// Returns false when the line doesn't belong to the hunk body.
        mutating func consumeBody(_ line: String) -> Bool {
            let marker = line.first
            switch marker {
            case "+" where newLeft > 0:
                hunk?.lines.append(DiffLine(kind: .add, oldNumber: nil, newNumber: newLine, text: String(line.dropFirst())))
                newLine += 1
                newLeft -= 1
                current?.additions += 1
            case "-" where oldLeft > 0:
                hunk?.lines.append(DiffLine(kind: .del, oldNumber: oldLine, newNumber: nil, text: String(line.dropFirst())))
                oldLine += 1
                oldLeft -= 1
                current?.deletions += 1
            case " ", nil:
                guard oldLeft > 0, newLeft > 0 else { return false }
                hunk?.lines.append(DiffLine(kind: .context, oldNumber: oldLine, newNumber: newLine, text: String(line.dropFirst())))
                oldLine += 1
                newLine += 1
                oldLeft -= 1
                newLeft -= 1
            case "\\":
                appendNoNewline()
            default:
                return false
            }
            return true
        }

        mutating func appendNoNewline() {
            hunk?.lines.append(DiffLine(kind: .noNewline, oldNumber: nil, newNumber: nil, text: "No newline at end of file"))
        }

        mutating func openHunk(_ line: String) {
            closeHunk()
            guard let parsed = UnifiedDiffParser.parseHunkHeader(line) else { return }
            hunk = parsed
            oldLeft = parsed.oldCount
            newLeft = parsed.newCount
            oldLine = parsed.oldStart
            newLine = parsed.newStart
            sawMinus = false
        }

        mutating func closeHunk() {
            if let hunk { current?.hunks.append(hunk) }
            hunk = nil
            oldLeft = 0
            newLeft = 0
        }

        mutating func startFile() {
            flush()
            current = DiffFile(index: files.count, path: "")
            sawMinus = false
        }

        mutating func flush() {
            closeHunk()
            guard var file = current else { return }
            if file.path.isEmpty { file.path = file.oldPath ?? "" }
            if (file.status == .renamed || file.status == .copied), file.oldPath == file.path { file.status = .modified }
            if file.status == .added || file.status == .deleted || file.oldPath == file.path { file.oldPath = nil }
            if !(file.path.isEmpty && file.hunks.isEmpty) { files.append(file) }
            current = nil
        }
    }

    // MARK: - Headers

    /// `@@ -a,b +c,d @@ section` (counts default to 1).
    static func parseHunkHeader(_ line: String) -> DiffHunk? {
        let scalars = Array(line.unicodeScalars)
        guard scalars.count > 4, line.hasPrefix("@@ ") else { return nil }
        guard let close = line.range(of: " @@", range: line.index(line.startIndex, offsetBy: 2)..<line.endIndex) else { return nil }
        let ranges = line[line.index(line.startIndex, offsetBy: 3)..<close.lowerBound].split(separator: " ")
        guard ranges.count >= 2, ranges[0].hasPrefix("-"), ranges.last!.hasPrefix("+") else { return nil }
        func pair(_ text: Substring) -> (Int, Int)? {
            let parts = text.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard let start = Int(parts[0]) else { return nil }
            let count = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
            return (start, count)
        }
        guard let old = pair(ranges[0]), let new = pair(ranges.last!) else { return nil }
        var section = String(line[close.upperBound...])
        if section.hasPrefix("@") { section = String(section.drop(while: { $0 == "@" })) }
        section = section.trimmingCharacters(in: .whitespaces)
        return DiffHunk(header: line, oldStart: old.0, oldCount: old.1, newStart: new.0, newCount: new.1, section: section)
    }

    /// A `---`/`+++` path; nil for `/dev/null`. Drops timestamps and the
    /// `a/`/`b/` prefix.
    static func headerPath(_ raw: String) -> String? {
        var text = raw
        if text.hasPrefix("\"") {
            text = unquote(text)
        } else if let tab = text.firstIndex(of: "\t") {
            text = String(text[..<tab])
        }
        if text == "/dev/null" { return nil }
        return stripPrefix(text)
    }

    /// Paths of `diff --git a/x b/y`, handling quoted names and spaces.
    static func gitHeaderPaths(_ rest: String) -> (String, String)? {
        var tokens: [String] = []
        var remainder = Substring(rest)
        while !remainder.isEmpty, tokens.count < 2 {
            remainder = remainder.drop(while: { $0 == " " })
            if remainder.hasPrefix("\"") {
                var end = remainder.index(after: remainder.startIndex)
                var escaped = false
                while end < remainder.endIndex {
                    let character = remainder[end]
                    if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { break }
                    end = remainder.index(after: end)
                }
                let stop = end < remainder.endIndex ? remainder.index(after: end) : end
                tokens.append(unquote(String(remainder[..<stop])))
                remainder = remainder[stop...]
            } else if tokens.isEmpty, !rest.contains("\"") {
                // Unquoted with possible spaces: "a/X b/X" splits in the middle.
                let text = String(remainder)
                let words = text.split(separator: " ", omittingEmptySubsequences: false)
                if words.count % 2 == 0 {
                    let half = words.count / 2
                    let a = words[..<half].joined(separator: " ")
                    let b = words[half...].joined(separator: " ")
                    if stripPrefix(a) == stripPrefix(b) || words.count == 2 { return (stripPrefix(a), stripPrefix(b)) }
                }
                if let range = text.range(of: " b/") {
                    return (stripPrefix(String(text[..<range.lowerBound])), String(text[range.upperBound...]))
                }
                return nil
            } else {
                let word = remainder.prefix(while: { $0 != " " })
                tokens.append(String(word))
                remainder = remainder[word.endIndex...]
            }
        }
        guard tokens.count == 2 else { return nil }
        return (stripPrefix(tokens[0]), stripPrefix(tokens[1]))
    }

    static func stripPrefix(_ path: String) -> String {
        for prefix in ["a/", "b/", "i/", "w/", "c/", "o/"] where path.hasPrefix(prefix) {
            return String(path.dropFirst(2))
        }
        return path
    }

    /// Decodes a git C-quoted path (`"caf\303\251 \"x\""`) into UTF-8 text.
    static func unquote(_ text: String) -> String {
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return text }
        var bytes: [UInt8] = []
        let inner = Array(text.utf8.dropFirst().dropLast())
        var i = 0
        while i < inner.count {
            let byte = inner[i]
            guard byte == 0x5C, i + 1 < inner.count else {
                bytes.append(byte)
                i += 1
                continue
            }
            let next = inner[i + 1]
            switch next {
            case UInt8(ascii: "n"): bytes.append(0x0A); i += 2
            case UInt8(ascii: "t"): bytes.append(0x09); i += 2
            case UInt8(ascii: "r"): bytes.append(0x0D); i += 2
            case UInt8(ascii: "\""), UInt8(ascii: "\\"): bytes.append(next); i += 2
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var value = 0
                var j = i + 1
                while j < inner.count, j < i + 4, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(inner[j]) {
                    value = value * 8 + Int(inner[j] - UInt8(ascii: "0"))
                    j += 1
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
                i = j
            default: bytes.append(next); i += 2
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

extension Array where Element == DiffFile {
    var totalAdditions: Int { reduce(0) { $0 + $1.additions } }
    var totalDeletions: Int { reduce(0) { $0 + $1.deletions } }
}
