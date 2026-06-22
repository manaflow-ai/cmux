import XCTest
import Darwin
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class TerminalControllerTerminalTextTests: XCTestCase {
    func testTailTerminalLinesPreservesSplitSuffixSemanticsWithoutFullSplit() {
        XCTAssertEqual(TerminalController.tailTerminalLines("a\nb\nc", maxLines: 2), "b\nc")
        XCTAssertEqual(TerminalController.tailTerminalLines("a\nb\n", maxLines: 2), "b\n")
        XCTAssertEqual(TerminalController.tailTerminalLines("a", maxLines: 2), "a")
        XCTAssertEqual(TerminalController.tailTerminalLines("a\nb", maxLines: 0), "")
    }

    func testTerminalTextPayloadTailsScrollbackBeforeEncoding() throws {
        let result = TerminalController.terminalTextPayload(
            from: TerminalController.TerminalTextRawSnapshot(
                viewport: nil,
                screen: "old\nscreen",
                history: "one\ntwo\nthree",
                active: "four\nfive"
            ),
            includeScrollback: true,
            lineLimit: 3
        )
        let payload = try result.get()

        XCTAssertEqual(payload.text, "three\nfour\nfive")
        XCTAssertEqual(payload.base64, Data("three\nfour\nfive".utf8).base64EncodedString())
    }

    /// Regression test for https://github.com/manaflow-ai/cmux/issues/6500.
    ///
    /// `surface.read_text --lines N` must NOT force `includeScrollback = true`.
    /// When `includeScrollback` is false, the payload is built from `viewport`
    /// only and tailed to `lineLimit` — `screen`/`history`/`active` are never
    /// consulted, so the heavy `PageFormatter` pass over full scrollback history
    /// is skipped. This test pins that contract: with `includeScrollback: false`
    /// and a `lineLimit`, the result is the tailed viewport even when scrollback
    /// fields would otherwise have produced more content.
    func testTerminalTextPayloadLineLimitTailsViewportWithoutScrollback() throws {
        let viewport = "alpha\nbeta\ngamma\ndelta\nepsilon"
        let result = TerminalController.terminalTextPayload(
            from: TerminalController.TerminalTextRawSnapshot(
                viewport: viewport,
                screen: "screen-line-1\nscreen-line-2",
                history: "history-line-1\nhistory-line-2\nhistory-line-3",
                active: "active-line-1\nactive-line-2"
            ),
            includeScrollback: false,
            lineLimit: 2
        )
        let payload = try result.get()

        XCTAssertEqual(payload.text, "delta\nepsilon")
        XCTAssertEqual(payload.base64, Data("delta\nepsilon".utf8).base64EncodedString())
    }

}
