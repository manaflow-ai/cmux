import Testing
@testable import CnxTerminal

/// D5 / T-TABS-02: a tab never opened in this launch showed "Connecting to
/// <Mac>…" with a spinner in the grid forever (its session starts only when
/// its page is built). Its card is a static labeled placeholder instead.
@Suite struct TerminalTabCardTests {
    @Test func aNeverOpenedTabShowsNoSpinner() {
        #expect(!TerminalTabCard.showsConnecting(state: .connecting(mac: "Mac"), pageBuilt: false, hasSnapshot: false))
    }

    @Test func anOpenedTabStillShowsItsConnectionState() {
        #expect(TerminalTabCard.showsConnecting(state: .connecting(mac: "Mac"), pageBuilt: true, hasSnapshot: false))
        #expect(TerminalTabCard.showsConnecting(state: .reattaching(mac: nil), pageBuilt: false, hasSnapshot: true))
        #expect(!TerminalTabCard.showsConnecting(state: .attached, pageBuilt: true, hasSnapshot: true))
    }
}
