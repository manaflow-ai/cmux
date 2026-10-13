import Foundation
import Testing
@testable import CmuxNative

@Suite("SyntaxHighlighter carry")
struct SyntaxHighlighterTests {
    /// Tokens for a run of lines, carrying state like the diff and preview do.
    private func run(_ lines: [String], _ language: SyntaxHighlighter.Language) -> [[SyntaxHighlighter.Token]] {
        var carry = SyntaxHighlighter.Carry.none
        return lines.map { SyntaxHighlighter.tokens($0, language: language, carry: &carry) }
    }

    private func kinds(_ tokens: [SyntaxHighlighter.Token]) -> [SyntaxHighlighter.TokenKind] { tokens.map(\.kind) }

    @Test func pythonDocstringBodyIsString() {
        let lines = [
            #"    """Verifies that the version in"#,
            "    the manifest is in sync for if and while.",
            #"    """"#,
            "    if x in y:",
        ]
        let tokens = run(lines, .python)
        #expect(kinds(tokens[0]) == [.string])
        // The whole middle line is one string token: no keywords inside.
        #expect(tokens[1] == [SyntaxHighlighter.Token(range: 0..<(lines[1] as NSString).length, kind: .string)])
        #expect(kinds(tokens[2]) == [.string])
        // After the closing quotes, code is code again.
        #expect(kinds(tokens[3]) == [.keyword, .keyword])
    }

    @Test func pythonOneLineDocstringDoesNotCarry() {
        let tokens = run(["    \"\"\"One line.\"\"\"", "    return None"], .python)
        #expect(kinds(tokens[0]) == [.string])
        #expect(kinds(tokens[1]) == [.keyword, .keyword])
    }

    @Test func pythonSingleQuotedTripleAndRawPrefix() {
        let tokens = run(["x = r'''a\\", "if b'''", "for"], .python)
        #expect(kinds(tokens[1]).first == .string)
        // "if" sits inside the string; the line ends after it closes.
        #expect(tokens[1].count == 1)
        #expect(kinds(tokens[2]) == [.keyword])
    }

    @Test func swiftBlockCommentSpansLines() {
        let tokens = run(["let a = 1 /* start", "  let inside = true", "  end */ let b = 2", "let c = 3"], .swift)
        #expect(kinds(tokens[0]).last == .comment)
        #expect(kinds(tokens[1]) == [.comment])
        // Comment up to "*/", then real tokens.
        #expect(tokens[2].first?.kind == .comment)
        #expect(tokens[2].first?.range == 0..<8)
        #expect(kinds(tokens[2]).dropFirst().contains(.keyword))
        #expect(kinds(tokens[3]).contains(.keyword))
    }

    @Test func swiftMultiLineString() {
        let tokens = run([#"let s = """"#, "  return if while", #"  """"#, "return"], .swift)
        #expect(kinds(tokens[1]) == [.string])
        #expect(kinds(tokens[2]) == [.string])
        #expect(kinds(tokens[3]) == [.keyword])
    }

    @Test func typescriptTemplateLiteral() {
        let tokens = run(["const s = `line one", "  const not = 1 \\` still", "end` + x", "const y = 1"], .typescript)
        #expect(kinds(tokens[1]) == [.string])
        #expect(tokens[2].first?.kind == .string)
        #expect(tokens[2].first?.range == 0..<4)
        #expect(kinds(tokens[3]).first == .keyword)
    }

    @Test func closedTemplateDoesNotCarry() {
        let tokens = run(["const s = `a ${b}`", "const y = 1"], .typescript)
        #expect(kinds(tokens[1]).first == .keyword)
    }

    @Test func goRawStringHasNoEscapes() {
        // A backslash before the closing backtick doesn't escape it in Go.
        let tokens = run(["s := `a", "b\\` + x", "func"], .go)
        #expect(tokens[1].first?.range == 0..<3)
        #expect(kinds(tokens[2]) == [.keyword])
    }

    @Test func singleLineCallerCarriesNothing() {
        #expect(kinds(SyntaxHighlighter.tokens("  let inside = true", language: .swift)).contains(.keyword))
    }

    @Test func diffHunksCarryPerSideAndResetAtHeaders() throws {
        let diff = """
        diff --git a/a.py b/a.py
        --- a/a.py
        +++ b/a.py
        @@ -1,4 +1,4 @@
         def f():
        -    \"\"\"Old doc in
        +    \"\"\"New doc in
             with the if keyword
             \"\"\"
        @@ -20,1 +20,1 @@
        -if a:
        +if b:
        """
        let file = try #require(UnifiedDiffParser.parse(diff).first)
        let rendered = DiffRenderer.render(file, contents: nil, expanded: [], canExpand: false)
        let lines = rendered.unified.compactMap { row -> DiffRenderLine? in
            if case let .line(_, line) = row { return line }
            return nil
        }
        let body = lines.first { String($0.text.characters).contains("with the if keyword") }
        let ifRange = try #require(body.flatMap { $0.text.range(of: "if") })
        #expect(body?.text[ifRange].foregroundColor == SyntaxPalette.string)
        // The second hunk starts fresh: `if` is a keyword again.
        let last = try #require(lines.last)
        let lastIf = try #require(last.text.range(of: "if"))
        #expect(last.text[lastIf].foregroundColor == SyntaxPalette.keyword)
    }
}
