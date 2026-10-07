import Foundation

/// Parses git unified diff text (with or without `diff --git` headers)
/// into hunks with line numbers and intra-line emphasis. Pure and
/// synchronous; call it off the main actor for large patches.
public struct UnifiedDiffParser: Sendable {
    public init() {}

    public func parse(_ patch: String, truncated: Bool = false, binary: Bool = false) -> DiffDocument {
        guard !binary, !patch.isEmpty else { return DiffDocument(isTruncated: truncated, isBinary: binary) }
        var hunks: [DiffHunk] = []
        var current: DiffHunk?
        var old = 0
        var new = 0
        // Split on LF only so a CRLF file keeps its `\r` in the content.
        for raw in patch.components(separatedBy: "\n") {
            if let header = Self.header(raw) {
                if let current { hunks.append(Self.finished(current)) }
                current = header
                old = header.oldStart
                new = header.newStart
                continue
            }
            guard current != nil, let prefix = raw.first else { continue }
            let text = String(raw.dropFirst())
            switch prefix {
            case " ":
                current?.lines.append(DiffLine(kind: .context, text: text, oldNumber: old, newNumber: new))
                old += 1
                new += 1
            case "+":
                current?.lines.append(DiffLine(kind: .addition, text: text, newNumber: new))
                new += 1
            case "-":
                current?.lines.append(DiffLine(kind: .removal, text: text, oldNumber: old))
                old += 1
            case "\\":
                current?.lines.append(DiffLine(kind: .noNewlineMarker, text: ""))
            default:
                continue
            }
        }
        if let current { hunks.append(Self.finished(current)) }
        return DiffDocument(hunks: hunks, isTruncated: truncated, isBinary: false)
    }

    private static func finished(_ hunk: DiffHunk) -> DiffHunk {
        var hunk = hunk
        hunk.lines = IntraLineDiff().applying(to: hunk.lines)
        return hunk
    }

    /// `@@ -a[,b] +c[,d] @@[ section]`.
    static func header(_ line: String) -> DiffHunk? {
        guard line.hasPrefix("@@ ") else { return nil }
        let rest = line.dropFirst(3)
        guard let close = rest.range(of: " @@") else { return nil }
        let ranges = rest[rest.startIndex..<close.lowerBound].split(separator: " ")
        guard ranges.count == 2, let old = coordinate(ranges[0], prefix: "-"), let new = coordinate(ranges[1], prefix: "+") else {
            return nil
        }
        let section = rest[close.upperBound...].trimmingCharacters(in: .whitespaces)
        return DiffHunk(header: line, oldStart: old.start, oldCount: old.count, newStart: new.start, newCount: new.count,
                        section: section.isEmpty ? nil : section)
    }

    private static func coordinate(_ token: Substring, prefix: Character) -> (start: Int, count: Int)? {
        guard token.first == prefix else { return nil }
        let parts = token.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
        guard let start = parts.first.flatMap({ Int($0) }) else { return nil }
        guard parts.count <= 2 else { return nil }
        let count = parts.count == 2 ? Int(parts[1]) : 1
        guard let count else { return nil }
        return (start, count)
    }
}
