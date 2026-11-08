import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct GlobalSearchTerminalTextTests {
    @Test func plainTextPassesThroughUnchanged() {
        let text = "npm ERR! module not found\nnpm ERR! see log\n"

        #expect(GlobalSearchTerminalText.strippedVT(text) == text)
    }

    @Test func stripsSGRColorSequences() {
        let styled = "\u{1B}[31merror\u{1B}[0m: connection refused"

        #expect(GlobalSearchTerminalText.strippedVT(styled) == "error: connection refused")
    }

    @Test func stripsCursorAndEraseSequences() {
        let redrawn = "\u{1B}[2J\u{1B}[H\u{1B}[1;32mready\u{1B}[K"

        #expect(GlobalSearchTerminalText.strippedVT(redrawn) == "ready")
    }

    @Test func stripsHyperlinkOSCTerminatedByBell() {
        let linked = "see \u{1B}]8;;https://example.test\u{07}the docs\u{1B}]8;;\u{07} now"

        #expect(GlobalSearchTerminalText.strippedVT(linked) == "see the docs now")
    }

    @Test func stripsOSCTerminatedByStringTerminator() {
        let titled = "\u{1B}]0;agent — zsh\u{1B}\\prompt$ ls"

        #expect(GlobalSearchTerminalText.strippedVT(titled) == "prompt$ ls")
    }

    @Test func stripsTwoByteEscapes() {
        let charset = "\u{1B}(Bplain\u{1B}=text"

        #expect(GlobalSearchTerminalText.strippedVT(charset) == "plaintext")
    }

    @Test func keepsNewlinesAndTabsButDropsOtherControls() {
        let mixed = "col1\tcol2\nrow\u{07}end\u{00}"

        #expect(GlobalSearchTerminalText.strippedVT(mixed) == "col1\tcol2\nrowend")
    }

    @Test func truncatedSequenceAtEndDoesNotLeakEscapeBytes() {
        let truncated = "tail of output\u{1B}[38;5;"

        let stripped = GlobalSearchTerminalText.strippedVT(truncated)

        #expect(stripped == "tail of output")
        #expect(!stripped.contains("\u{1B}"))
    }

    @Test func fingerprintIsStableAcrossCallsAndSensitiveToContent() {
        let text = "deploy 31771540184 succeeded"

        #expect(GlobalSearchTerminalText.fingerprint(text) == GlobalSearchTerminalText.fingerprint(text))
        #expect(GlobalSearchTerminalText.fingerprint(text) != GlobalSearchTerminalText.fingerprint(text + " "))
    }

    @Test func fingerprintOfEmptyTextIsTheOffsetBasis() {
        #expect(GlobalSearchTerminalText.fingerprint("") == 0xcbf2_9ce4_8422_2325)
    }
}
