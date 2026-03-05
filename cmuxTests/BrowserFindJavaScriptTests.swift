import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class BrowserFindJavaScriptTests: XCTestCase {

    // MARK: - searchScript

    func testSearchScriptReturnsNonEmptyJavaScript() {
        let js = BrowserFindJavaScript.searchScript(query: "hello")
        XCTAssertFalse(js.isEmpty)
        XCTAssertTrue(js.contains("hello"))
    }

    func testSearchScriptEmptyQueryReturnsEarlyReturn() {
        let js = BrowserFindJavaScript.searchScript(query: "")
        XCTAssertTrue(js.contains("total: 0"))
    }

    // MARK: - nextScript / previousScript

    func testNextScriptReturnsValidJavaScript() {
        let js = BrowserFindJavaScript.nextScript()
        XCTAssertFalse(js.isEmpty)
        XCTAssertTrue(js.contains("__cmuxFindMatches"))
    }

    func testPreviousScriptReturnsValidJavaScript() {
        let js = BrowserFindJavaScript.previousScript()
        XCTAssertFalse(js.isEmpty)
        XCTAssertTrue(js.contains("__cmuxFindMatches"))
    }

    // MARK: - clearScript

    func testClearScriptReturnsValidJavaScript() {
        let js = BrowserFindJavaScript.clearScript()
        XCTAssertFalse(js.isEmpty)
        XCTAssertTrue(js.contains("__cmux-find"))
    }

    // MARK: - jsStringEscape

    func testEscapesDoubleQuotes() {
        let result = BrowserFindJavaScript.jsStringEscape(#"say "hello""#)
        XCTAssertEqual(result, #"say \"hello\""#)
    }

    func testEscapesBackslashes() {
        let result = BrowserFindJavaScript.jsStringEscape(#"path\to\file"#)
        XCTAssertEqual(result, #"path\\to\\file"#)
    }

    func testEscapesNewlines() {
        let result = BrowserFindJavaScript.jsStringEscape("line1\nline2")
        XCTAssertEqual(result, "line1\\nline2")
    }

    func testEscapesCarriageReturns() {
        let result = BrowserFindJavaScript.jsStringEscape("line1\rline2")
        XCTAssertEqual(result, "line1\\rline2")
    }

    func testEscapesTabs() {
        let result = BrowserFindJavaScript.jsStringEscape("col1\tcol2")
        XCTAssertEqual(result, "col1\\tcol2")
    }

    func testPlainTextPassesThrough() {
        let result = BrowserFindJavaScript.jsStringEscape("hello world 123")
        XCTAssertEqual(result, "hello world 123")
    }

    func testJapaneseTextPassesThrough() {
        let result = BrowserFindJavaScript.jsStringEscape("こんにちは")
        XCTAssertEqual(result, "こんにちは")
    }

    func testMixedSpecialCharacters() {
        let result = BrowserFindJavaScript.jsStringEscape(#"a\"b\nc"#)
        XCTAssertEqual(result, #"a\\\"b\\nc"#)
    }

    func testEscapesNullByte() {
        let result = BrowserFindJavaScript.jsStringEscape("a\0b")
        XCTAssertEqual(result, "a\\0b")
    }

    func testEscapesLineSeparator() {
        let result = BrowserFindJavaScript.jsStringEscape("a\u{2028}b")
        XCTAssertEqual(result, "a\\u2028b")
    }

    func testEscapesParagraphSeparator() {
        let result = BrowserFindJavaScript.jsStringEscape("a\u{2029}b")
        XCTAssertEqual(result, "a\\u2029b")
    }

    // MARK: - searchScript escaping integration

    func testSearchScriptEscapesQueryInOutput() {
        let js = BrowserFindJavaScript.searchScript(query: #"test"injection"#)
        // The double quote should be escaped, not breaking the JS string literal.
        XCTAssertTrue(js.contains(#"test\"injection"#))
        XCTAssertFalse(js.contains(#"test"injection"#))
    }

    func testSearchScriptHandlesLineSeparator() {
        let js = BrowserFindJavaScript.searchScript(query: "test\u{2028}break")
        XCTAssertTrue(js.contains("\\u2028"))
    }
}
