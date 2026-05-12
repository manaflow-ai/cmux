import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class MarkdownMermaidRendererTests: XCTestCase {
    func testMermaidFenceLanguageDetectionUsesFirstFenceTokenCaseInsensitively() {
        XCTAssertTrue(MarkdownCodeBlockLanguage.isMermaid("mermaid"))
        XCTAssertTrue(MarkdownCodeBlockLanguage.isMermaid(" Mermaid "))
        XCTAssertTrue(MarkdownCodeBlockLanguage.isMermaid("mermaid flowchart"))

        XCTAssertFalse(MarkdownCodeBlockLanguage.isMermaid(nil))
        XCTAssertFalse(MarkdownCodeBlockLanguage.isMermaid(""))
        XCTAssertFalse(MarkdownCodeBlockLanguage.isMermaid("swift"))
        XCTAssertFalse(MarkdownCodeBlockLanguage.isMermaid("not-mermaid"))
    }

    func testMermaidHTMLPayloadEscapesDiagramSourceInsideInlineScript() {
        let source = "flowchart LR\nA[</script><script>bad()</script>] --> B"

        let html = MarkdownMermaidHTMLDocument.html(source: source, theme: .dark)

        XCTAssertTrue(html.contains("const source = "))
        XCTAssertTrue(html.contains("const theme = \"dark\";"))
        XCTAssertFalse(html.contains("</script><script>bad()</script>"))
        XCTAssertTrue(html.contains("\\u003C/script\\u003E\\u003Cscript\\u003Ebad()\\u003C/script\\u003E"))
    }

    func testMermaidScriptEventParsesHeightAndErrorMessages() {
        XCTAssertEqual(
            MarkdownMermaidScriptEvent(body: ["type": "height", "height": 240.0, "requestID": "request-1"]),
            .height(240.0, requestID: "request-1")
        )
        XCTAssertEqual(
            MarkdownMermaidScriptEvent(body: ["type": "error", "message": "Parse error", "requestID": "request-2"]),
            .error("Parse error", requestID: "request-2")
        )
        XCTAssertNil(MarkdownMermaidScriptEvent(body: ["type": "height", "height": "240", "requestID": "request-3"]))
        XCTAssertNil(MarkdownMermaidScriptEvent(body: ["type": "height", "height": 240.0]))
        XCTAssertNil(MarkdownMermaidScriptEvent(body: ["type": "unknown", "requestID": "request-4"]))
    }
}
