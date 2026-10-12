import Foundation
import SwiftUI
import UIKit

/// Light keyword/string/comment highlighting from a small regex tokenizer.
/// One compiled grammar per language, cached for the process lifetime.
/// Pure (no UI state); call it off the main actor.
enum SyntaxHighlighter {
    enum Language: String, Sendable, CaseIterable {
        case swift, typescript, python, rust, go, zig, json, yaml, shell, markdown, c, plain
    }

    enum TokenKind: Sendable, Hashable { case comment, string, number, keyword, type }

    struct Token: Sendable, Hashable {
        var range: Range<Int>
        var kind: TokenKind
    }

    static func language(forPath path: String) -> Language {
        let name = (path as NSString).lastPathComponent.lowercased()
        if ["makefile", "dockerfile", ".bashrc", ".zshrc", ".profile"].contains(name) { return .shell }
        switch (name as NSString).pathExtension {
        case "swift": return .swift
        case "ts", "tsx", "js", "jsx", "mjs", "cjs", "mts", "cts": return .typescript
        case "py", "pyi": return .python
        case "rs": return .rust
        case "go": return .go
        case "zig", "zon": return .zig
        case "json", "jsonc", "json5", "lock": return .json
        case "yml", "yaml", "toml": return .yaml
        case "sh", "bash", "zsh", "fish", "env": return .shell
        case "md", "markdown", "mdx": return .markdown
        case "c", "h", "m", "mm", "cpp", "cc", "hpp", "java", "kt", "cs": return .c
        default: return .plain
        }
    }

    /// Tokens in UTF-16 offsets, ordered and non-overlapping.
    static func tokens(_ line: String, language: Language) -> [Token] {
        guard language != .plain, !line.isEmpty, let grammar = grammars[language] else { return [] }
        let ns = line as NSString
        // Very long lines (minified files) aren't worth tokenizing.
        guard ns.length <= 2000 else { return [] }
        var result: [Token] = []
        grammar.regex.enumerateMatches(in: line, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            for (group, kind) in grammar.groups.enumerated() {
                let range = match.range(at: group + 1)
                if range.location != NSNotFound, range.length > 0 {
                    result.append(Token(range: range.location..<(range.location + range.length), kind: kind))
                    break
                }
            }
        }
        return result
    }

    /// An attributed line with syntax colors and optional word-diff highlights.
    static func attributed(
        _ line: String,
        language: Language,
        base: Color = Theme.ink,
        highlights: [Range<Int>] = [],
        highlightColor: Color? = nil
    ) -> AttributedString {
        var attributed = AttributedString(line)
        attributed.foregroundColor = base
        for token in tokens(line, language: language) {
            guard let range = Range(NSRange(location: token.range.lowerBound, length: token.range.count), in: attributed) else { continue }
            attributed[range].foregroundColor = SyntaxPalette.color(token.kind)
            if token.kind == .comment { attributed[range].inlinePresentationIntent = .emphasized }
        }
        if let highlightColor {
            for highlight in highlights {
                guard let range = Range(NSRange(location: highlight.lowerBound, length: highlight.count), in: attributed) else { continue }
                attributed[range].backgroundColor = highlightColor
            }
        }
        return attributed
    }

    // MARK: - Grammars

    private struct Grammar: @unchecked Sendable {
        // NSRegularExpression is immutable and thread-safe for matching.
        let regex: NSRegularExpression
        let groups: [TokenKind]
    }

    private static let grammars: [Language: Grammar] = {
        var table: [Language: Grammar] = [:]
        for language in Language.allCases where language != .plain {
            if let grammar = makeGrammar(language) { table[language] = grammar }
        }
        return table
    }()

    private static let doubleQuoted = #""(?:[^"\\]|\\.)*"?"#
    private static let singleQuoted = #"'(?:[^'\\]|\\.)*'?"#
    private static let backtick = #"`(?:[^`\\]|\\.)*`?"#
    private static let number = #"\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?)\b"#
    private static let typeName = #"\b[A-Z][A-Za-z0-9_]*\b"#

    private static func words(_ list: String) -> String {
        #"\b(?:"# + list.split(separator: " ").joined(separator: "|") + #")\b"#
    }

