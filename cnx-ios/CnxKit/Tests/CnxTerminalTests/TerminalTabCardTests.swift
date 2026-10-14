import Testing
@testable import CnxTerminal

/// D5 / T-TABS-02: a tab never opened in this launch showed "Connecting to
/// <Mac>…" with a spinner in the grid forever (its session starts only when
/// its page is built). Its card shows its saved frame or the static placeholder instead.
@Suite struct TerminalTabCardTests {
    @Test func aNeverOpenedTabShowsNoSpinner() {
        #expect(!TerminalTabCard.showsConnecting(state: .connecting(mac: "Mac"), sessionStarted: false))
    }

    @Test func anOpenedTabStillShowsItsConnectionState() {
        #expect(TerminalTabCard.showsConnecting(state: .connecting(mac: "Mac"), sessionStarted: true))
        #expect(TerminalTabCard.showsConnecting(state: .reattaching(mac: nil), sessionStarted: true))
        #expect(!TerminalTabCard.showsConnecting(state: .attached, sessionStarted: true))
    }
}
