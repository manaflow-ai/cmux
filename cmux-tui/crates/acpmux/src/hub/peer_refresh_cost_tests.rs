//! What a peer's refresh costs every other peer: the rows walked and built while the rows writer
//! lock is held (`remote_table::under_writer`), for a peer with 2,000 live chats, the count a
//! goal's attached chats reach.
//!
//! On cosmic-gray (2026-11-27) the daemon sat at 94% CPU with the writer lock held 53 to 181 ms
//! at a time by four writers: a row that closed walked every row of its peer to trim the closed
//! ones, an idle close or drop parsed and wrote again every row of the peer, and a restart built
//! every saved row of each peer, all under the lock every other peer's notices wait on. Each of
//! them now costs a constant under the lock, whatever the peer holds.
//!
//! Run with `cargo test -p acpmux --lib -- hub::peer_refresh_cost_tests --nocapture` for the
//! numbers.

use super::peer_closed_bound::CLOSED_KEPT;
use super::remote_table::under_writer;
use super::*;
use crate::peer::PeerNotice;

const LIVE: usize = 2_000;
const NAME: &str = "attached";

fn hub_at(dir: &Path) -> Arc<Hub> {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Local;
    let store = crate::store::open(&cfg.store, dir).unwrap();
    Hub::new(cfg, store)
}

fn add_peer(hub: &Hub) -> Arc<crate::peer::Peer> {
    let (tx, _rx) = tokio::sync::mpsc::channel(8);
    let peer = crate::peer::Peer::new(NAME, "ws://127.0.0.1:9", None, None, tx);
    hub.peers.lock().unwrap().insert(NAME.to_owned(), peer.clone());
    peer
}

/// `LIVE` live chats and `CLOSED_KEPT` closed ones, the bound full.
fn listed(hub: &Hub, peer: &crate::peer::Peer) {
    let mut rows: Vec<Value> = (0..LIVE)
        .map(|n| json!({"sessionId": format!("s{n}"), "status": "idle", "updatedAt": 100 + n}))
        .collect();
    rows.extend(
        (0..CLOSED_KEPT).map(
            |n| json!({"sessionId": format!("c{n}"), "status": "closed", "updatedAt": 10 + n}),
        ),
    );
    hub.apply_peer_notice(NAME, peer.generation, PeerNotice::sessions_from_values(rows));
    assert_eq!(hub.remote_sessions.read().of_peer(NAME).count(), LIVE + CLOSED_KEPT);
}

#[test]
fn a_peers_refresh_costs_the_rows_writer_lock_no_walk_of_its_rows() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-prc");
    let hub = hub_at(dir.path());
    let peer = add_peer(&hub);
    listed(&hub, &peer);

    // A chat that closes, one past the bound: the oldest closed row goes, read from the peer's
    // closed index. Before: every row of the peer walked under the lock (2,004).
    under_writer::take();
    hub.apply_peer_notice(
        NAME,
        peer.generation,
        PeerNotice::SessionChanged {
            session: json!({"sessionId": "s7", "status": "closed", "updatedAt": 50_000}),
            kind: "status".into(),
            seq: 1,
        },
    );
    let close = under_writer::take();
    assert_eq!(hub.remote_sessions.read().closed_of_peer(NAME), CLOSED_KEPT);
    assert!(hub.remote_sessions.read().find_mux(NAME, "c0").is_none(), "the oldest went");

    // The grace ends: every live row marked stale, built from a snapshot before the lock.
    peer.seed_last_seen(Some(now_ms() - 40_000));
    let unreachable = {
        hub.mark_peer_unreachable(NAME, peer.generation);
        under_writer::take()
    };
    let stale = hub.remote_sessions.read().of_peer(NAME).filter(|(_, r)| r.summary.stale()).count();
    assert_eq!(stale, LIVE - 1, "every live row is marked");
    // Again with nothing to mark: no lock at all.
    hub.mark_peer_unreachable(NAME, peer.generation);
    let again = under_writer::take();

    // The same marks built under the lock, as every idle close and drop did before.
    let before_unreachable = {
        let dir = cmux_unix_socket::short_test_dir("acpmux-prc-old");
        let old = hub_at(dir.path());
        let old_peer = add_peer(&old);
        listed(&old, &old_peer);
        under_writer::take();
        let changed = old.remote_sessions.write().mark_peer_stale(NAME, Some(now_ms() - 40_000));
        assert_eq!(changed.len(), LIVE);
        under_writer::take()
    };

    // A restart reads the saved rows back, built before the lock. Before: each built under it.
    hub.save_peer_cache(NAME, peer.generation, true);
    hub.seal();
    let restarted = hub_at(dir.path());
    let restored = add_peer(&restarted);
    under_writer::take();
    restarted.load_peer_cache(&restored);
    let load = under_writer::take();
    let held = restarted.remote_sessions.read().of_peer(NAME).count();
    assert_eq!(held, LIVE - 1 + CLOSED_KEPT, "every row saved is back");

    eprintln!(
        "cost-bench: {LIVE} live + {CLOSED_KEPT} closed rows; under the rows writer lock \
         (holds/walked/built): close past bound {close:?}; unreachable {unreachable:?} \
         (in-lock path {before_unreachable:?}); unreachable again {again:?}; cache load {load:?}"
    );
    let rows = (LIVE + CLOSED_KEPT) as u64;
    assert_eq!(before_unreachable.walked, rows, "the old path walks every row under the lock");
    assert_eq!(before_unreachable.built, LIVE as u64, "and builds every live one");
    assert_eq!((close.walked, close.built), (0, 0), "{close:?}");
    assert_eq!(unreachable, under_writer::Cost { holds: 1, walked: 0, built: 0 });
    assert_eq!(again.holds, 0, "nothing to mark takes no lock: {again:?}");
    assert_eq!(load, under_writer::Cost { holds: 1, walked: 0, built: 0 });
}
