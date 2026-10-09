import Foundation

/// A line-level diff for inline edit previews. Exact LCS for edits up to a
/// few hundred lines each side; larger edits fall back to "all old removed,
/// all new added" so a huge write never stalls the main thread.
struct LineDiff: Sendable {
    enum Kind: Sendable, Hashable { case context, added, removed, gap }

    struct Line: Sendable, Hashable, Identifiable {
        var id: Int
        var kind: Kind
        var text: String
        /// 1-based line number in the new text (context and added) or old text (removed).
        var number: Int?
    }

    let lines: [Line]

    init(old: String, new: String, context: Int = 3) {
        let ops = Self.operations(Self.split(old), Self.split(new))
        lines = Self.trim(ops, context: context)
    }

    static func counts(old: String, new: String) -> DiffCounts {
        let ops = operations(split(old), split(new))
        return DiffCounts(added: ops.filter { $0.kind == .added }.count, removed: ops.filter { $0.kind == .removed }.count)
    }

    static func split(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    private static func operations(_ a: [String], _ b: [String]) -> [Line] {
        let n = a.count, m = b.count
        guard n * m <= 160_000 else {
            return a.enumerated().map { Line(id: 0, kind: .removed, text: $1, number: $0 + 1) }
                + b.enumerated().map { Line(id: 0, kind: .added, text: $1, number: $0 + 1) }
        }
        // lcs[i][j] = LCS length of a[i...] and b[j...]
        var lcs = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }
        var out: [Line] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                out.append(Line(id: 0, kind: .context, text: b[j], number: j + 1)); i += 1; j += 1
            } else if j < m, i == n || lcs[i][j + 1] >= lcs[i + 1][j] {
                out.append(Line(id: 0, kind: .added, text: b[j], number: j + 1)); j += 1
            } else {
                out.append(Line(id: 0, kind: .removed, text: a[i], number: i + 1)); i += 1
            }
        }
        return out
    }

    /// Keeps `context` unchanged lines around each change and replaces longer
    /// unchanged stretches with one gap line.
    private static func trim(_ ops: [Line], context: Int) -> [Line] {
        let changed = ops.indices.filter { ops[$0].kind != .context }
        guard !changed.isEmpty else { return [] }
        var keep = Set<Int>()
        for c in changed { for k in max(0, c - context)...min(ops.count - 1, c + context) { keep.insert(k) } }
        var out: [Line] = []
        var lastKept = -1
        for index in ops.indices where keep.contains(index) {
            if lastKept >= 0, index > lastKept + 1 {
                out.append(Line(id: out.count, kind: .gap, text: "", number: nil))
            }
            var line = ops[index]
            line.id = out.count
            out.append(line)
            lastKept = index
        }
        return out
    }
}
