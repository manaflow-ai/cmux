/// Marks the changed span of paired lines: in every run of removals
/// followed by the same number of additions, the i-th removal pairs with
/// the i-th addition, and each gets the range between their common prefix
/// and common suffix (UTF-16). Runs of different lengths stay unmarked.
public struct IntraLineDiff: Sendable {
    /// Lines longer than this are not compared (cost and noise).
    public var maxLineLength: Int

    public init(maxLineLength: Int = 1000) {
        self.maxLineLength = maxLineLength
    }

    public func applying(to lines: [DiffLine]) -> [DiffLine] {
        var result = lines
        var index = 0
        while index < result.count {
            guard result[index].kind == .removal else {
                index += 1
                continue
            }
            let removalStart = index
            while index < result.count, result[index].kind == .removal { index += 1 }
            let additionStart = index
            while index < result.count, result[index].kind == .addition { index += 1 }
            let removals = additionStart - removalStart
            guard removals == index - additionStart else { continue }
            for offset in 0..<removals {
                let (old, new) = spans(result[removalStart + offset].text, result[additionStart + offset].text)
                result[removalStart + offset].emphasis = old
                result[additionStart + offset].emphasis = new
            }
        }
        return result
    }

    /// The changed span of each side, nil when the lines are equal, one is
    /// entirely changed or too long.
    public func spans(_ old: String, _ new: String) -> (Range<Int>?, Range<Int>?) {
        let a = Array(old.utf16)
        let b = Array(new.utf16)
        guard a.count <= maxLineLength, b.count <= maxLineLength, a != b else { return (nil, nil) }
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }
        guard prefix + suffix > 0 else { return (nil, nil) }
        let oldRange = prefix..<(a.count - suffix)
        let newRange = prefix..<(b.count - suffix)
        return (oldRange.isEmpty ? nil : oldRange, newRange.isEmpty ? nil : newRange)
    }
}
