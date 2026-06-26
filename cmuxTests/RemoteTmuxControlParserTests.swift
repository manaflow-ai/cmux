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

    @Test func outputPreservesMultibyteCharSplitAcrossNotifications() {
        // tmux sends pane bytes raw and can chunk a PTY read mid-character, so a
        // box-drawing `─` (E2 94 80) arrives split across two %output
        // notifications: "…E2 94" then "80…". Each half must be emitted as raw
        // bytes — NOT run through String(decoding:as: UTF8.self), which replaces
        // each incomplete half with U+FFFD (EF BF BD). ghostty's stream parser
        // reassembles the split character across process_output calls, but only if
        // it receives the original bytes. This reproduces the box-drawing
        // corruption seen in mirrored TUIs (claude) at certain sizes.
        var parser = RemoteTmuxControlStreamParser()
        var stream = Data()
        stream.append(Data("%output %1 ".utf8))
        stream.append(Data([0xe2, 0x94]))        // first 2 bytes of `─`
        stream.append(Data("\r\n".utf8))
        stream.append(Data("%output %1 ".utf8))
        stream.append(Data([0x80]))              // final byte of `─`
        stream.append(Data("\r\n".utf8))

        let messages = parser.feed(stream)
        let payload = messages.reduce(into: Data()) { acc, message in
            if case let .output(paneId, data) = message, paneId == 1 { acc.append(data) }
        }
        // Intact `─`, byte-for-byte — never a U+FFFD (EF BF BD) replacement.
        #expect(payload == Data([0xe2, 0x94, 0x80]))
        #expect(!payload.contains(0xef))
    }

    @Test func sessionChangedKeepsMultiWordName() {
        let messages = parse("%session-changed $1 my session name\r\n")
        #expect(messages == [.sessionChanged(sessionId: 1, name: "my session name")])
    }

    @Test func layoutChangeCarriesRawLayoutString() {
        let messages = parse("%layout-change @4 f92f,80x24,0,0,1 @4 1\r\n")
        #expect(messages == [.layoutChange(windowId: 4, layout: "f92f,80x24,0,0,1")])
    }

    // MARK: - Pane state seeding (cursor / region / origin ordering)

    @Test func paneStateSeedPlacesCursorLastWithOriginRelativeRow() {
        // origin mode ON + a restricted scroll region: DECSTBM and DECOM each home
        // the cursor, so the CUP must be emitted LAST, and tmux's absolute row
        // converted to the region-relative row the origin-relative CUP expects.
        let line = "cursor_x=4,cursor_y=10,"
            + "scroll_region_upper=3,scroll_region_lower=20,"
            + "cursor_flag=1,insert_flag=0,keypad_cursor_flag=0,keypad_flag=0,"
            + "wrap_flag=1,origin_flag=1,pane_height=24"
        let seq = String(
            decoding: RemoteTmuxControlMessageDecoding().paneStateSeedSequence(from: line),
            as: UTF8.self
        )
        #expect(seq.contains("\u{1b}[4;21r"))   // restricted region, 1-based 4..21
        #expect(seq.contains("\u{1b}[?6h"))     // origin mode on
        // Cursor placed LAST and region-relative: row = cy(10) - upper(3) = 7 → 8
        // (1-based), col = cx(4) + 1 = 5.
        #expect(seq.hasSuffix("\u{1b}[8;5H"))
        // No mouse flags in this fixture → no mouse DECSET is emitted.
        for mode in ["?1003h", "?1002h", "?1000h", "?9h", "?1006h", "?1005h"] {
            #expect(!seq.contains(mode))
        }
    }

    /// Builds a pane-state line with one concrete mouse tracking flag set (+ SGR).
    private func mouseSeedLine(flag: String) -> String {
        "cursor_x=0,cursor_y=0,"
            + "scroll_region_upper=0,scroll_region_lower=51,"
            + "cursor_flag=1,insert_flag=0,keypad_cursor_flag=0,keypad_flag=0,"
            + "wrap_flag=1,origin_flag=0,pane_height=52,"
            + "\(flag)=1,mouse_sgr_flag=1"
    }

    @Test(arguments: [
        ("mouse_all_flag", "\u{1b}[?1003h"),      // any-event / all-motion
        ("mouse_button_flag", "\u{1b}[?1002h"),   // button-event
        ("mouse_standard_flag", "\u{1b}[?1000h"), // normal
    ])
    func paneStateSeedRestoresConcreteMouseTrackingLevel(flag: String, expected: String) {
        // Each concrete tmux flag maps to its xterm DECSET tracking level, and ONLY
        // that level is enabled (so the app gets exactly the mode it requested).
        let seq = String(
            decoding: RemoteTmuxControlMessageDecoding().paneStateSeedSequence(from: mouseSeedLine(flag: flag)),
            as: UTF8.self
        )
        #expect(seq.contains(expected))
        #expect(seq.contains("\u{1b}[?1006h"))   // SGR encoding
        for other in ["\u{1b}[?1003h", "\u{1b}[?1002h", "\u{1b}[?1000h"] where other != expected {
            #expect(!seq.contains(other))
        }
    }

    @Test func paneStateSeedIgnoresAggregateMouseAnyFlag() {
        // `mouse_any_flag` is tmux's aggregate "any mouse mode on" OR-flag, not a
        // concrete level — on its own it must NOT enable any tracking mode (else a
        // pane that only requested 1000/1002 would be over-escalated).
        let line = "cursor_x=0,cursor_y=0,"
            + "scroll_region_upper=0,scroll_region_lower=51,"
            + "cursor_flag=1,insert_flag=0,keypad_cursor_flag=0,keypad_flag=0,"
            + "wrap_flag=1,origin_flag=0,pane_height=52,"
            + "mouse_any_flag=1,mouse_all_flag=0,mouse_button_flag=0,mouse_standard_flag=0,mouse_sgr_flag=1"
        let seq = String(
            decoding: RemoteTmuxControlMessageDecoding().paneStateSeedSequence(from: line),
            as: UTF8.self
        )
        for mode in ["\u{1b}[?1003h", "\u{1b}[?1002h", "\u{1b}[?1000h"] {
            #expect(!seq.contains(mode))
        }
    }

    @Test func paneStateSeedSuppressesFullWindowRegionWithAbsoluteCursor() {
        // A full-window region (upper 0, lower height-1) is NOT seeded — it is the
        // surface default and would go stale on resize. origin off → absolute cursor.
        let line = "cursor_x=2,cursor_y=46,"
            + "scroll_region_upper=0,scroll_region_lower=51,"
            + "cursor_flag=1,insert_flag=0,keypad_cursor_flag=0,keypad_flag=0,"
            + "wrap_flag=1,origin_flag=0,pane_height=52"
        let seq = String(
            decoding: RemoteTmuxControlMessageDecoding().paneStateSeedSequence(from: line),
            as: UTF8.self
        )
        #expect(!seq.contains(";52r"))            // full-window DECSTBM suppressed
        #expect(seq.contains("\u{1b}[?6l"))       // origin off
        #expect(seq.hasSuffix("\u{1b}[47;3H"))    // absolute cursor, placed last
    }

    // MARK: - Optimistic window reorder (rapid-drag race fix)

    @Test func windowOrderApplyingReorderRearrangesSubsetInPlace() {
        // All windows reordered → result is exactly the new sequence.
        #expect(
            RemoteTmuxControlMessageDecoding().windowOrder([0, 4, 6], applyingReorder: [0, 6, 4]) == [0, 6, 4]
        )
        // A window not in the dragged subset keeps its slot; the dragged windows
        // fill the slots they occupied, in the new order.
        #expect(
            RemoteTmuxControlMessageDecoding().windowOrder([0, 4, 6, 9], applyingReorder: [6, 4, 0]) == [6, 4, 0, 9]
        )
        // No-op reorder leaves the order unchanged.
        #expect(
            RemoteTmuxControlMessageDecoding().windowOrder([0, 4, 6], applyingReorder: [0, 4, 6]) == [0, 4, 6]
        )
    }

    // MARK: - Session-end action (disconnect handling)

    @Test func sessionEndClosesDedicatedWindowWhenAnotherWindowRemains() {
        let windowId = UUID()
        // Dedicated host-owned window lost its last session and another window is
        // open → close the whole window (the disconnect UX).
        #expect(
            RemoteTmuxController.sessionEndAction(
                dedicatedWindowId: windowId, dedicatedWindowOwnedByEndingHost: true, otherMainWindowCount: 1
            ) == .closeDedicatedWindow(windowId)
        )
        #expect(
            RemoteTmuxController.sessionEndAction(
                dedicatedWindowId: windowId, dedicatedWindowOwnedByEndingHost: true, otherMainWindowCount: 3
            ) == .closeDedicatedWindow(windowId)
        )
    }

    @Test func sessionEndKeepsSoleDedicatedWindowOpen() {
        // Dedicated window but it is the ONLY window → don't close it (never leave
        // the user with zero windows); fall back to closing just the workspace.
        #expect(
            RemoteTmuxController.sessionEndAction(
                dedicatedWindowId: UUID(), dedicatedWindowOwnedByEndingHost: true, otherMainWindowCount: 0
            ) == .closeWorkspace
        )
    }

    @Test func sessionEndKeepsDedicatedWindowWithUnrelatedWorkspace() {
        // The user moved a local workspace — or another host's mirror — into the
        // dedicated window → closing the whole window would discard it. Close only
        // the dead workspace instead.
        #expect(
            RemoteTmuxController.sessionEndAction(
                dedicatedWindowId: UUID(), dedicatedWindowOwnedByEndingHost: false, otherMainWindowCount: 2
            ) == .closeWorkspace
        )
    }

    @Test func sessionEndClosesWorkspaceWhenNotDedicated() {
        // No dedicated window (host still has other sessions, or a shared/socket
        // mirror) → only the dead workspace closes, regardless of window count.
        #expect(
            RemoteTmuxController.sessionEndAction(
                dedicatedWindowId: nil, dedicatedWindowOwnedByEndingHost: false, otherMainWindowCount: 0
            ) == .closeWorkspace
        )
        #expect(
            RemoteTmuxController.sessionEndAction(
                dedicatedWindowId: nil, dedicatedWindowOwnedByEndingHost: true, otherMainWindowCount: 5
            ) == .closeWorkspace
        )
    }

    // MARK: - Mirror tab reorder (out-of-band tmux window reorder)

    @Test func mirrorTabReorderFollowsRemoteWindowOrder() {
        let a = UUID(), b = UUID(), c = UUID()
        // Remote moved the windows → cmux tabs rearrange to match.
        #expect(RemoteTmuxSessionMirror.mirrorTabReorder(current: [a, b, c], requested: [c, a, b]) == [c, a, b])
        // A requested id that has no tab yet (filtered out) still yields the valid
        // reorder of the present tabs.
        #expect(RemoteTmuxSessionMirror.mirrorTabReorder(current: [a, b], requested: [b, a, UUID()]) == [b, a])
    }

    @Test func mirrorTabReorderNoOpsWhenAlreadyOrdered() {
        let a = UUID(), b = UUID(), c = UUID()
        #expect(RemoteTmuxSessionMirror.mirrorTabReorder(current: [a, b, c], requested: [a, b, c]) == nil)
    }

    @Test func mirrorTabReorderSkipsWhenSetsDiverge() {
        let a = UUID(), b = UUID(), c = UUID()
        // Requested is missing a present tab → not a permutation → leave untouched.
        #expect(RemoteTmuxSessionMirror.mirrorTabReorder(current: [a, b, c], requested: [a, b]) == nil)
        // Requested drops one present tab and only reorders the rest → sets diverge.
        #expect(RemoteTmuxSessionMirror.mirrorTabReorder(current: [a, b, c], requested: [c, b]) == nil)
    }

    @Test func singlePaneDisplaySeedsOnlySinglePaneWindows() throws {
        let singlePane = RemoteTmuxWindow(
            id: 1,
            width: 80,
            height: 24,
            layout: try #require(RemoteTmuxRawLayoutParser.parse("80x24,0,0,1"))
        )
        let multiPane = RemoteTmuxWindow(
            id: 2,
            width: 120,
            height: 40,
            layout: try #require(RemoteTmuxRawLayoutParser.parse("abcd,120x40,0,0{60x40,0,0,4,59x40,61,0,5}"))
        )

        #expect(RemoteTmuxSessionMirror.shouldSeedSinglePaneDisplay(for: singlePane))
        #expect(!RemoteTmuxSessionMirror.shouldSeedSinglePaneDisplay(for: multiPane))
    }

    // MARK: - Reconnect: session-gone classification

    @Test func stderrSessionGoneIsDetected() {
        // A reconnect that reaches the host but finds the session/server gone is a
        // genuine end (stop retrying, close).
        #expect(RemoteTmuxControlMessageDecoding().stderrIndicatesSessionGone("can't find session: work"))
        #expect(RemoteTmuxControlMessageDecoding().stderrIndicatesSessionGone("no server running on /tmp/tmux-501/default"))
        #expect(RemoteTmuxControlMessageDecoding().stderrIndicatesSessionGone("lost server"))
        #expect(RemoteTmuxControlMessageDecoding().stderrIndicatesSessionGone("ERROR: SESSION NOT FOUND"))
    }

    @Test func stderrTransientFailureIsNotSessionGone() {
        // Network/transport failures must NOT be classified as session-gone — the
        // reconnect loop keeps retrying through these.
        #expect(!RemoteTmuxControlMessageDecoding().stderrIndicatesSessionGone(
            "ssh: connect to host example.com port 22: Operation timed out"))
        #expect(!RemoteTmuxControlMessageDecoding().stderrIndicatesSessionGone(
            "ssh: connect to host x port 22: No route to host"))
        #expect(!RemoteTmuxControlMessageDecoding().stderrIndicatesSessionGone("Connection to host closed."))
        #expect(!RemoteTmuxControlMessageDecoding().stderrIndicatesSessionGone(""))
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

