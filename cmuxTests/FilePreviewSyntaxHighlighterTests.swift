import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("File preview syntax highlighter")
struct FilePreviewSyntaxHighlighterTests {
    // MARK: - Language detection

    @Test("Common source extensions map to a highlight language")
    func commonExtensionsMapToLanguage() {
        let cases: [(String, FilePreviewSyntaxLanguage)] = [
            ("main.swift", .swift),
            ("app.py", .python),
            ("index.ts", .typescript),
            ("index.tsx", .typescript),
            ("server.js", .javascript),
            ("main.go", .go),
            ("lib.rs", .rust),
            ("Main.java", .java),
            ("data.json", .json),
            ("config.yaml", .yaml),
            ("Cargo.toml", .toml),
            ("query.sql", .sql),
            ("styles.css", .css),
            ("script.sh", .shell)
        ]
        for (name, expected) in cases {
            let url = URL(fileURLWithPath: "/tmp/\(name)")
            #expect(FilePreviewSyntaxLanguage.detect(for: url) == expected, "Expected \(name) -> \(expected)")
        }
    }

    @Test("Unsupported file types have no highlight language")
    func unsupportedFileTypesReturnNil() {
        for name in ["notes.txt", "photo.png", "archive.zip", "data.bin", "README"] {
            let url = URL(fileURLWithPath: "/tmp/\(name)")
            #expect(FilePreviewSyntaxLanguage.detect(for: url) == nil, "Expected \(name) to be unsupported")
        }
    }

    @Test("Extensionless dotfiles map by filename")
    func dotfilesMapByFilename() {
        #expect(FilePreviewSyntaxLanguage.detect(for: URL(fileURLWithPath: "/tmp/.zshrc")) == .shell)
        #expect(FilePreviewSyntaxLanguage.detect(for: URL(fileURLWithPath: "/tmp/Gemfile")) == .ruby)
    }

    // MARK: - Tokenization

    private func tokens(_ source: String, _ language: FilePreviewSyntaxLanguage) -> [FilePreviewSyntaxToken] {
        FilePreviewSyntaxTokenizer.tokens(in: source, language: language)
    }

    private func substring(_ source: String, _ range: NSRange) -> String {
        (source as NSString).substring(with: range)
    }

    private func kinds(
        _ source: String,
        _ language: FilePreviewSyntaxLanguage
    ) -> [(String, FilePreviewSyntaxTokenKind)] {
        tokens(source, language).map { (substring(source, $0.range), $0.kind) }
    }

    @Test("Swift keywords, strings, and comments are classified")
    func swiftBasics() {
        let source = "let name = \"hi\" // greeting"
        let result = kinds(source, .swift)
        #expect(result.contains(where: { $0 == ("let", .keyword) }))
        #expect(result.contains(where: { $0 == ("\"hi\"", .string) }))
        #expect(result.contains(where: { $0 == ("// greeting", .comment) }))
    }

    @Test("Token ranges line up with the source text")
    func tokenRangesAreAccurate() {
        let source = "let name = \"hi\" // greeting"
        for token in tokens(source, .swift) {
            let text = substring(source, token.range)
            switch token.kind {
            case .keyword: #expect(text == "let")
            case .string: #expect(text == "\"hi\"")
            case .comment: #expect(text == "// greeting")
            default: break
            }
        }
    }

    @Test("Numbers and types are recognized in Swift")
    func swiftNumbersAndTypes() {
        let source = "let count: Int = 42"
        let result = kinds(source, .swift)
        #expect(result.contains(where: { $0 == ("Int", .type) }))
        #expect(result.contains(where: { $0 == ("42", .number) }))
    }

    @Test("Function calls are detected when an identifier precedes a paren")
    func functionCallDetection() {
        let source = "print(value)"
        let result = kinds(source, .swift)
        #expect(result.contains(where: { $0 == ("print", .function) }))
    }

    @Test("Swift attributes are highlighted")
    func swiftAttributes() {
        let source = "@MainActor func go() {}"
        let result = kinds(source, .swift)
        #expect(result.contains(where: { $0 == ("@MainActor", .attribute) }))
        #expect(result.contains(where: { $0 == ("func", .keyword) }))
    }

    @Test("Python comments use the hash form and def is a keyword")
    func pythonBasics() {
        let source = "def add(a, b):  # sum\n    return a + b"
        let result = kinds(source, .python)
        #expect(result.contains(where: { $0 == ("def", .keyword) }))
        #expect(result.contains(where: { $0 == ("# sum", .comment) }))
        #expect(result.contains(where: { $0 == ("return", .keyword) }))
    }

