/// A line lexer: keywords, strings, comments, numbers, types, markup tags
/// and keys, with block comments and multi-line strings carried across
/// lines by `SyntaxLineState`. Pure and value-typed, so it runs off the
/// main actor; the viewers apply its tokens as attributes.
public struct SyntaxHighlighter: Sendable {
    public let language: SyntaxLanguage
    private let rules: SyntaxRules
    private let lineComments: [[UInt16]]
    private let blockOpen: [UInt16]?
    private let blockClose: [UInt16]?
    private let multiline: [[UInt16]]
    private let quotes: Set<UInt16>

    public init(language: SyntaxLanguage) {
        self.language = language
        rules = language.rules
        lineComments = rules.lineComments.map { Array($0.utf16) }
        blockOpen = rules.blockComment.map { Array($0.open.utf16) }
        blockClose = rules.blockComment.map { Array($0.close.utf16) }
        multiline = rules.multilineStrings.map { Array($0.utf16) }
        quotes = Set(rules.quotes.compactMap { $0.utf16.first })
    }

    /// Tokens of a whole text in absolute UTF-16 offsets.
    public func highlight(_ text: String) -> [SyntaxToken] {
        var tokens: [SyntaxToken] = []
        var state = SyntaxLineState.normal
        var offset = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let units = Array(line.utf16)
            let (lineTokens, next) = highlight(units: units, state: state)
            tokens.append(contentsOf: lineTokens.map { SyntaxToken(($0.range.lowerBound + offset)..<($0.range.upperBound + offset), $0.kind) })
            state = next
            offset += units.count + 1
        }
        return tokens
    }

    /// Tokens of one line (UTF-16 offsets into it) and the state it ends in.
    public func highlight(line: String, state: SyntaxLineState = .normal) -> ([SyntaxToken], SyntaxLineState) {
        highlight(units: Array(line.utf16), state: state)
    }

    // MARK: Scanner

    private func highlight(units u: [UInt16], state: SyntaxLineState) -> ([SyntaxToken], SyntaxLineState) {
        if rules.markdown { return (markdownLine(u), .normal) }
        var tokens: [SyntaxToken] = []
        var i = 0
        switch state {
        case .normal:
            break
        case .blockComment:
            guard let close = blockClose, let end = find(close, in: u, from: 0) else {
                return (u.isEmpty ? [] : [SyntaxToken(0..<u.count, .comment)], .blockComment)
            }
            tokens.append(SyntaxToken(0..<(end + close.count), .comment))
            i = end + close.count
        case .string(let delimiter):
            let close = Array(delimiter.utf16)
            guard let end = findUnescaped(close, in: u, from: 0) else {
                return (u.isEmpty ? [] : [SyntaxToken(0..<u.count, .string)], state)
            }
            tokens.append(SyntaxToken(0..<(end + close.count), .string))
            i = end + close.count
        }
        while i < u.count {
            let c = u[i]
            if rules.markup, c == 0x3C, !(blockOpen.map { matches($0, in: u, at: i) } ?? false) {
                i = markupTag(u, from: i, into: &tokens)
                continue
            }
            if lineComments.contains(where: { matches($0, in: u, at: i) }),
               !rules.commentNeedsSpace || i == 0 || isSpace(u[i - 1]) {
                tokens.append(SyntaxToken(i..<u.count, .comment))
                return (tokens, .normal)
            }
            if let open = blockOpen, let close = blockClose, matches(open, in: u, at: i) {
                guard let end = find(close, in: u, from: i + open.count) else {
                    tokens.append(SyntaxToken(i..<u.count, .comment))
                    return (tokens, .blockComment)
                }
                tokens.append(SyntaxToken(i..<(end + close.count), .comment))
                i = end + close.count
                continue
            }
            if let delimiter = multiline.first(where: { matches($0, in: u, at: i) }) {
                guard let end = findUnescaped(delimiter, in: u, from: i + delimiter.count) else {
                    tokens.append(SyntaxToken(i..<u.count, .string))
                    return (tokens, .string(delimiter: String(decoding: delimiter, as: UTF16.self)))
                }
                tokens.append(SyntaxToken(i..<(end + delimiter.count), .string))
                i = end + delimiter.count
                continue
            }
            if quotes.contains(c) {
                let end = (findUnescaped([c], in: u, from: i + 1).map { $0 + 1 }) ?? u.count
                tokens.append(SyntaxToken(i..<end, isKey(u, after: end) ? .attribute : .string))
                i = end
                continue
            }
            if isDigit(c), i == 0 || !isIdentifier(u[i - 1]) {
                var end = i + 1
                while end < u.count, isNumberPart(u[end]) { end += 1 }
                tokens.append(SyntaxToken(i..<end, .number))
                i = end
                continue
            }
            if isIdentifierStart(c) {
                var end = i + 1
                while end < u.count, isIdentifier(u[end]) { end += 1 }
                if let kind = wordKind(u, i..<end) { tokens.append(SyntaxToken(i..<end, kind)) }
                i = end
                continue
            }
            i += 1
        }
        return (tokens, .normal)
    }

    private func wordKind(_ u: [UInt16], _ range: Range<Int>) -> SyntaxTokenKind? {
        let word = String(decoding: u[range], as: UTF16.self)
        if rules.keyedValues, isKey(u, after: range.upperBound) { return .attribute }
        if rules.keywords.contains(rules.keywordsIgnoreCase ? word.lowercased() : word) { return .keyword }
        if let first = u[range].first, first == 0x40 || first == 0x23 { return .keyword }
        if rules.capitalizedTypes, let first = u[range].first, first >= 0x41, first <= 0x5A { return .type }
        return nil
    }

    /// `key:` (not `::`) or `key =` for keyed formats.
    private func isKey(_ u: [UInt16], after end: Int) -> Bool {
        guard rules.keyedValues else { return false }
        var j = end
        while j < u.count, u[j] == 0x20 || u[j] == 0x09 { j += 1 }
        guard j < u.count else { return false }
        if u[j] == 0x3A { return j + 1 >= u.count || u[j + 1] != 0x3A }
        return language == .toml && u[j] == 0x3D
    }

    /// `<name attr="v">`: the tag name, attribute names and quoted values.
    private func markupTag(_ u: [UInt16], from start: Int, into tokens: inout [SyntaxToken]) -> Int {
        var i = start + 1
        if i < u.count, u[i] == 0x2F || u[i] == 0x21 || u[i] == 0x3F { i += 1 }
        let nameStart = i
        while i < u.count, isIdentifier(u[i]) || u[i] == 0x2D || u[i] == 0x3A { i += 1 }
        guard i > nameStart else { return start + 1 }
        tokens.append(SyntaxToken(nameStart..<i, .tag))
        while i < u.count, u[i] != 0x3E {
            if quotes.contains(u[i]) {
                let end = (findUnescaped([u[i]], in: u, from: i + 1).map { $0 + 1 }) ?? u.count
                tokens.append(SyntaxToken(i..<end, .string))
                i = end
            } else if isIdentifierStart(u[i]) {
                let attributeStart = i
                while i < u.count, isIdentifier(u[i]) || u[i] == 0x2D || u[i] == 0x3A { i += 1 }
                tokens.append(SyntaxToken(attributeStart..<i, .attribute))
            } else {
                i += 1
            }
        }
        return min(i + 1, u.count)
    }

    /// Headings, fences and inline code spans of Markdown source.
    private func markdownLine(_ u: [UInt16]) -> [SyntaxToken] {
        var start = 0
        while start < u.count, start < 3, u[start] == 0x20 { start += 1 }
        if start < u.count, u[start] == 0x23 { return [SyntaxToken(0..<u.count, .heading)] }
        if matches(Array("```".utf16), in: u, at: start) || matches(Array("~~~".utf16), in: u, at: start) {
            return [SyntaxToken(0..<u.count, .comment)]
        }
        var tokens: [SyntaxToken] = []
        var i = 0
        while i < u.count {
            if u[i] == 0x60, let end = find([0x60], in: u, from: i + 1) {
                tokens.append(SyntaxToken(i..<(end + 1), .string))
                i = end + 1
            } else {
                i += 1
            }
        }
        return tokens
    }

    // MARK: Units

    private func matches(_ needle: [UInt16], in u: [UInt16], at i: Int) -> Bool {
        guard !needle.isEmpty, i + needle.count <= u.count else { return false }
        for k in 0..<needle.count where u[i + k] != needle[k] { return false }
        return true
    }

    private func find(_ needle: [UInt16], in u: [UInt16], from start: Int) -> Int? {
        var i = start
        while i + needle.count <= u.count {
            if matches(needle, in: u, at: i) { return i }
            i += 1
        }
        return nil
    }

    /// Like `find`, skipping backslash-escaped characters.
    private func findUnescaped(_ needle: [UInt16], in u: [UInt16], from start: Int) -> Int? {
        var i = start
        while i + needle.count <= u.count {
            if u[i] == 0x5C {
                i += 2
                continue
            }
            if matches(needle, in: u, at: i) { return i }
            i += 1
        }
        return nil
    }

    private func isSpace(_ c: UInt16) -> Bool { c == 0x20 || c == 0x09 }
    private func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
    private func isLetter(_ c: UInt16) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c >= 0x80 }
    private func isIdentifier(_ c: UInt16) -> Bool { isLetter(c) || isDigit(c) || c == 0x5F }

    private func isIdentifierStart(_ c: UInt16) -> Bool {
        if isLetter(c) || c == 0x5F { return true }
        guard c < 0x80 else { return false }
        return rules.identifierStarts.contains(Character(Unicode.Scalar(UInt8(c))))
    }

    private func isNumberPart(_ c: UInt16) -> Bool {
        isDigit(c) || c == 0x2E || c == 0x5F || (c >= 0x61 && c <= 0x66) || (c >= 0x41 && c <= 0x46) || c == 0x78 || c == 0x6F
    }
}