/// Behavior tests for the per-pane foreground classification
/// (`#{alternate_on}|#{pane_current_command}`) that drives BOTH the reflow
/// suppression and the kill-window/kill-pane close confirmation — exercised on
/// raw subscription values as tmux delivers them.
@Suite struct RemoteTmuxPaneForegroundStateTests {
    private typealias State = RemoteTmuxControlConnection.PaneForegroundState

    @Test func idleShellIsNeitherActiveNorNoReflow() {
        let state = State(rawValue: "0|bash")
        #expect(!state.hasActiveCommand)
        #expect(!state.suppressesReflow)
    }

    @Test func loginShellDashVariantIsIdle() {
        let state = State(rawValue: "0|-zsh")
        #expect(!state.hasActiveCommand)
        #expect(!state.suppressesReflow)
    }

    @Test func foregroundCommandIsActive() {
        // `sleep 10` in a remote pane: pane_current_command reports "sleep".
        let state = State(rawValue: "0|sleep")
        #expect(state.hasActiveCommand)
        #expect(state.suppressesReflow)
    }

    @Test func alternateScreenIsActiveEvenForShellCommandName() {
        let state = State(rawValue: "1|bash")
        #expect(state.hasActiveCommand)
        #expect(state.suppressesReflow)
    }

    @Test func fullScreenTUIIsActive() {
        let state = State(rawValue: "1|vim")
        #expect(state.hasActiveCommand)
        #expect(state.suppressesReflow)
    }

