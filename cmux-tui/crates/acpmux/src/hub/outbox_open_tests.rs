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
    outbox.add(delivery("open", DAY_MS + 60 * 60 * 1000, "delivered", true));
    outbox.add(delivery("settled", DAY_MS + 60 * 60 * 1000, "delivered", false));
    // Any change runs the retention.
    outbox.add(delivery("new", 0, "queued", false));
    outbox.update("new", |d| d.attempts += 1);
    let open: Vec<String> = outbox.open_on_peers().into_iter().map(|d| d.id).collect();
    assert_eq!(open, ["open"], "the open delivery was pruned");
    assert!(outbox.get("settled").is_none(), "a settled delivery past its day stays");
}
