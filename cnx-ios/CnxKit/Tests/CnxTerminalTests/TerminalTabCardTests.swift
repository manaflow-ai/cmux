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