    /// The two policies deliberately diverge on an unclassifiable value: reflow
    /// stays suppressed (rewrapping a TUI corrupts it) while close confirmation
    /// must NOT fire (it would add a dialog to every close of a healthy shell
    /// pane that simply hasn't reported yet).
    @Test func emptyOrGarbageValueSuppressesReflowButIsNotActive() {
        for raw in ["", "0|", "garbage-without-separator", "  \n"] {
            let state = State(rawValue: raw)
            #expect(state.suppressesReflow, "raw=\(raw)")
            #expect(!state.hasActiveCommand, "raw=\(raw)")
        }
    }

    @Test func surroundingWhitespaceIsTrimmed() {
        let state = State(rawValue: " 0|node \r\n")
        #expect(!state.alternateOn)
        #expect(state.command == "node")
        #expect(state.hasActiveCommand)
    }
}

/// The `refresh-client -B` subscribe lines must keep their `name:target:format`
/// argument double-quoted: tmux's command parser rejects an unquoted `#{…}`
/// mid-argument with `parse error: syntax error` (verified on tmux 3.6a), and
/// control mode silently drops the `%error` result — the subscription then
/// never exists, a pane's live foreground/cwd state never updates, and the
/// kill close-confirmation sees a stale idle shell forever.
@Suite struct RemoteTmuxSubscriptionCommandTests {
    @Test @MainActor func reflowSubscribeCommandKeepsFormatQuoted() {
        #expect(
            RemoteTmuxControlCommandBuilder().paneReflowSubscriptionCommand(paneId: 15)
                == "refresh-client -B \"cmux_reflow_15:%15:#{alternate_on}|#{pane_current_command}\""
        )
    }

    @Test @MainActor func cwdSubscribeCommandKeepsFormatQuoted() {
        #expect(
            RemoteTmuxControlCommandBuilder().panePathSubscriptionCommand(paneId: 7)
                == "refresh-client -B \"cmux_cwd_7:%7:#{pane_current_path}\""
        )
    }
}