    @Test("Python triple-quoted strings span multiple lines")
    func pythonTripleQuotedStrings() {
        let source = "x = \"\"\"line one\nline two\"\"\"\n"
        let result = kinds(source, .python)
        #expect(result.contains(where: { $0.0 == "\"\"\"line one\nline two\"\"\"" && $0.1 == .string }))
    }

    @Test("TypeScript template literals are treated as strings")
    func typeScriptTemplateLiteral() {
        let source = "const x = `hello ${name}`;"
        let result = kinds(source, .typescript)
        #expect(result.contains(where: { $0 == ("const", .keyword) }))
        #expect(result.contains(where: { $0.0 == "`hello ${name}`" && $0.1 == .string }))
    }

    @Test("Block comments are classified across lines")
    func blockComments() {
        let source = "/* a\n b */ let x = 1"
        let result = kinds(source, .swift)
        #expect(result.contains(where: { $0.0 == "/* a\n b */" && $0.1 == .comment }))
        #expect(result.contains(where: { $0 == ("let", .keyword) }))
    }

    @Test("CSS protocol-relative URLs are not line comments")
    func cssProtocolRelativeURLsAreNotLineComments() {
        let source = "body { background: url(//cdn.example.com/bg.png); } /* real comment */"
        let comments = kinds(source, .css)
            .filter { $0.1 == .comment }
            .map(\.0)
        #expect(!comments.contains(where: { $0.hasPrefix("//") }))
        #expect(comments.contains("/* real comment */"))
    }

    @Test("Rust lifetimes are not classified as string literals")
    func rustLifetimesAreNotStringLiterals() {
        let source = "let s = \"ok\"; fn foo<'a, 'b>(x: &'a str, y: &'b str) -> &'a str { x }"
        let strings = kinds(source, .rust)
            .filter { $0.1 == .string }
            .map(\.0)
        #expect(strings == ["\"ok\""])
    }

    @Test("JSON keywords and strings are classified, braces are not")
    func jsonBasics() {
        let source = "{ \"enabled\": true, \"count\": 3 }"
        let result = kinds(source, .json)
        #expect(result.contains(where: { $0 == ("\"enabled\"", .string) }))
        #expect(result.contains(where: { $0 == ("true", .keyword) }))
        #expect(result.contains(where: { $0 == ("3", .number) }))
    }

    @Test("Escaped quotes do not terminate a string early")
    func escapedQuotesInString() {
        let source = "let s = \"a\\\"b\" + c"
        let result = kinds(source, .swift)
        #expect(result.contains(where: { $0.0 == "\"a\\\"b\"" && $0.1 == .string }))
    }

    @Test("C preprocessor directives are highlighted at line start")
    func cPreprocessorDirective() {
        let source = "#include <stdio.h>\nint main() { return 0; }"
        let result = kinds(source, .cFamily)
        #expect(result.contains(where: { $0 == ("#include", .attribute) }))
        #expect(result.contains(where: { $0 == ("int", .keyword) }))
    }

    @Test("Tokenizing tolerates emoji and other astral-plane characters")
    func astralPlaneCharactersKeepRangesValid() {
        let source = "let s = \"🚀 launch\" // 🎉 done"
        let nsLength = (source as NSString).length
        for token in tokens(source, .swift) {
            #expect(token.range.location >= 0)
            #expect(token.range.location + token.range.length <= nsLength)
        }
        // The string token must include the rocket and survive NSString slicing.
        let result = kinds(source, .swift)
        #expect(result.contains(where: { $0.0 == "\"🚀 launch\"" && $0.1 == .string }))
    }

    @Test("Empty source yields no tokens")
    func emptySource() {
        #expect(tokens("", .swift).isEmpty)
    }

    @Test("Plain identifiers produce no colored tokens")
    func plainIdentifiersAreNotEmitted() {
        let result = kinds("foo bar baz", .swift)
        #expect(result.isEmpty)
    }

    // MARK: - Theme

    @Test("Light foreground selects the dark palette and vice versa")
    func paletteSelectionFromForeground() {
        #expect(FilePreviewSyntaxTheme.prefersDarkPalette(foreground: .white))
        #expect(!FilePreviewSyntaxTheme.prefersDarkPalette(foreground: .black))
    }

    @Test("Every token kind resolves to a color in both palettes")
    func everyKindHasAColor() {
        let allKinds: [FilePreviewSyntaxTokenKind] = [
            .keyword, .type, .string, .number, .comment, .function, .attribute
        ]
        for prefersDark in [true, false] {
            let theme = FilePreviewSyntaxTheme.theme(prefersDark: prefersDark)
            for kind in allKinds {
                _ = theme.color(for: kind)
            }
        }
    }
}
