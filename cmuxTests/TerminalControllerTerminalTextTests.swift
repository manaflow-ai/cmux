import Testing
import Darwin
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
@MainActor
struct TerminalControllerTerminalTextTests {
    @Test
    func tailTerminalLinesPreservesSplitSuffixSemanticsWithoutFullSplit() {
        #expect(TerminalController.tailTerminalLines("a\nb\nc", maxLines: 2) == "b\nc")
        #expect(TerminalController.tailTerminalLines("a\nb\n", maxLines: 2) == "b\n")
        #expect(TerminalController.tailTerminalLines("a", maxLines: 2) == "a")
        #expect(TerminalController.tailTerminalLines("a\nb", maxLines: 0) == "")
    }

    @Test
    func terminalTextPayloadTailsScrollbackBeforeEncoding() throws {
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

        #expect(payload.text == "three\nfour\nfive")
        #expect(payload.base64 == Data("three\nfour\nfive".utf8).base64EncodedString())
    }

    @Test
    func terminalTextOutputReturnsPlainViewportWithoutEncodingRoundTrip() throws {
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

        #expect(try result.get() == "result ✓")
    }

    @Test
    func terminalTextBase64ResponsePreservesSocketBytes() {
        let text = "prompt λ\nresult ✓"
        let response = TerminalController.terminalTextBase64Response(
            from: TerminalController.TerminalTextRawSnapshot(
                viewport: text,
                screen: nil,
                history: nil,
                active: nil
            ),
            includeScrollback: false,
            lineLimit: nil
        )

        #expect(response == "OK cHJvbXB0IM67CnJlc3VsdCDinJM=")
    }

    @Test
    func terminalTextOutputAndBase64ResponsePreserveEmptyText() throws {
        let snapshot = TerminalController.TerminalTextRawSnapshot(
            viewport: "",
            screen: nil,
            history: nil,
            active: nil
        )

        #expect(
            try TerminalController.terminalTextOutput(
                from: snapshot,
                includeScrollback: false,
                lineLimit: nil
            ).get() == ""
        )
        #expect(
            TerminalController.terminalTextBase64Response(
                from: snapshot,
                includeScrollback: false,
                lineLimit: nil
            ) == "OK "
        )
    }

    @Test
    func decodeTerminalTextReadsBorrowedSelectionBytes() {
        let bytes = Array("selected λ".utf8)

        let decoded = bytes.withUnsafeBytes { buffer in
            TerminalController.decodeTerminalText(buffer)
        }

        #expect(decoded == "selected λ")
    }

    @Test
    func decodeTerminalTextPreservesInvalidUTF8ReplacementSemantics() {
        let bytes: [UInt8] = [0x66, 0x80, 0x6f]

        let decoded = bytes.withUnsafeBytes { buffer in
            TerminalController.decodeTerminalText(buffer)
        }

        #expect(decoded == "f\u{FFFD}o")
    }

}
