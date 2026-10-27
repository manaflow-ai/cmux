//! `_acpmux/peer_snapshot`: a down peer's chat reads stale, with no
//! countdown, across a restart and after its rows are gone; a recreated
//! session reads nothing, and a copy that does not read whole reads as none.

use super::*;
use crate::peer::PeerNotice;

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

/// Captures `page` of m1 as the hub's forward path does, and waits for it to be written.
fn capture(hub: &Hub, peer: &crate::peer::Peer, page: &Value) {
    let asked = hub.listed_generation("huge-blue", "m1");
    let on = ("huge-blue", peer.generation, peer.link_epoch(), asked);
    hub.capture_peer_page(on, ("m1", false), &json!({}), page);
    hub.peer_snapshots.flush_now();
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
    capture(&hub, &peer, &page(1..=6));
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
    // A limit of none, or one that is not a whole number of records, is not a read.
    for limit in [json!(0), json!(-1), json!(1.5), json!(true), json!("2")] {
        assert!(hub.peer_snapshot(&json!({"sessionId": "m1", "limit": limit})).is_err(), "{limit}");
    }
    // No limit (or null) is the default, and one past the bound is held to it.
    assert!(hub.peer_snapshot(&json!({"sessionId": "m1", "limit": null})).is_ok());
    let all = hub.peer_snapshot(&json!({"sessionId": "m1", "limit": 1_000_000})).unwrap();
    assert_eq!(seqs(&all), (1..=6).collect::<Vec<_>>());

    // This daemon restarts while the peer is still down.
    let again = hub_at(dir.path());
    let peer = add_idle_peer(&again, "huge-blue");
    again.load_peer_cache(&peer);
    let got = again.peer_snapshot(&json!({"sessionId": "huge-blue/lane"})).unwrap();
    assert_eq!(seqs(&got), (1..=6).collect::<Vec<_>>());
    assert!(got["summary"].get("retry").is_none(), "{got}");

    // No row lists it any more (a lease that ended with its VM): host and id.
    again.remote_sessions.lock().unwrap().retain(|_, _| false);
    let got = again.peer_snapshot(&json!({"host": "huge-blue", "sessionId": "m1"})).unwrap();
    assert_eq!(seqs(&got), (1..=6).collect::<Vec<_>>());
    assert_eq!(got["summary"]["name"], "huge-blue/lane", "the kept row");
    let none = again.peer_snapshot(&json!({"host": "huge-blue", "sessionId": "m9"})).unwrap();
    assert_eq!((seqs(&none), none["lastSeq"].clone()), (vec![], json!(0)));
    assert!(again.peer_snapshot(&json!({"sessionId": "nope"})).is_err());
    assert!(again.peer_snapshot(&json!({})).is_err());
}

#[test]
fn a_row_with_another_generation_reads_nothing_and_its_listing_drops_the_copy() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-psr");
    let hub = hub_at(dir.path());
    let peer = add_idle_peer(&hub, "huge-blue");
    hub.apply_peer_notice("huge-blue", peer.generation, PeerNotice::Sessions(vec![row(42)]));
    capture(&hub, &peer, &page(1..=3));
    // The peer recreated the session under the same id.
    hub.apply_peer_notice("huge-blue", peer.generation, PeerNotice::Sessions(vec![row(43)]));
    let got = hub.peer_snapshot(&json!({"sessionId": "huge-blue/lane"})).unwrap();
    assert_eq!((seqs(&got), got["lastSeq"].clone()), (vec![], json!(0)));
    hub.peer_snapshots.flush_now();
    let home = hub.store.peer_cache_dir().unwrap().parent().unwrap().to_owned();
    assert!(!disk::path(&disk::root(&home), &("huge-blue".into(), "m1".into())).unwrap().exists());
    // A read that looked up the row before it changed asks for 42: it reads nothing, and leaves
    // the copy of 43 that the listing made current.
    let mut fresh = page(1..=2);
    fresh["session"]["createdAt"] = json!(43);
    capture(&hub, &peer, &fresh);
    let snaps = &hub.peer_snapshots;
    let old = snaps.read(("huge-blue", "m1"), (100, usize::MAX), Some(42), None);
    assert_eq!(seqs(&old), Vec::<u64>::new());
    let now = snaps.read(("huge-blue", "m1"), (100, usize::MAX), Some(43), None);
    assert_eq!(seqs(&now), vec![1, 2]);
}

#[test]
fn a_copy_that_does_not_read_whole_reads_as_none() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-psr");
    let hub = hub_at(dir.path());
    let peer = add_idle_peer(&hub, "huge-blue");
    hub.apply_peer_notice("huge-blue", peer.generation, PeerNotice::Sessions(vec![row(42)]));
    capture(&hub, &peer, &page(1..=6));
    let home = hub.store.peer_cache_dir().unwrap().parent().unwrap().to_owned();
    let file = disk::path(&disk::root(&home), &("huge-blue".into(), "m1".into())).unwrap();
    let text = std::fs::read_to_string(&file).unwrap();
    // A restart finds the copy cut (a disk that lost its tail): it is not half a chat.
    std::fs::write(&file, &text[..text.len() - 5]).unwrap();
    let again = hub_at(dir.path());
    let peer = add_idle_peer(&again, "huge-blue");
    again.load_peer_cache(&peer);
    let got = again.peer_snapshot(&json!({"sessionId": "huge-blue/lane"})).unwrap();
    assert_eq!((seqs(&got), got["hasMore"].clone()), (vec![], json!(false)), "{got}");
    again.peer_snapshots.flush_now();
    assert!(!file.exists(), "it goes");
}

#[test]
fn a_loss_not_sent_yet_goes_before_a_read_of_its_peer() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-psr");
    let hub = hub_at(dir.path());
    let peer = add_idle_peer(&hub, "huge-blue");
    hub.apply_peer_notice("huge-blue", peer.generation, PeerNotice::Sessions(vec![row(42)]));
    capture(&hub, &peer, &page(1..=6));
    {
        // A purge of the peer's that could not be sent (no thread then): its loss waits.
        let mut dropped = hub.peer_snapshots.dropped();
        dropped.peers.insert("huge-blue".into(), false);
        dropped.unsent.insert("huge-blue".into());
    }
    let got = hub.peer_snapshot(&json!({"sessionId": "huge-blue/lane"})).unwrap();
    assert!(seqs(&got).is_empty(), "the loss went first: {got}");
    assert!(hub.peer_snapshots.dropped().unsent.is_empty());
}
