import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for the incremental `tmux -CC` control-mode stream parser and
/// the raw window-layout parser. These exercise the real parsers on byte input
/// and assert the emitted messages / nodes — not source text.
@Suite struct RemoteTmuxControlParserTests {
    /// Feeds a control-mode protocol string (lines are `\r\n`-terminated as the
    /// SSH `-tt` pty delivers them) and collects the emitted messages.
    private func parse(_ protocolText: String) -> [RemoteTmuxControlMessage] {
        var parser = RemoteTmuxControlStreamParser()
        return parser.feed(Data(protocolText.utf8))
    }

    // MARK: - Command-block framing (the FIFO-desync fix)

    @Test func blockTerminatedOnlyByMatchingCommandNumber() {
        // The captured output inside command #7's block itself contains a line
        // that looks like a terminator for a *different* command (#9). tmux does
        // not escape command output, so that inner line must be treated as
        // content; only `%end … 7 …` (matching the %begin's command number)
        // closes the block. Matching on prefix alone truncates the block and
        // permanently desyncs the command-correlation FIFO.
        let messages = parse(
            "%begin 1700000000 7 1\r\n"
            + "captured pane line one\r\n"
            + "%end 1700000000 9 1\r\n"
            + "captured pane line two\r\n"
            + "%end 1700000000 7 1\r\n"
        )
        #expect(messages == [
            .commandResult(
                commandNumber: 7,
                lines: [
                    "captured pane line one",
                    "%end 1700000000 9 1",
                    "captured pane line two",
                ],
                isError: false
            )
        ])
    }

    @Test func errorBlockTerminatesAndIsFlagged() {
        let messages = parse(
            "%begin 1700000000 3 1\r\n"
            + "no such window\r\n"
            + "%error 1700000000 3 1\r\n"
        )
        #expect(messages == [
            .commandResult(commandNumber: 3, lines: ["no such window"], isError: true)
        ])
    }

    @Test func blockContentPreservesEscapeBackslash() {
        // `capture-pane -e` output can contain ESC `\` (an OSC String Terminator).
        // ST stripping is scoped to notification lines, so block content must
        // survive verbatim — otherwise the painted pane loses bytes.
        let esc = "\u{1b}\\" // ESC backslash (ST)
        let messages = parse(
            "%begin 1700000000 4 0\r\n"
            + "title\(esc)tail\r\n"
            + "%end 1700000000 4 0\r\n"
        )
        #expect(messages == [
            .commandResult(commandNumber: 4, lines: ["title\(esc)tail"], isError: false)
        ])
    }

    @Test func enterDCSIsStrippedAndEmittedBeforeFirstBlock() {
        // The real stream prepends the `ESC P 1000 p` enter sequence to the
        // first %begin line; the parser emits `.enter` and strips the framing.
        let enter = "\u{1b}P1000p"
        let messages = parse(
            enter + "%begin 1700000000 1 0\r\n"
            + "ok\r\n"
            + "%end 1700000000 1 0\r\n"
        )
        #expect(messages == [
            .enter,
            .commandResult(commandNumber: 1, lines: ["ok"], isError: false),
        ])
    }

    @Test func partialLinesBufferAcrossFeeds() {
        var parser = RemoteTmuxControlStreamParser()
        // A notification split mid-line across two chunks must not emit early.
        #expect(parser.feed(Data("%window-ad".utf8)).isEmpty)
        let messages = parser.feed(Data("d @4\r\n".utf8))
        #expect(messages == [.windowAdd(windowId: 4)])
    }

    // MARK: - %output octal unescaping (the overflow-trap fix)

    @Test func outputUnescapesValidOctal() {
        // \033 = ESC, \012 = newline.
        let messages = parse("%output %2 hi\\012\\033[1m\r\n")
        #expect(messages == [
            .output(paneId: 2, data: Data([0x68, 0x69, 0x0a, 0x1b, 0x5b, 0x31, 0x6d]))
        ])
    }

    @Test func outputDoesNotTrapOnOutOfRangeOctal() {
        // \777 = 511, outside a byte: must be emitted literally, never trapped.
        let messages = parse("%output %5 \\777x\r\n")
        #expect(messages == [
            .output(paneId: 5, data: Data("\\777x".utf8))
        ])
    }

    @Test func sessionChangedKeepsMultiWordName() {
        let messages = parse("%session-changed $1 my session name\r\n")
        #expect(messages == [.sessionChanged(sessionId: 1, name: "my session name")])
    }

    @Test func layoutChangeCarriesRawLayoutString() {
        let messages = parse("%layout-change @4 f92f,80x24,0,0,1 @4 1\r\n")
        #expect(messages == [.layoutChange(windowId: 4, layout: "f92f,80x24,0,0,1")])
    }

    // MARK: - Raw layout parser

    @Test func parsesLeafLayoutWithChecksum() {
        let node = RemoteTmuxRawLayoutParser.parse("f92f,80x24,0,0,1")
        #expect(node == RemoteTmuxLayoutNode(
            width: 80, height: 24, x: 0, y: 0, content: .pane(1)
        ))
    }

    @Test func parsesLeafLayoutWithoutChecksum() {
        let node = RemoteTmuxRawLayoutParser.parse("80x24,0,0,7")
        #expect(node?.content == .pane(7))
    }

    @Test func parsesHorizontalSplit() {
        let node = RemoteTmuxRawLayoutParser.parse("abcd,120x40,0,0{60x40,0,0,4,59x40,61,0,5}")
        #expect(node == RemoteTmuxLayoutNode(
            width: 120, height: 40, x: 0, y: 0,
            content: .horizontal([
                RemoteTmuxLayoutNode(width: 60, height: 40, x: 0, y: 0, content: .pane(4)),
                RemoteTmuxLayoutNode(width: 59, height: 40, x: 61, y: 0, content: .pane(5)),
            ])
        ))
        #expect(node?.paneIDsInOrder == [4, 5])
    }

    @Test func parsesVerticalSplit() {
        let node = RemoteTmuxRawLayoutParser.parse("abcd,80x40,0,0[80x20,0,0,1,80x19,0,21,2]")
        #expect(node?.content == .vertical([
            RemoteTmuxLayoutNode(width: 80, height: 20, x: 0, y: 0, content: .pane(1)),
            RemoteTmuxLayoutNode(width: 80, height: 19, x: 0, y: 21, content: .pane(2)),
        ]))
    }

    @Test func parsesNestedSplit() {
        // A horizontal split whose right child is itself a vertical split.
        let node = RemoteTmuxRawLayoutParser.parse(
            "abcd,120x40,0,0{60x40,0,0,4,59x40,61,0[59x20,61,0,5,59x19,61,21,8]}"
        )
        #expect(node?.paneIDsInOrder == [4, 5, 8])
    }

    @Test func rejectsSingleChildSplit() {
        // A split must have at least two children; one child is malformed.
        #expect(RemoteTmuxRawLayoutParser.parse("abcd,60x40,0,0{60x40,0,0,4}") == nil)
    }

    @Test func rejectsGarbageLayout() {
        #expect(RemoteTmuxRawLayoutParser.parse("not-a-layout") == nil)
        #expect(RemoteTmuxRawLayoutParser.parse("") == nil)
        // Trailing junk after a valid node fails (cursor must reach the end).
        #expect(RemoteTmuxRawLayoutParser.parse("80x24,0,0,1xyz") == nil)
    }
}