/// Close-time activity queries: the wire commands (same quoting constraint as
/// the subscriptions) and the per-line `%<pane>|<alt>|<command>` result parse
/// that feeds the kill close-confirmation.
@Suite struct RemoteTmuxActivityQueryTests {
    @Test @MainActor func windowQueryCommandKeepsFormatQuoted() {
        #expect(
            RemoteTmuxControlCommandBuilder().windowActivityQueryCommand(windowId: 3)
                == "list-panes -t @3 -F \"#{pane_id}|#{alternate_on}|#{pane_current_command}\""
        )
    }

    @Test @MainActor func paneQueryCommandKeepsFormatQuoted() {
        #expect(
            RemoteTmuxControlCommandBuilder().paneActivityQueryCommand(paneId: 9)
                == "display-message -p -t %9 -F \"#{pane_id}|#{alternate_on}|#{pane_current_command}\""
        )
    }

    @Test @MainActor func parsesActiveCommandLine() {
        let parsed = RemoteTmuxControlCommandBuilder().parseActivityQueryLine("%5|0|sleep")
        #expect(parsed?.paneId == 5)
        #expect(parsed?.state.hasActiveCommand == true)
        #expect(parsed?.state.command == "sleep")
    }

    @Test @MainActor func parsesIdleShellLine() {
        let parsed = RemoteTmuxControlCommandBuilder().parseActivityQueryLine("%12|0|bash")
        #expect(parsed?.paneId == 12)
        #expect(parsed?.state.hasActiveCommand == false)
    }

    @Test @MainActor func parsesAltScreenLine() {
        let parsed = RemoteTmuxControlCommandBuilder().parseActivityQueryLine("%7|1|vim")
        #expect(parsed?.paneId == 7)
        #expect(parsed?.state.alternateOn == true)
        #expect(parsed?.state.hasActiveCommand == true)
    }

    @Test @MainActor func commandContainingSeparatorSurvives() {
        // maxSplits strips only the pane id; the state parser strips only the
        // alternate_on flag — a pipe in the command name stays in the command.
        let parsed = RemoteTmuxControlCommandBuilder().parseActivityQueryLine("%5|0|my|weird")
        #expect(parsed?.state.command == "my|weird")
        #expect(parsed?.state.hasActiveCommand == true)
    }

    @Test @MainActor func rejectsLinesWithoutPaneId() {
        #expect(RemoteTmuxControlCommandBuilder().parseActivityQueryLine("0|bash") == nil)
        #expect(RemoteTmuxControlCommandBuilder().parseActivityQueryLine("garbage") == nil)
        #expect(RemoteTmuxControlCommandBuilder().parseActivityQueryLine("") == nil)
    }
}

