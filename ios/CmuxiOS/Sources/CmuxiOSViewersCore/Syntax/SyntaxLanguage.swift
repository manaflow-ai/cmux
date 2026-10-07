/// A language the viewer highlights, detected from a file name.
public enum SyntaxLanguage: String, Hashable, Sendable, CaseIterable {
    case swift, objc, c, cpp, csharp, java, kotlin, javascript, typescript, go, rust, python, ruby, shell
    case json, yaml, toml, sql, css, html, xml, markdown, plain

    public static func detect(fileName: String) -> SyntaxLanguage {
        let lower = fileName.lowercased()
        let name = lower.split(separator: "/").last.map(String.init) ?? lower
        switch name {
        case "makefile", "dockerfile", ".zshrc", ".bashrc", ".profile", ".envrc": return .shell
        case "package.swift": return .swift
        case "cargo.lock": return .toml
        default: break
        }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return .plain }
        return byExtension[String(name[name.index(after: dot)...])] ?? .plain
    }

    private static let byExtension: [String: SyntaxLanguage] = [
        "swift": .swift, "m": .objc, "mm": .objc, "h": .c, "c": .c, "cc": .cpp, "cpp": .cpp, "cxx": .cpp, "hpp": .cpp,
        "cs": .csharp, "java": .java, "kt": .kotlin, "kts": .kotlin, "js": .javascript, "mjs": .javascript, "cjs": .javascript,
        "jsx": .javascript, "ts": .typescript, "tsx": .typescript, "mts": .typescript, "go": .go, "rs": .rust, "py": .python,
        "rb": .ruby, "sh": .shell, "bash": .shell, "zsh": .shell, "fish": .shell, "json": .json, "jsonl": .json,
        "yml": .yaml, "yaml": .yaml, "toml": .toml, "sql": .sql, "css": .css, "scss": .css, "html": .html, "htm": .html,
        "vue": .html, "svelte": .html, "xml": .xml, "plist": .xml, "svg": .xml, "xcstrings": .json, "md": .markdown,
        "markdown": .markdown, "zig": .rust,
    ]

    public var rules: SyntaxRules {
        switch self {
        case .swift:
            SyntaxRules(lineComments: ["//"], blockComment: ("/*", "*/"), multilineStrings: ["\"\"\""], keywords: SyntaxKeywords.swift,
                        capitalizedTypes: true, identifierStarts: ["@", "#"])
        case .objc, .c, .cpp, .csharp, .java, .kotlin, .go:
            SyntaxRules(lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\"", "'"],
                        multilineStrings: self == .go ? ["`"] : (self == .kotlin || self == .java ? ["\"\"\""] : []),
                        keywords: SyntaxKeywords.cFamily, capitalizedTypes: true, identifierStarts: ["@", "#"])
        case .javascript, .typescript:
            SyntaxRules(lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\"", "'"], multilineStrings: ["`"],
                        keywords: SyntaxKeywords.script, capitalizedTypes: true, identifierStarts: ["$", "@"])
        case .rust:
            SyntaxRules(lineComments: ["//"], blockComment: ("/*", "*/"), keywords: SyntaxKeywords.rust, capitalizedTypes: true,
                        identifierStarts: ["#"])
        case .python:
            SyntaxRules(lineComments: ["#"], quotes: ["\"", "'"], multilineStrings: ["\"\"\"", "'''"], keywords: SyntaxKeywords.python,
                        capitalizedTypes: true, identifierStarts: ["@"])
        case .ruby:
            SyntaxRules(lineComments: ["#"], quotes: ["\"", "'"], keywords: SyntaxKeywords.ruby, capitalizedTypes: true,
                        identifierStarts: ["@", ":"])
        case .shell:
            SyntaxRules(lineComments: ["#"], quotes: ["\"", "'"], keywords: SyntaxKeywords.shell, identifierStarts: ["$"],
                        commentNeedsSpace: true)
        case .json:
            SyntaxRules(keywords: ["true", "false", "null"], keyedValues: true)
        case .yaml:
            SyntaxRules(lineComments: ["#"], quotes: ["\"", "'"], keywords: ["true", "false", "null", "yes", "no", "on", "off"],
                        keyedValues: true, commentNeedsSpace: true)
        case .toml:
            SyntaxRules(lineComments: ["#"], quotes: ["\"", "'"], multilineStrings: ["\"\"\""], keywords: ["true", "false"],
                        keyedValues: true)
        case .sql:
            SyntaxRules(lineComments: ["--"], blockComment: ("/*", "*/"), quotes: ["'", "\""], keywords: SyntaxKeywords.sql,
                        keywordsIgnoreCase: true)
        case .css:
            SyntaxRules(blockComment: ("/*", "*/"), quotes: ["\"", "'"], keywords: ["important", "media", "import", "keyframes"],
                        keyedValues: true, identifierStarts: ["@", "#", "."])
        case .html, .xml:
            SyntaxRules(blockComment: ("<!--", "-->"), quotes: ["\"", "'"], markup: true)
        case .markdown:
            SyntaxRules(markdown: true)
        case .plain:
            SyntaxRules(quotes: [])
        }
    }
}
