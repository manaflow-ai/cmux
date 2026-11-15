//! A peer's whole list that changes every row (a restarted peer: each row's receipt is new) is
//! announced row by row on the hub's event channel, which holds each event until every receiver
//! has read it: up to 8,192 events while one connection's fan-out lags. Each announcement held its
//! row parsed into a `serde_json::Value` tree, about ten times its text: the churn lab's dhat put
//! 115 MB at the notice task for one peer of 4,000 rows, and the channel held 3,880 events as the
//! daemon's RSS rose from 167 to 331 MB (`tests/god_daemon.rs`
//! `whole_lists_of_a_peer_that_cannot_follow_under_churn`, run 43753071867).

use super::*;
use crate::peer::{Peer, PeerNotice};

const ROWS: usize = 2_000;

fn list(generation: u64) -> PeerNotice {
    PeerNotice::sessions_from_values(
        (0..ROWS)
            .map(|i| {
                let mut row = crate::god_fixture::peer_row("peer00", i, 75);
                // A new run of the peer: every row reads as changed.
                row["updatedAt"] = json!(generation * 1_000_000 + i as u64);
                row
            })
            .collect(),
    )
}

#[test]
fn a_changed_whole_list_held_by_a_lagging_receiver_costs_about_its_text() {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let (tx, _rx) = tokio::sync::mpsc::channel(8);
    let peer = Peer::new("peer00", "ws://127.0.0.1:9", None, None, tx);
    hub.peers.lock().unwrap().insert("peer00".into(), peer.clone());
    hub.apply_peer_notice("peer00", peer.generation, list(1));

    // A connection that has not read yet: the channel keeps every event for it.
    let lagging = hub.subscribe();
    let second = list(2);
    let text: usize = match &second {
        PeerNotice::Sessions(rows) => rows.iter().map(|r| r.len()).sum(),
        _ => unreachable!(),
    };
    // The most the apply holds at once on this thread: the table's new rows and the announcements
    // the lagging receiver keeps.
    let ((), peak) = crate::hub::peer_snapshot::thread_peak_bytes(|| {
        hub.apply_peer_notice("peer00", peer.generation, second);
    });
    assert_eq!(lagging.len(), ROWS, "every changed row is announced");
    eprintln!("PERF changed list text={text} peak={peak}");
    // The new rows (packed text, as the table keeps them) plus their announcements: a few times
    // the list's text, not a parsed tree per row.
    assert!(
        peak <= 4 * text,
        "a changed list of {text} bytes of text peaked at {peak} bytes ({}x)",
        peak / text.max(1)
    );
}
