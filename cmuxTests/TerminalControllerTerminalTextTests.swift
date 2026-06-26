import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("TerminalController terminal text payload")
struct TerminalControllerTerminalTextTests {
    @Test func tailTerminalLinesPreservesSplitSuffixSemanticsWithoutFullSplit() {
        #expect(TerminalController.tailTerminalLines("a\nb\nc", maxLines: 2) == "b\nc")
        #expect(TerminalController.tailTerminalLines("a\nb\n", maxLines: 2) == "b\n")
        #expect(TerminalController.tailTerminalLines("a", maxLines: 2) == "a")
        #expect(TerminalController.tailTerminalLines("a\nb", maxLines: 0) == "")
    }

    @Test func terminalTextPayloadTailsScrollbackBeforeEncoding() throws {
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

    /// Regression for https://github.com/manaflow-ai/cmux/issues/6500: a bounded
    /// read without scrollback must come from the viewport only and never touch
    /// the (potentially huge) screen/history snapshot fields. Here the
    /// screen/history are intentionally large; the payload must ignore them
    /// entirely and tail the small viewport, proving no full-history work runs.
    @Test func terminalTextPayloadWithoutScrollbackUsesViewportOnly() throws {
        let hugeHistory = String(repeating: "scrollback line\n", count: 100_000)
        let result = TerminalController.terminalTextPayload(
            from: TerminalController.TerminalTextRawSnapshot(
                viewport: "v1\nv2\nv3\nv4",
                screen: hugeHistory,
                history: hugeHistory,
                active: hugeHistory
            ),
            includeScrollback: false,
            lineLimit: 2
        )
        let payload = try result.get()

        #expect(payload.text == "v3\nv4")
        #expect(payload.base64 == Data("v3\nv4".utf8).base64EncodedString())
    }
}
