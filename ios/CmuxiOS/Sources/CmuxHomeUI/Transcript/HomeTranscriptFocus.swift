import CmuxHomeCore

/// The message a conversation opens at (a search hit): its idempotency key
/// and, when the message is committed, its seq. The seq lets the screen
/// find the row even when the transcript item's key differs from the hit's,
/// and tells it whether older pages can still contain the message.
struct HomeTranscriptFocus: Hashable, Sendable {
    var key: IdempotencyKey
    var seq: Seq?

    init(key: IdempotencyKey, seq: Seq? = nil) {
        self.key = key
        self.seq = seq
    }

    init(_ hit: HomeSearchHit) {
        self.init(key: hit.message.clientMessageID, seq: hit.message.seq)
    }
}