/// Naming the kill-window confirmation dialog from the live foreground
/// classification (`RemoteTmuxController.mirrorTabActivity`) so it can't lag the
/// tab's own tmux automatic-rename.
@Suite struct RemoteTmuxMirrorTabActivityTests {
    private typealias State = RemoteTmuxControlConnection.PaneForegroundState

    @Test @MainActor func namesTheActivePaneCommand() {
        let activity = RemoteTmuxController.mirrorTabActivity(
            states: [1: State(rawValue: "0|bash"), 2: State(rawValue: "0|sleep")],
            paneOrder: [1, 2], activePaneId: nil
        )
        #expect(activity.hasActiveCommand)
        #expect(activity.activeCommandName == "sleep")
    }

    @Test @MainActor func prefersTheFocusedPaneWhenSeveralAreActive() {
        let activity = RemoteTmuxController.mirrorTabActivity(
            states: [1: State(rawValue: "0|vim"), 2: State(rawValue: "0|sleep")],
            paneOrder: [1, 2], activePaneId: 2
        )
        #expect(activity.activeCommandName == "sleep")
    }

    @Test @MainActor func namesAnActiveBackgroundPaneWhenTheFocusedOneIsIdle() {
        // Focused pane idle, another pane active → fall past the focused pane to
        // the active one in layout order (the deduped second half of the scan).
        let activity = RemoteTmuxController.mirrorTabActivity(
            states: [1: State(rawValue: "0|bash"), 2: State(rawValue: "0|sleep")],
            paneOrder: [1, 2], activePaneId: 1
        )
        #expect(activity.hasActiveCommand)
        #expect(activity.activeCommandName == "sleep")
    }

    @Test @MainActor func idleWindowHasNoNameAndIsNotActive() {
        let activity = RemoteTmuxController.mirrorTabActivity(
            states: [1: State(rawValue: "0|bash"), 2: State(rawValue: "0|zsh")],
            paneOrder: [1, 2], activePaneId: 1
        )
        #expect(!activity.hasActiveCommand)
        #expect(activity.activeCommandName == nil)
    }

    @Test @MainActor func unclassifiedWindowIsIdle() {
        let activity = RemoteTmuxController.mirrorTabActivity(
            states: [:], paneOrder: [1, 2], activePaneId: nil
        )
        #expect(!activity.hasActiveCommand)
        #expect(activity.activeCommandName == nil)
    }
}
