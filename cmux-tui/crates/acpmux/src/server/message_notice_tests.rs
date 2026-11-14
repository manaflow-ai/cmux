use super::{MESSAGE_NOTICES_KEPT, MessageNoticeBook, MessageNotices};

/// A long-lived connection keeps a bounded count of one chat's messages: past the bound the
/// oldest go under the low-water mark, still heard, and newer ones are still told apart.
#[test]
fn a_long_lived_chat_keeps_a_bounded_count() {
    let mut n = MessageNotices::default();
    let total = (MESSAGE_NOTICES_KEPT * 3) as u64;
    // Message records are sparse among a chat's records: every third seq.
    for i in 1..=total {
        assert!(n.live(i * 3), "seq {} goes once", i * 3);
        assert!(n.kept() <= MESSAGE_NOTICES_KEPT);
    }
    assert_eq!(n.kept(), MESSAGE_NOTICES_KEPT);
    // Heard ones, under the mark or above it, are not sent again.
    assert!(!n.live(3));
    assert!(!n.live(total * 3));
    // A newer record still goes, and a gap above the mark is still told apart.
    assert!(n.live(total * 3 + 1));
    assert!(n.live(total * 3 - 1));
    assert!(!n.live(total * 3 - 1));
    assert!(n.kept() <= MESSAGE_NOTICES_KEPT);
}

/// A replay's older record still goes once more live records than the bound have raised the
/// low-water mark past it: the replay never sent it, and a repeat beats a loss.
#[test]
fn a_replay_record_below_a_risen_floor_still_goes() {
    let mut n = MessageNotices::default();
    // The reopen's replay is at seq 10 when the live stream sends more than the bound.
    let live_from = 1_000u64;
    for seq in live_from..live_from + MESSAGE_NOTICES_KEPT as u64 + 10 {
        assert!(n.live(seq));
    }
    assert!(n.kept() <= MESSAGE_NOTICES_KEPT);
    // The replay reaches records the live stream never sent, below the risen mark.
    assert!(n.replay(10));
    assert!(n.replay(live_from + 5), "the replay sends what the bound forgot again");
    // Ones the live stream sent and still keeps are not sent again.
    assert!(!n.replay(live_from + MESSAGE_NOTICES_KEPT as u64));
    assert!(n.kept() <= MESSAGE_NOTICES_KEPT);
}

/// A peer's chat that keeps the raw id of one here (an export and import keeps ids) counts its
/// own seqs: neither chat's record silences the other's of the same seq.
#[test]
fn a_peer_chat_with_a_local_raw_id_hears_its_own_messages() {
    let mut book = MessageNoticeBook::default();
    assert!(book.live(None, "c", 3));
    assert!(book.live(Some("p"), "c", 3));
    assert!(!book.live(None, "c", 3));
    assert!(!book.live(Some("p"), "c", 3));
    assert!(book.live(Some("q"), "c", 3));
    // A reopen of the peer's chat replays it afresh and ends the local chat's count.
    book.reopen(Some("p"), "c");
    assert!(book.replay(Some("p"), "c", 3));
    assert!(book.live(None, "c", 3));
    // Detaching the local chat leaves the peer's count.
    book.forget(None, "c");
    assert!(!book.live(Some("p"), "c", 3));
    // Switching to the local chat drops every peer's count of that raw id.
    book.forget_others(None, "c");
    assert!(book.live(Some("p"), "c", 3));
    // A chat with no count from a reopen sends its replay.
    assert!(book.replay(None, "d", 1));
}

/// A replay racing the live stream sends each message notice once, whichever sends first.
#[test]
fn a_message_notice_goes_once_across_replay_and_live() {
    // A record heard once is not heard again live (another viewer's reopen of a peer's chat
    // replays it over the shared link); a record of no known seq always goes.
    let mut n = MessageNotices::default();
    assert!(n.live(2));
    assert!(!n.live(2));
    assert!(n.live(0));
    assert!(n.live(0));
    // The live stream sent seq 5 while the replay was at 3: the replay skips only 5.
    let mut n = MessageNotices::default();
    assert!(n.live(5));
    assert!(n.replay(3));
    assert!(!n.replay(5));
    assert!(n.replay(6));
    assert!(!n.live(6));
    // A peer's replay reaches a viewer as live records: an older one after a newer one
    // still goes.
    let mut n = MessageNotices::default();
    assert!(n.live(9));
    assert!(n.live(4));
    assert!(!n.live(4));
    // The replay sent 3 and 4 before the live stream reached them.
    let mut n = MessageNotices::default();
    assert!(n.replay(3));
    assert!(n.replay(4));
    assert!(!n.live(4));
    assert!(n.live(5));
}
