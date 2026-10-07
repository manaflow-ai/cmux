import CmuxiOSViewersCore
import Foundation
import Testing

@Suite struct SyntaxHighlighterTests {
    func spans(_ tokens: [SyntaxToken], in text: String) -> [String: SyntaxTokenKind] {
        let units = Array(text.utf16)
        return Dictionary(tokens.map { (String(decoding: units[$0.range], as: UTF16.self), $0.kind) }, uniquingKeysWith: { a, _ in a })
    }

    @Test func swiftKeywordsStringsCommentsNumbersTypes() {
        let text = "let view = Viewer(\"a // not\", 42) // tail"
        let found = spans(SyntaxHighlighter(language: .swift).highlight(text), in: text)
        #expect(found["let"] == .keyword)
        #expect(found["Viewer"] == .type)
        #expect(found["\"a // not\""] == .string)
        #expect(found["42"] == .number)
        #expect(found["// tail"] == .comment)
        #expect(found["view"] == nil)
    }

    @Test func blockCommentsAndMultilineStringsCarryAcrossLines() {
        let highlighter = SyntaxHighlighter(language: .swift)
        let (first, state) = highlighter.highlight(line: "x /* open", state: .normal)
        #expect(state == .blockComment)
        #expect(first.last?.kind == .comment)
        let (second, after) = highlighter.highlight(line: "still */ let y", state: state)
        #expect(after == .normal)
        #expect(second.first == SyntaxToken(0..<8, .comment))
        #expect(second.last?.kind == .keyword)
        let python = SyntaxHighlighter(language: .python)
        let (_, inString) = python.highlight(line: "doc = \"\"\"start", state: .normal)
        #expect(inString == .string(delimiter: "\"\"\""))
        let (closing, done) = python.highlight(line: "end\"\"\" # c", state: inString)
        #expect(done == .normal)
        #expect(closing.map(\.kind) == [.string, .comment])
    }

    @Test func wholeTextOffsetsAreAbsolute() {
        let text = "a\n// c\nlet"
        let tokens = SyntaxHighlighter(language: .swift).highlight(text)
        #expect(tokens == [SyntaxToken(2..<6, .comment), SyntaxToken(7..<10, .keyword)])
    }

    @Test func keysMarkupAndShellComments() {
        let json = "{\"name\": \"cmux\", \"on\": true}"
        let jsonSpans = spans(SyntaxHighlighter(language: .json).highlight(json), in: json)
        #expect(jsonSpans["\"name\""] == .attribute && jsonSpans["\"cmux\""] == .string && jsonSpans["true"] == .keyword)
        let html = "<a href=\"x\">link</a>"
        let htmlSpans = spans(SyntaxHighlighter(language: .html).highlight(html), in: html)
        #expect(htmlSpans["a"] == .tag && htmlSpans["href"] == .attribute && htmlSpans["\"x\""] == .string)
        let shell = "echo a#b # comment"
        let shellSpans = spans(SyntaxHighlighter(language: .shell).highlight(shell), in: shell)
        #expect(shellSpans["# comment"] == .comment && shellSpans["echo"] == .keyword)
        let sql = "SELECT * FROM t"
        #expect(spans(SyntaxHighlighter(language: .sql).highlight(sql), in: sql)["SELECT"] == .keyword)
    }

    @Test func detectsLanguagesAndFileKinds() {
        #expect(SyntaxLanguage.detect(fileName: "Sources/App/View.swift") == .swift)
        #expect(SyntaxLanguage.detect(fileName: "Makefile") == .shell)
        #expect(SyntaxLanguage.detect(fileName: "x.TSX") == .typescript)
        #expect(SyntaxLanguage.detect(fileName: ".gitignore") == .plain)
        #expect(ViewerFileKind.classify(name: "README.md") == .markdown)
        #expect(ViewerFileKind.classify(name: "a.PNG") == .image)
        #expect(ViewerFileKind.classify(name: "doc.pdf") == .pdf)
        #expect(ViewerFileKind.classify(name: "a.swift") == .text(.swift))
        #expect(ViewerFileKind.classify(name: "archive.zip") == .other)
        #expect(ViewerFileKind.classify(name: "blob", prefix: Data([0x41, 0, 0x42])) == .other)
        #expect(ViewerFileKind.classify(name: "LICENSE", prefix: Data("MIT".utf8)) == .text(.plain))
    }

    @Test func lineIndexFindsLines() {
        let index = LineIndex("ab\ncd\n\nef\n")
        #expect(index.starts == [0, 3, 6, 7])
        #expect(index.line(containing: 0) == 0)
        #expect(index.line(containing: 4) == 1)
        #expect(index.line(containing: 6) == 2)
        #expect(index.line(containing: 9) == 3)
    }
}
