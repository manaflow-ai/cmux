//! A delivery a peer took and may have lost with its disk (`Delivery::open_on_peer`) against the
//! outbox's retention (review of #37284 at af36583c, F2).

use super::outbox::*;
use serde_json::json;

const DAY_MS: u64 = 24 * 60 * 60 * 1000;

/// A delivery handed over `age_ms` ago, in `state`, open on its peer or not.
fn delivery(id: &str, age_ms: u64, state: &str, open: bool) -> Delivery {
    let at = crate::store::now_ms() - age_ms;
    serde_json::from_value(json!({
        "id": id,
        "target": "b/moved",
        "request": {"sessionId": "b/moved", "_meta": {"acpmux": {"promptId": format!("p-{id}")}}},
        "state": state,
        "openOnPeer": open,
        "createdAt": at,
        "updatedAt": at,
    }))
    .unwrap()
}

/// Its machine went away and stays offline past a day: the delivery the peer took is kept open
/// for its redelivery, while a settled one of the same age goes as before.
#[test]
fn an_open_delivery_outlives_a_day_with_its_peer_offline() {
    let outbox = Outbox::default();
    outbox.add(delivery("open", DAY_MS + 60 * 60 * 1000, "delivered", true)).unwrap();
    outbox.add(delivery("settled", DAY_MS + 60 * 60 * 1000, "delivered", false)).unwrap();
    // Any change runs the retention.
    outbox.add(delivery("new", 0, "queued", false)).unwrap();
    outbox.update("new", |d| d.attempts += 1);
    let open: Vec<String> = outbox.open_on_peers().into_iter().map(|d| d.id).collect();
    assert_eq!(open, ["open"], "the open delivery was pruned");
    assert!(outbox.get("settled").is_none(), "a settled delivery past its day stays");
}

/// cosmic-gray, 2026-11-22: 3,696 open deliveries had no proof and an answer `duplicate`, each
/// sent again on every link of its peer for up to 30 days (one 1,152 times in 215 h). A prompt
/// that went into an inbox digest or a steered turn has no record of its own prompt id there, so
/// no proof ever comes; its peer answers each resend with the same final outcome. That answer
/// closes it, delivered.
#[test]
fn a_duplicate_answered_with_its_final_outcome_closes_without_a_proof() {
    use super::open_delivery::{Again, after_again, done_on_peer, final_duplicate};
    // The shapes the outbox held, by their count there.
    let inbox = json!({"stopReason": "end_turn", "_meta": {"acpmux": {
        "duplicate": true, "inbox": true, "promptId": "p", "turnId": "t", "turnSeq": 3}}});
    let ledger = json!({"stopReason": "end_turn", "_meta": {"acpmux": {
        "duplicate": true, "promptId": "p", "turnId": "t", "status": "completed"}}});
    let steered = json!({"stopReason": "steered", "_meta": {"acpmux": {
        "duplicate": true, "inbox": true, "promptId": "p", "steer": true, "turnId": "t"}}});
    let withdrawn = json!({"stopReason": "cancelled", "_meta": {"acpmux": {
        "duplicate": true, "promptId": "p", "turnId": "t", "status": "withdrawn"}}});
    for answer in [&inbox, &ledger, &steered, &withdrawn] {
        assert!(final_duplicate(answer), "{answer}");
    }
    // Not final: still running in a turn it joined, cut by a crash, or a first acceptance.
    let joined = json!({"duplicate": true, "promptId": "p", "queued": false, "turnId": "t"});
    let cut = json!({"stopReason": null, "_meta": {"acpmux": {
        "duplicate": true, "promptId": "p", "turnId": "t", "status": "interrupted"}}});
    let fresh =
        json!({"stopReason": "end_turn", "_meta": {"acpmux": {"promptId": "p", "turnId": "t"}}});
    for answer in [&joined, &cut, &fresh] {
        assert!(!final_duplicate(answer), "{answer}");
    }

    let mut d = delivery("dup", 0, "delivered", true);
    d.accepted = Some(joined.clone());
    assert!(!done_on_peer(&d), "a joined turn still running stays open");
    assert!(!after_again(&mut d, Again::Taken(joined)), "answered the same: still open");
    assert!(d.open_on_peer);
    // The next link's resend finds the turn ended.
    assert!(after_again(&mut d, Again::Taken(inbox.clone())), "its final outcome settles it");
    assert!(!d.open_on_peer, "closed");
    assert_eq!(d.state, State::Delivered);

    // Read back from disk already answered so: closed by the next link without a resend.
    let outbox = Outbox::default();
    let mut kept = delivery("kept", 0, "delivered", true);
    kept.accepted = Some(inbox);
    assert!(done_on_peer(&kept));
    outbox.add(kept).unwrap();
    outbox.update("kept", super::open_delivery::release);
    assert!(outbox.open_on_peers().is_empty(), "nothing left open to send again");
}

/// A proven delivery keeps its proof's path: a final duplicate answer does not short it.
#[test]
fn a_proven_delivery_is_not_closed_by_a_duplicate_answer() {
    use super::open_delivery::done_on_peer;
    let mut d = delivery("proven", 0, "delivered", true);
    d.accepted = Some(json!({"stopReason": "end_turn", "_meta": {"acpmux": {
        "duplicate": true, "promptId": "p", "turnId": "t", "status": "completed"}}}));
    d.proof = Some(Proof {
        records: vec![json!({"seq": 1, "kind": "queued"})],
        link: (1, 0),
        incarnation: String::new(),
        since: 0,
    });
    assert!(!done_on_peer(&d));
}
