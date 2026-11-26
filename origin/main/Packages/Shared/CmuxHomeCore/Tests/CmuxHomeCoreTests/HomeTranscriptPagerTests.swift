import Testing
@testable import CmuxHomeCore

/// The transcript pager on its own: opens and closes pair up, only the last
/// close reports the conversation as gone, a reopen after it starts a new
/// epoch, and one older-page read runs per conversation.
@MainActor
@Suite struct HomeTranscriptPagerTests {
    let id = ConversationID("conv_aziz")

    @Test func opensAndClosesPairAndTheLastCloseEndsTheTranscript() {
        var pager = HomeTranscriptPager()
        let r1 = pager.close(id)
        #expect(!r1, "a close with no open does nothing")
        pager.open(id)
        pager.open(id)
        #expect(pager.viewers[id] == 2)
        let r2 = pager.close(id)
        #expect(!r2)
        #expect(pager.isShown(id))
        let r3 = pager.close(id)
        #expect(r3)
        #expect(!pager.isShown(id))
    }

    @Test func onlyAFirstOpenStartsANewEpoch() {
        var pager = HomeTranscriptPager()
        pager.open(id)
        let first = pager.epoch(id)
        pager.open(id)
        #expect(pager.epoch(id) == first)
        _ = pager.close(id)
        _ = pager.close(id)
        pager.open(id)
        #expect(pager.epoch(id) != first)
    }

    @Test func oneOlderPageReadRunsAtATime() {
        var pager = HomeTranscriptPager()
        let r4 = pager.beginOlder(id)
        #expect(r4)
        let r5 = pager.beginOlder(id)
        #expect(!r5)
        pager.endOlder(id)
        let r6 = pager.beginOlder(id)
        #expect(r6)
    }
}
