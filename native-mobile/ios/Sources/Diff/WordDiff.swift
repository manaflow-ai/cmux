import Foundation

/// Word-level intraline diff for a deleted line paired with an added line.
/// Ranges are UTF-16 offsets into each line (NSRange-compatible).
struct WordDiff: Sendable, Hashable {
    var oldRanges: [Range<Int>]
    var newRanges: [Range<Int>]

    static let empty = WordDiff(oldRanges: [], newRanges: [])

    /// Token cap: above `maxTokens * maxTokens` cells the LCS is skipped.
    static let maxTokens = 400

    /// LCS on word, whitespace and punctuation tokens. Returns nil when the
    /// lines share too little to be worth highlighting (GitHub shows plain
    /// row tints then).
    static func compute(old: String, new: String) -> WordDiff? {
        let a = tokenize(old)
        let b = tokenize(new)
        guard !a.isEmpty || !b.isEmpty else { return nil }
        guard a.count <= maxTokens, b.count <= maxTokens else { return nil }
        let (keepA, keepB) = lcs(a.map(\.text), b.map(\.text))
        let commonLength = zip(a, keepA).reduce(0) { $1.1 ? $0 + $1.0.text.utf16.count : $0 }
        let longest = max(old.utf16.count, new.utf16.count)
        // Mostly-rewritten lines: highlighting everything is just noise.
        if longest > 0, Double(commonLength) / Double(longest) < 0.3 { return nil }
        let oldRanges = merge(zip(a, keepA).filter { !$0.1 }.map(\.0.range))
        let newRanges = merge(zip(b, keepB).filter { !$0.1 }.map(\.0.range))
        if oldRanges.isEmpty, newRanges.isEmpty { return nil }
        return WordDiff(oldRanges: oldRanges, newRanges: newRanges)
    }

    struct Token: Sendable, Hashable {
        var text: Substring
        /// UTF-16 offsets.
        var range: Range<Int>
    }

    static func tokenize(_ line: String) -> [Token] {
        enum Class { case word, space, other }
        func classify(_ character: Character) -> Class {
            if character == "_" || character.isLetter || character.isNumber { return .word }
            if character.isWhitespace { return .space }
            return .other
        }
        var tokens: [Token] = []
        var index = line.startIndex
        var offset = 0
        while index < line.endIndex {
            let kind = classify(line[index])
            var end = line.index(after: index)
            if kind != .other {
                while end < line.endIndex, classify(line[end]) == kind { end = line.index(after: end) }
            }
            let text = line[index..<end]
            let length = text.utf16.count
            tokens.append(Token(text: text, range: offset..<(offset + length)))
            offset += length
            index = end
        }
        return tokens
    }

    /// Marks which elements of each side belong to a longest common subsequence.
    static func lcs(_ a: [Substring], _ b: [Substring]) -> ([Bool], [Bool]) {
        let n = a.count
        let m = b.count
        var keepA = [Bool](repeating: false, count: n)
        var keepB = [Bool](repeating: false, count: m)
        guard n > 0, m > 0 else { return (keepA, keepB) }
        // Trim common prefix and suffix first; most edits are local.
        var prefix = 0
        while prefix < n, prefix < m, a[prefix] == b[prefix] {
            keepA[prefix] = true
            keepB[prefix] = true
            prefix += 1
        }
        var suffix = 0
        while suffix < n - prefix, suffix < m - prefix, a[n - 1 - suffix] == b[m - 1 - suffix] {
            keepA[n - 1 - suffix] = true
            keepB[m - 1 - suffix] = true
            suffix += 1
        }
        let rows = n - prefix - suffix
        let columns = m - prefix - suffix
        guard rows > 0, columns > 0 else { return (keepA, keepB) }
        var table = [Int](repeating: 0, count: (rows + 1) * (columns + 1))
        let width = columns + 1
        for i in stride(from: rows - 1, through: 0, by: -1) {
            for j in stride(from: columns - 1, through: 0, by: -1) {
                table[i * width + j] = a[prefix + i] == b[prefix + j]
                    ? table[(i + 1) * width + j + 1] + 1
                    : max(table[(i + 1) * width + j], table[i * width + j + 1])
            }
        }
        var i = 0
        var j = 0
        while i < rows, j < columns {
            if a[prefix + i] == b[prefix + j] {
                keepA[prefix + i] = true
                keepB[prefix + j] = true
                i += 1
                j += 1
            } else if table[(i + 1) * width + j] >= table[i * width + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return (keepA, keepB)
    }

    static func merge(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var merged: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, last.upperBound >= range.lowerBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}

/// Pairs deleted and added lines in a hunk the way GitHub does: each run of
/// deletions followed directly by a run of additions is zipped index by index.
enum DiffLinePairing {
    struct Pair: Sendable, Hashable {
        /// Indexes into the hunk's `lines`.
        var del: Int
        var add: Int
    }

    static func pairs(in lines: [DiffLine]) -> [Pair] {
        var result: [Pair] = []
        var i = 0
        while i < lines.count {
            guard lines[i].kind == .del else { i += 1; continue }
            var dels: [Int] = []
            while i < lines.count, lines[i].kind == .del || (lines[i].kind == .noNewline && !dels.isEmpty) {
                if lines[i].kind == .del { dels.append(i) }
                i += 1
            }
            var adds: [Int] = []
            while i < lines.count, lines[i].kind == .add || (lines[i].kind == .noNewline && !adds.isEmpty) {
                if lines[i].kind == .add { adds.append(i) }
                i += 1
            }
            for (del, add) in zip(dels, adds) { result.append(Pair(del: del, add: add)) }
        }
        return result
    }

    /// Word diffs keyed by line index within the hunk.
    static func wordDiffs(in lines: [DiffLine]) -> [Int: [Range<Int>]] {
        var ranges: [Int: [Range<Int>]] = [:]
        for pair in pairs(in: lines) {
            guard let diff = WordDiff.compute(old: lines[pair.del].text, new: lines[pair.add].text) else { continue }
            ranges[pair.del] = diff.oldRanges
            ranges[pair.add] = diff.newRanges
        }
        return ranges
    }
}
