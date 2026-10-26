//! `_acpmux/peer_snapshot`: a down peer's chat reads stale, with no
//! countdown, across a restart and after its rows are gone; a recreated
//! session reads nothing.

use super::*;
use crate::peer::PeerNotice;

/// Records a segment holds in tests (`disk::SEGMENT_EVENTS`).
const SEGMENT_EVENTS_FOR_TESTS: u64 = disk::SEGMENT_EVENTS as u64;

fn hub_at(dir: &Path) -> Arc<Hub> {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Local;
    let store = crate::store::open(&cfg.store, dir).unwrap();
    Hub::new(cfg, store)
}

fn add_idle_peer(hub: &Hub, name: &str) -> Arc<crate::peer::Peer> {
    let (tx, _rx) = tokio::sync::mpsc::channel(8);
    let peer = crate::peer::Peer::new(name, "ws://127.0.0.1:9", None, None, tx);
    hub.peers.lock().unwrap().insert(name.to_owned(), peer.clone());
    peer
}

fn row(created: u64) -> Value {
    json!({"sessionId": "m1", "name": "lane", "status": "running", "createdAt": created,
           "updatedAt": 5, "retry": {"attempt": 1, "of": 3, "nextAt": 99}})
}

fn page(range: std::ops::RangeInclusive<u64>) -> Value {
    let events: Vec<Value> = range
        .clone()
        .map(|s| json!({"sessionId": "m1", "seq": s, "kind": "k", "msg": {}}))
        .collect();
    json!({"session": {"createdAt": 42}, "events": events, "hasMore": false, "lastSeq": range.end()})
}

fn seqs(reply: &Value) -> Vec<u64> {
    reply["events"].as_array().unwrap().iter().map(|e| e["seq"].as_u64().unwrap()).collect()
}

#[test]
fn a_down_peers_chat_reads_stale_without_a_countdown_across_a_restart() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-psr");
    let hub = hub_at(dir.path());
    let peer = add_idle_peer(&hub, "huge-blue");
    hub.apply_peer_notice("huge-blue", peer.generation, PeerNotice::Sessions(vec![row(42)]));
    hub.capture_peer_page(
        ("huge-blue", peer.generation, peer.link_epoch()),
        "m1",
        &json!({}),
        &page(1..=6),
    );
    let down = PeerNotice::Disconnected("connect timed out".into());
    hub.apply_peer_notice("huge-blue", peer.generation, down);

    let got = hub.peer_snapshot(&json!({"sessionId": "huge-blue/lane"})).unwrap();
    assert_eq!(seqs(&got), (1..=6).collect::<Vec<_>>());
    assert_eq!((got["stale"].clone(), got["lastSeq"].clone()), (json!(true), json!(6)));
    assert_eq!((got["generation"].clone(), got["hasMore"].clone()), (json!(42), json!(false)));
    assert_eq!(got["qualifiedSessionId"], "huge-blue/m1");
    assert!(got["capturedAt"].is_u64());
    assert!(got["summary"].get("retry").is_none(), "no countdown from a peer that is down: {got}");
    assert_eq!(got["summary"]["stale"], true);
    // The newest within the limit, and more is older.
    let two = hub.peer_snapshot(&json!({"sessionId": "m1", "limit": 2})).unwrap();
    assert_eq!((seqs(&two), two["hasMore"].clone()), (vec![5, 6], json!(true)));

    // This daemon restarts while the peer is still down.
    let again = hub_at(dir.path());
    let peer = add_idle_peer(&again, "huge-blue");
    again.load_peer_cache(&peer);
    let got = again.peer_snapshot(&json!({"sessionId": "huge-blue/lane"})).unwrap();
    assert_eq!(seqs(&got), (1..=6).collect::<Vec<_>>());
    assert!(got["summary"].get("retry").is_none(), "{got}");

    // No row lists it any more (a lease that ended with its VM): host and id.
    again.remote_sessions.lock().unwrap().clear();
    let got = again.peer_snapshot(&json!({"host": "huge-blue", "sessionId": "m1"})).unwrap();
    assert_eq!(seqs(&got), (1..=6).collect::<Vec<_>>());
    assert_eq!(got["summary"]["name"], "huge-blue/lane", "the kept row");
    let none = again.peer_snapshot(&json!({"host": "huge-blue", "sessionId": "m9"})).unwrap();
    assert_eq!((seqs(&none), none["lastSeq"].clone()), (vec![], json!(0)));
    assert!(again.peer_snapshot(&json!({"sessionId": "nope"})).is_err());
    assert!(again.peer_snapshot(&json!({})).is_err());
}

#[test]
fn a_row_with_another_generation_reads_nothing_and_drops_the_copy() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-psr");
    let hub = hub_at(dir.path());
    let peer = add_idle_peer(&hub, "huge-blue");
    hub.apply_peer_notice("huge-blue", peer.generation, PeerNotice::Sessions(vec![row(42)]));
    hub.capture_peer_page(
        ("huge-blue", peer.generation, peer.link_epoch()),
        "m1",
        &json!({}),
        &page(1..=3),
    );
    // The peer recreated the session under the same id.
    hub.apply_peer_notice("huge-blue", peer.generation, PeerNotice::Sessions(vec![row(43)]));
    let got = hub.peer_snapshot(&json!({"sessionId": "huge-blue/lane"})).unwrap();
    assert_eq!((seqs(&got), got["lastSeq"].clone()), (vec![], json!(0)));
    assert!(!dir.path().join("peers/huge-blue/m1").exists());
}

#[cfg(unix)]
#[test]
fn a_segment_that_cannot_be_read_never_reads_as_the_whole_chat() {
    use std::os::unix::fs::PermissionsExt;
    let dir = cmux_unix_socket::short_test_dir("acpmux-psr");
    let hub = hub_at(dir.path());
    let peer = add_idle_peer(&hub, "huge-blue");
    hub.apply_peer_notice("huge-blue", peer.generation, PeerNotice::Sessions(vec![row(42)]));
    let on = ("huge-blue", peer.generation, peer.link_epoch());
    hub.capture_peer_page(on, "m1", &json!({}), &page(1..=SEGMENT_EVENTS_FOR_TESTS + 2));
    let whole = hub.peer_snapshot(&json!({"sessionId": "huge-blue/lane"})).unwrap();
    assert_eq!(whole["hasMore"], false, "read from the first record: {whole}");
    // The oldest segment can no longer be read (root reads anything, so it is replaced instead).
    let seg = dir.path().join("peers/huge-blue/m1/seg-0.ndjson");
    std::fs::remove_file(&seg).unwrap();
    std::fs::create_dir(&seg).unwrap();
    std::fs::set_permissions(&seg, std::fs::Permissions::from_mode(0o700)).unwrap();
    let got = hub.peer_snapshot(&json!({"sessionId": "huge-blue/lane"})).unwrap();
    assert_eq!(got["hasMore"], true, "{got}");
    assert!(!seqs(&got).is_empty() && !seqs(&got).contains(&1));
}
