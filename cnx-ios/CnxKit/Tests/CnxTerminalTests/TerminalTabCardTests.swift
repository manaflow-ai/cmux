import Testing
@testable import CnxTerminal

/// D5 / T-TABS-02: a tab never opened in this launch showed "Connecting to
/// <Mac>…" with a spinner in the grid forever (its session starts only when
/// its page is built). Its card shows its saved frame or the static placeholder instead.
@Suite struct TerminalTabCardTests {
    @Test func aNeverOpenedTabShowsNoSpinner() {
        #expect(!TerminalConnectionState.connecting(mac: "Mac").cardShowsConnecting(sessionStarted: false))
    }

    @Test func anOpenedTabStillShowsItsConnectionState() {
        #expect(TerminalConnectionState.connecting(mac: "Mac").cardShowsConnecting(sessionStarted: true))
        #expect(TerminalConnectionState.reattaching(mac: nil).cardShowsConnecting(sessionStarted: true))
        #expect(!TerminalConnectionState.attached.cardShowsConnecting(sessionStarted: true))
    }
}

/// Verifier D5 (round 3, T-TABS-02): a tab not opened in this launch showed a
/// black card with only a cursor for minutes with the link up: its saved
/// frame from an earlier launch was a blank screen. Its card shows the Mac's
/// screen as text (`read-screen`) once fetched; a live page's own snapshot
/// still wins once the tab was opened.
@Suite struct TerminalCardContentTests {
    @Test func aNeverOpenedTabShowsTheMacsScreenOverASavedFrame() {
        #expect(TerminalCardContent.choose(sessionStarted: false, connecting: false, hasSnapshot: true,
                                           screenText: "$ ls\nREADME.md") == .screenText)
    }

    @Test func anOpenedTabShowsItsLiveSnapshot() {
        #expect(TerminalCardContent.choose(sessionStarted: true, connecting: false, hasSnapshot: true,
                                           screenText: "$ ls") == .snapshot)
        #expect(TerminalCardContent.choose(sessionStarted: true, connecting: true, hasSnapshot: true,
                                           screenText: nil) == .connecting)
    }

    @Test func blankScreenTextIsNotContent() {
        #expect(TerminalCardContent.choose(sessionStarted: false, connecting: false, hasSnapshot: true,
                                           screenText: "\n  \n") == .snapshot)
        #expect(TerminalCardContent.choose(sessionStarted: false, connecting: false, hasSnapshot: false,
                                           screenText: nil) == .placeholder)
    }
}