    private static func makeGrammar(_ language: Language) -> Grammar? {
        var parts: [(String, TokenKind)] = []
        switch language {
        case .swift:
            parts = [(#"//.*|/\*.*?(?:\*/|$)"#, .comment), (doubleQuoted, .string), (number, .number),
                     (words("actor any as associatedtype async await break case catch class continue default defer deinit do else enum extension fallthrough false fileprivate final for func guard if import in init inout internal is let lazy mutating nil nonisolated open operator override private protocol public repeat rethrows return self Self some static struct subscript super switch throw throws true try typealias var weak where while @MainActor @Sendable @escaping @Observable sending consuming borrowing"), .keyword),
                     (typeName, .type)]
        case .typescript:
            parts = [(#"//.*|/\*.*?(?:\*/|$)"#, .comment), (doubleQuoted + "|" + singleQuoted + "|" + backtick, .string), (number, .number),
                     (words("abstract as async await break case catch class const continue debugger declare default delete do else enum export extends false finally for from function get if implements import in instanceof interface let new null of private protected public readonly return set static super switch this throw true try type typeof undefined var void while yield"), .keyword),
                     (typeName, .type)]
        case .python:
            parts = [(#"#.*"#, .comment), (#"[rbfu]{0,2}(?:"# + doubleQuoted + "|" + singleQuoted + ")", .string), (number, .number),
                     (words("and as assert async await break class continue def del elif else except False finally for from global if import in is lambda None nonlocal not or pass raise return self True try while with yield match case"), .keyword),
                     (typeName, .type)]
        case .rust:
            parts = [(#"//.*|/\*.*?(?:\*/|$)"#, .comment), (doubleQuoted, .string), (number, .number),
                     (words("as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while"), .keyword),
                     (typeName, .type)]
        case .go:
            parts = [(#"//.*|/\*.*?(?:\*/|$)"#, .comment), (doubleQuoted + "|" + backtick, .string), (number, .number),
                     (words("break case chan const continue default defer else fallthrough false for func go goto if import interface iota map nil package range return select struct switch true type var"), .keyword),
                     (typeName, .type)]
        case .zig:
            parts = [(#"//.*"#, .comment), (doubleQuoted + "|" + singleQuoted, .string), (number, .number),
                     (words("addrspace align allowzero and anyframe anytype asm break catch comptime const continue defer else enum errdefer error export extern false fn for if inline noalias null or orelse packed pub resume return struct suspend switch test threadlocal true try undefined union unreachable usingnamespace var volatile while"), .keyword),
                     (#"@[A-Za-z_]\w*|"# + typeName, .type)]
        case .c:
            parts = [(#"//.*|/\*.*?(?:\*/|$)"#, .comment), (doubleQuoted + "|" + singleQuoted, .string), (number, .number),
                     (words("auto break case char class const continue default do double else enum extern false float for goto if inline int long namespace new nil NULL nullptr private protected public return self short signed sizeof static struct switch template this true typedef union unsigned using virtual void volatile while"), .keyword),
                     (#"#\w+|"# + typeName, .type)]
        case .json:
            parts = [(#""(?:[^"\\]|\\.)*"(?=\s*:)"#, .keyword), (doubleQuoted, .string), (#"-?"# + number, .number),
                     (words("true false null"), .type)]
        case .yaml:
            parts = [(#"(?:^|\s)#.*"#, .comment), (#"^\s*-?\s*[\w.\-"']+(?=\s*[:=])"#, .keyword), (doubleQuoted + "|" + singleQuoted, .string),
                     (number, .number), (words("true false null yes no on off"), .type)]
        case .shell:
            parts = [(#"(?:^|\s)#.*"#, .comment), (doubleQuoted + "|" + singleQuoted, .string), (number, .number),
                     (words("if then else elif fi for while until do done case esac in function return local export source exit set unset readonly shift"), .keyword),
                     (#"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"#, .type)]
        case .markdown:
            parts = [(#"^\s{0,3}>.*"#, .comment), (backtick, .string), (#"^\s{0,3}#{1,6}\s.*|\*\*[^*]+\*\*"#, .keyword),
                     (#"\[[^\]]*\]\([^)]*\)"#, .type)]
        case .plain:
            return nil
        }
        let pattern = parts.map { "(" + $0.0 + ")" }.joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return nil }
        // Inner groups must be non-capturing so outer group N maps to parts[N].
        guard regex.numberOfCaptureGroups == parts.count else { return nil }
        return Grammar(regex: regex, groups: parts.map(\.1))
    }
}

/// Syntax colors tuned for both appearances; no blue (cmux-next rule).
enum SyntaxPalette {
    static func dynamic(dark: UInt32, light: UInt32) -> Color {
        func color(_ hex: UInt32) -> UIColor {
            UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        let darkColor = color(dark)
        let lightColor = color(light)
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? darkColor : lightColor })
    }

    static let keyword = dynamic(dark: 0xFF7B72, light: 0xCF222E)
    static let string = dynamic(dark: 0xE3B87A, light: 0x8A5A00)
    static let comment = dynamic(dark: 0x8B949E, light: 0x6E7781)
    static let number = dynamic(dark: 0xF0A35E, light: 0xB35900)
    static let type = dynamic(dark: 0xD2A8FF, light: 0x8250DF)

    static func color(_ kind: SyntaxHighlighter.TokenKind) -> Color {
        switch kind {
        case .comment: comment
        case .string: string
        case .number: number
        case .keyword: keyword
        case .type: type
        }
    }
}
