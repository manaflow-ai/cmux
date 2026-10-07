import Foundation

/// Finds markdown-lite spans in a prompt: `#` headings, `**bold**`,
/// `` `code` ``, `-`/`*`/`1.` list markers and `@mentions`. Linear in the
/// text length; the editor restyles on every change.
public struct PromptStyler: Sendable {
    public var text: String

    public init(_ text: String) {
        self.text = text
    }

    public var runs: [PromptStyleRun] {
        let source = text as NSString
        var runs: [PromptStyleRun] = []
        var lineStart = 0
        while lineStart <= source.length {
            let lineRange = source.lineRange(for: NSRange(location: lineStart, length: 0))
            let line = source.substring(with: lineRange)
            runs += Self.lineRuns(line, offset: lineRange.location)
            let next = NSMaxRange(lineRange)
            if next <= lineStart { break }
            lineStart = next
            if lineStart == source.length { break }
        }
        return runs
    }

    private static func lineRuns(_ line: String, offset: Int) -> [PromptStyleRun] {
        let units = Array(line.utf16)
        var runs: [PromptStyleRun] = []
        let trimmedEnd = units.lastIndex { $0 != 0x0A && $0 != 0x0D }.map { $0 + 1 } ?? 0
        if units.first == 0x23 {   // "#"
            runs.append(PromptStyleRun(kind: .heading, range: NSRange(location: offset, length: trimmedEnd)))
            return runs
        }
        if let marker = listMarkerLength(units) {
            runs.append(PromptStyleRun(kind: .bullet, range: NSRange(location: offset, length: marker)))
        }
        var index = 0
        var inCode = false
        var codeStart = 0
        var boldStart: Int?
        while index < trimmedEnd {
            let unit = units[index]
            if unit == 0x60 {   // "`"
                if inCode {
                    runs.append(PromptStyleRun(kind: .code, range: NSRange(location: offset + codeStart, length: index - codeStart + 1)))
                }
                inCode.toggle()
                codeStart = index
                index += 1
                continue
            }
            if !inCode, unit == 0x2A, index + 1 < trimmedEnd, units[index + 1] == 0x2A {   // "**"
                if let start = boldStart {
                    runs.append(PromptStyleRun(kind: .bold, range: NSRange(location: offset + start, length: index + 2 - start)))
                    boldStart = nil
                } else {
                    boldStart = index
                }
                index += 2
                continue
            }
            if !inCode, unit == 0x40, index == 0 || units[index - 1] == 0x20 || units[index - 1] == 0x09 {   // "@"
                var end = index + 1
                while end < trimmedEnd, units[end] != 0x20, units[end] != 0x09 { end += 1 }
                if end > index + 1 {
                    runs.append(PromptStyleRun(kind: .mention, range: NSRange(location: offset + index, length: end - index)))
                }
                index = end
                continue
            }
            index += 1
        }
        return runs
    }

    /// Length of a leading `- `, `* ` or `12. ` marker (after indentation).
    private static func listMarkerLength(_ units: [UInt16]) -> Int? {
        var index = 0
        while index < units.count, units[index] == 0x20 { index += 1 }
        guard index < units.count else { return nil }
        if (units[index] == 0x2D || units[index] == 0x2A), index + 1 < units.count, units[index + 1] == 0x20 {
            return index + 2
        }
        var digits = index
        while digits < units.count, (0x30...0x39).contains(units[digits]) { digits += 1 }
        if digits > index, digits + 1 < units.count, units[digits] == 0x2E, units[digits + 1] == 0x20 {
            return digits + 2
        }
        return nil
    }
}
