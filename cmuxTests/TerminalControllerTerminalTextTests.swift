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

    func testTerminalTextOutputReturnsPlainViewportWithoutEncodingRoundTrip() throws {
        let result = TerminalController.terminalTextOutput(
            from: TerminalController.TerminalTextRawSnapshot(
                viewport: "prompt λ\nresult ✓",
                screen: nil,
                history: nil,
                active: nil
            ),
            includeScrollback: false,
            lineLimit: 1
        )

        XCTAssertEqual(try result.get(), "result ✓")
    }

    func testTerminalTextBase64ResponsePreservesSocketBytes() {
        let response = TerminalController.terminalTextBase64Response(
            from: TerminalController.TerminalTextRawSnapshot(
                viewport: "prompt λ\nresult ✓",
                screen: nil,
                history: nil,
                active: nil
            ),
            includeScrollback: false,
            lineLimit: nil
        )

        XCTAssertEqual(response, "OK cHJvbXB0IM67CnJlc3VsdCDinJM=")
    }

    func testTerminalTextOutputAndBase64ResponsePreserveEmptyText() throws {
        let snapshot = TerminalController.TerminalTextRawSnapshot(
            viewport: "",
            screen: nil,
            history: nil,
            active: nil
        )

        XCTAssertEqual(
            try TerminalController.terminalTextOutput(
                from: snapshot,
                includeScrollback: false,
                lineLimit: nil
            ).get(),
            ""
        )
        XCTAssertEqual(
            TerminalController.terminalTextBase64Response(
                from: snapshot,
                includeScrollback: false,
                lineLimit: nil
            ),
            "OK "
        )
    }

    func testDecodeTerminalTextReadsBorrowedSelectionBytes() {
        let bytes = Array("selected λ".utf8)

        let decoded = bytes.withUnsafeBytes { buffer in
            TerminalController.decodeTerminalText(buffer)
        }

        XCTAssertEqual(decoded, "selected λ")
    }

    func testDecodeTerminalTextPreservesInvalidUTF8ReplacementSemantics() {
        let bytes: [UInt8] = [0x66, 0x80, 0x6f]

        let decoded = bytes.withUnsafeBytes { buffer in
            TerminalController.decodeTerminalText(buffer)
        }

        XCTAssertEqual(decoded, "f\u{FFFD}o")
    }

}
