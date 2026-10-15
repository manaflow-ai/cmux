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

/// VERIFY-round5 V5-6 / T-TABS-01: a grid card shows the top of the page
/// (TabsKit lays a page-sized card out top-aligned in a 177 x 249.3 card),
/// so the newest rows and the agent's prompt were cut off. The snapshot is
/// placed so its bottom is the card's bottom edge.
@Suite struct TerminalCardCropTests {
    @Test func theCardShowsTheBottomOfThePage() {
        let crop = TerminalCardCrop(width: 402, imageHeight: 874)
        #expect(abs(crop.visibleHeight - 402 * 249.3 / 177) < 0.01)
        // The image moves up by what the card cannot show.
        #expect(abs(crop.imageTop - (crop.visibleHeight - 874)) < 0.01)
        // A short image is not moved.
        #expect(TerminalCardCrop(width: 402, imageHeight: 300).imageTop == 0)
    }

    /// V5-6 (round 7): the band under the composer is the page's toolbar
    /// inset, blank in a snapshot; the card ends at the composer instead.
    @Test func theCardEndsAtTheComposerNotTheToolbarBand() {
        let crop = TerminalCardCrop(width: 402, imageHeight: 874, bottomTrim: 82)
        #expect(abs(crop.imageTop - (crop.visibleHeight - (874 - 82))) < 0.01)
        // Never past the image's top.
        #expect(TerminalCardCrop(width: 402, imageHeight: 500, bottomTrim: 82).imageTop == 0)
    }
}

/// D11: a kill without backgrounding relaunched to no saved frame. The save
/// on output ran in the same turn as the first output batch, before Ghostty
/// presented it, so a tab whose replay was its only output saved the frame
/// from before the replay. Every save now waits for the frame (0.5 s) and
/// saves at most every 3 s.
@Suite struct TerminalFrameSaveScheduleTests {
    /// Round 8: a 370 ms render every 3 s while output streamed.
    @Test func noSaveWhileOutputStreamsUntilTheMaxWait() {
        #expect(TerminalFrameSaveSchedule.remainingWait(sinceLastOutput: 0.02, sinceRequested: 3) != nil)
        #expect(TerminalFrameSaveSchedule.remainingWait(sinceLastOutput: 0.6, sinceRequested: 3) == nil)
        #expect(TerminalFrameSaveSchedule.remainingWait(sinceLastOutput: 0.02, sinceRequested: 15) == nil)
    }

    @Test func theFirstSaveWaitsForTheFrameToBePresented() {
        #expect(TerminalFrameSaveSchedule.delay(sinceLastSave: .infinity) == 0.5)
        #expect(TerminalFrameSaveSchedule.delay(sinceLastSave: 10) == 0.5)
        #expect(TerminalFrameSaveSchedule.delay(sinceLastSave: 1) == 2)
    }
}
