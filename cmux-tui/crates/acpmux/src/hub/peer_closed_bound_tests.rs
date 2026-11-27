use super::*;

fn row(key: &str, closed: bool, updated: u64) -> Closed<String> {
    Closed { key: key.to_owned(), closed, updated }
}

#[test]
fn only_the_newest_closed_rows_are_kept_and_every_live_one() {
    let mut rows: Vec<_> = (0..10).map(|n| row(&format!("c{n}"), true, n)).collect();
    rows.extend((0..10).map(|n| row(&format!("l{n}"), false, n)));
    let past = past_bound(rows);
    assert_eq!(past.len(), 10 - CLOSED_KEPT);
    for n in 0..10 - CLOSED_KEPT as u64 {
        assert!(past.contains(&format!("c{n}")), "{past:?}");
    }
    assert!(past.iter().all(|k| k.starts_with('c')), "a live row is never dropped: {past:?}");
    assert!(past_bound((0..CLOSED_KEPT as u64).map(|n| row(&n.to_string(), true, n))).is_empty());
}

#[test]
fn a_listed_rows_status_and_time_are_read_from_its_text() {
    let list: Vec<Arc<str>> = (0..CLOSED_KEPT + 2)
        .map(|n| json!({"sessionId": n.to_string(), "status": "closed", "updatedAt": n}))
        .chain([json!({"sessionId": "live", "status": "idle", "updatedAt": 0})])
        .chain([json!({"sessionId": "old", "status": "closed"})])
        .map(|v| Arc::from(v.to_string()))
        .collect();
    let past = listed_past_bound(&list);
    // The oldest two closed rows, and the one with no time (the oldest of all).
    assert_eq!(past, HashSet::from([0, 1, CLOSED_KEPT + 3]));
}

fn hub_with_peer(name: &str) -> (Arc<Hub>, Arc<crate::peer::Peer>) {
    let store = Box::new(crate::store::MemoryStore::default());
    let hub = Hub::new(crate::config::Config::default(), store);
    let (tx, _rx) = tokio::sync::mpsc::channel(8);
    let peer = crate::peer::Peer::new(name, "ws://127.0.0.1:9", None, None, tx);
    hub.peers.lock().unwrap().insert(name.to_owned(), peer.clone());
    (hub, peer)
}

#[test]
fn wedge_fuzzy_host_resolution_does_not_wait_for_the_registry_writer() {
    let (hub, _peer) = hub_with_peer("wedge-routing-peer");
    let writer = hub.peers.lock().unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    let reader = {
        let hub = hub.clone();
        std::thread::spawn(move || {
            tx.send(hub.host_route("WEDGE-ROUTING-PEER")).unwrap();
        })
    };
    let result = rx.recv_timeout(std::time::Duration::from_secs(2));
    drop(writer);
    reader.join().unwrap();
    assert_eq!(
        result.expect("fuzzy host resolution waited on the registry writer").unwrap(),
        Some("wedge-routing-peer".to_owned())
    );
}

#[test]
fn wedge_connected_peers_and_remote_listing_do_not_wait_for_the_registry_writer() {
    let (hub, peer) = hub_with_peer("vm");
    peer.connected.store(true, std::sync::atomic::Ordering::SeqCst);
    hub.apply_peer_notice(
        "vm",
        peer.generation,
        crate::peer::PeerNotice::sessions_from_values(vec![
            json!({"sessionId": "s1", "status": "idle", "updatedAt": 1}),
        ]),
    );
    let writer = hub.peers.lock().unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    let reader = {
        let hub = hub.clone();
        std::thread::spawn(move || {
            let peers: Vec<_> = hub.connected_peers().iter().map(|p| p.name.clone()).collect();
            tx.send((peers, listed_ids(&hub))).unwrap();
        })
    };
    let result = rx.recv_timeout(std::time::Duration::from_secs(2));
    drop(writer);
    reader.join().unwrap();
    let (peers, rows) =
        result.expect("peer or remote-session listing waited on the registry writer");
    assert_eq!(peers, ["vm"]);
    assert_eq!(rows, ["s1"]);
}

#[test]
fn wedge_peer_listing_does_not_wait_for_a_lease_waiting_on_the_registry_writer() {
    let (hub, _) = hub_with_peer("vm");
    let (tx, _rx) = tokio::sync::mpsc::channel(8);
    let peer = crate::peer::Peer::new_with_lease("vm", "ws://127.0.0.1:9", None, None, tx, true);
    hub.peers.lock().unwrap().insert("vm".into(), peer.clone());
    hub.peer_leases.lock().unwrap().insert("vm".into(), peer.generation);
    let writer = hub.peers.lock().unwrap();
    let (held_tx, held_rx) = std::sync::mpsc::channel();
    let mutation = {
        let hub = hub.clone();
        std::thread::spawn(move || {
            // Lease changes hold this fence while awaiting the registry, as lease_peer
            // and end_peer_lease do. Publish only after acquiring both in that order.
            let mut leases = hub.peer_leases.lock().unwrap();
            held_tx.send(()).unwrap();
            let _registry = hub.peers.lock().unwrap();
            leases.insert("vm".into(), peer.generation);
        })
    };
    held_rx.recv_timeout(std::time::Duration::from_secs(2)).unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    let reader = {
        let hub = hub.clone();
        std::thread::spawn(move || tx.send(hub.peers()).unwrap())
    };
    let result = rx.recv_timeout(std::time::Duration::from_secs(2));
    drop(writer);
    mutation.join().unwrap();
    reader.join().unwrap();
    let rows = result.expect("peer listing waited on the lease-to-registry lock chain");
    let row = rows.iter().find(|row| row["name"] == "vm").expect("the registered peer");
    assert_eq!(row["leased"], true, "the published lease annotation remains visible");
}

/// Leo's daemon, 2026-11-25: every tokio worker parked on the peer registry's mutex, because
/// a peer's list notice took it and, still holding it, waited on the rows writer lock. A
/// lookup of any peer by name (an outbox attempt, a key route) then waited for every row
/// write. Now a lookup answers while a notice waits on the rows writer, and the notice still
/// lands once the writer lets go.
#[test]
fn wedge_a_peer_lookup_never_waits_behind_a_notice_waiting_on_the_rows_writer() {
    use crate::peer::PeerNotice;
    let (hub, peer) = hub_with_peer("vm");
    let rows_of = |ids: &[&str]| {
        PeerNotice::sessions_from_values(
            ids.iter()
                .map(|id| json!({"sessionId": id, "status": "idle", "updatedAt": 1}))
                .collect(),
        )
    };
    hub.apply_peer_notice("vm", peer.generation, rows_of(&["s1", "s2"]));
    let rows = hub.remote_sessions.write();
    let notice = {
        let hub = hub.clone();
        let generation = peer.generation;
        std::thread::spawn(move || {
            // A purge: before, it took the registry, then waited on the rows writer.
            let purge = PeerNotice::SessionChanged {
                session: json!({"sessionId": "s2"}),
                kind: "purged".into(),
                seq: 1,
            };
            hub.apply_peer_notice("vm", generation, purge);
        })
    };
    // The notice is under way and waits on the rows writer this test holds.
    std::thread::sleep(std::time::Duration::from_millis(100));
    let (tx, rx) = std::sync::mpsc::channel();
    {
        let hub = hub.clone();
        std::thread::spawn(move || {
            let started = std::time::Instant::now();
            let found = hub.peer("vm").is_some();
            tx.send((found, started.elapsed())).unwrap();
        });
    }
    let answered = rx.recv_timeout(std::time::Duration::from_secs(2));
    drop(rows);
    notice.join().unwrap();
    eprintln!("wedge-bench: peer lookup during a notice's rows-writer wait: {answered:?}");
    let (found, took) = answered.expect("a peer lookup waited behind a peer notice");
    assert!(found);
    assert!(took < std::time::Duration::from_millis(500), "lookup took {took:?}");
    assert_eq!(listed_ids(&hub), ["s1"]);
}

fn listed_ids(hub: &Hub) -> Vec<String> {
    let mut ids: Vec<String> =
        hub.remote_sessions().iter().map(|r| r["sessionId"].as_str().unwrap().to_owned()).collect();
    ids.sort();
    ids
}

/// A peer that lists its whole history costs this daemon its live chats and its newest
/// closed ones, however many it closed: the rows kept stay the same as its history grows,
/// and a closed row that falls past the bound goes from a list held before.
#[test]
fn a_peers_history_is_kept_to_its_live_chats_and_newest_closed_ones() {
    use crate::peer::PeerNotice;
    let (hub, peer) = hub_with_peer("vm");
    let list = |closed: usize| {
        let mut rows: Vec<Value> = (0..closed)
            .map(|n| {
                json!({"sessionId": format!("c{n:04}"), "status": "closed",
                            "updatedAt": 1_000 + n})
            })
            .collect();
        rows.push(json!({"sessionId": "live", "status": "idle", "updatedAt": 1}));
        PeerNotice::sessions_from_values(rows)
    };
    for closed in [CLOSED_KEPT, 10 * CLOSED_KEPT, 100 * CLOSED_KEPT] {
        hub.apply_peer_notice("vm", peer.generation, list(closed));
        let ids = listed_ids(&hub);
        assert_eq!(ids.len(), CLOSED_KEPT + 1, "{closed} closed: {ids:?}");
        assert!(ids.contains(&"live".to_owned()), "{ids:?}");
        // Its newest closed ones.
        let newest = format!("c{:04}", closed - 1);
        let oldest_kept = format!("c{:04}", closed - CLOSED_KEPT);
        assert!(ids.contains(&newest) && ids.contains(&oldest_kept), "{ids:?}");
    }
}

/// A chat that closes between whole lists keeps the bound too: the oldest closed row goes,
/// and watchers hear it went.
#[tokio::test]
async fn a_chat_that_closes_drops_the_oldest_closed_row_past_the_bound() {
    use crate::peer::PeerNotice;
    let (hub, peer) = hub_with_peer("vm");
    let mut rows: Vec<Value> = (0..CLOSED_KEPT)
        .map(|n| json!({"sessionId": format!("c{n}"), "status": "closed", "updatedAt": 10 + n}))
        .collect();
    rows.push(json!({"sessionId": "live", "status": "running", "updatedAt": 5}));
    hub.apply_peer_notice("vm", peer.generation, PeerNotice::sessions_from_values(rows));
    assert_eq!(listed_ids(&hub).len(), CLOSED_KEPT + 1);
    let mut events = hub.events.subscribe();
    hub.apply_peer_notice(
        "vm",
        peer.generation,
        PeerNotice::SessionChanged {
            session: json!({"sessionId": "live", "status": "closed", "updatedAt": 1_000}),
            kind: "status".into(),
            seq: 1,
        },
    );
    let ids = listed_ids(&hub);
    assert_eq!(ids.len(), CLOSED_KEPT, "{ids:?}");
    assert!(ids.contains(&"live".to_owned()), "the chat that closed is the newest: {ids:?}");
    assert!(!ids.contains(&"c0".to_owned()), "the oldest went: {ids:?}");
    let mut purged = Vec::new();
    while let Ok(ev) = events.try_recv() {
        if ev.record.kind == "purged" {
            purged.push(ev.session_id.clone());
        }
    }
    assert_eq!(purged, ["c0"], "watchers hear the row went");
}

/// A purge or a reopen that takes a kept closed row out leaves a closed row this daemon left
/// out among the peer's newest. A follow rebuilds from the rows held here and cannot bring it
/// back, so the peer's list position goes and its next link reads the whole list. Under the
/// bound nothing was left out, and the position stays.
#[test]
fn a_kept_closed_row_that_leaves_makes_the_next_link_read_the_whole_list() {
    use crate::peer::PeerNotice;
    let cursor = Some(("epoch".to_owned(), 7));
    let closed =
        |n: usize| json!({"sessionId": format!("c{n}"), "status": "closed", "updatedAt": 10 + n});
    let changed = |session: Value, kind: &str| PeerNotice::SessionChanged {
        session,
        kind: kind.to_owned(),
        seq: 2,
    };
    // One closed row more than the bound: `c0` is left out.
    let (hub, peer) = hub_with_peer("vm");
    let rows: Vec<Value> = (0..=CLOSED_KEPT).map(closed).collect();
    hub.apply_peer_notice("vm", peer.generation, PeerNotice::sessions_from_values(rows));
    assert!(!listed_ids(&hub).contains(&"c0".to_owned()));
    peer.set_list_cursor_for_test(cursor.clone());
    // A row that changes and stays closed keeps the position.
    hub.apply_peer_notice("vm", peer.generation, changed(closed(CLOSED_KEPT), "status"));
    assert_eq!(peer.list_cursor_for_test(), cursor);
    // A kept closed row is purged: `c0` is among the newest again.
    hub.apply_peer_notice("vm", peer.generation, changed(json!({"sessionId": "c1"}), "purged"));
    assert_eq!(listed_ids(&hub).len(), CLOSED_KEPT - 1);
    assert_eq!(peer.list_cursor_for_test(), None, "the next link reads the whole list");

    // The same with a kept closed row that runs again.
    let (hub, peer) = hub_with_peer("vm");
    let rows: Vec<Value> = (0..=CLOSED_KEPT).map(closed).collect();
    hub.apply_peer_notice("vm", peer.generation, PeerNotice::sessions_from_values(rows));
    peer.set_list_cursor_for_test(cursor.clone());
    let reopened = json!({"sessionId": "c2", "status": "running", "updatedAt": 5_000});
    hub.apply_peer_notice("vm", peer.generation, changed(reopened, "status"));
    assert_eq!(peer.list_cursor_for_test(), None);

    // Under the bound, nothing was left out: a purge keeps the position.
    let (hub, peer) = hub_with_peer("vm");
    let rows: Vec<Value> = (0..CLOSED_KEPT - 1).map(closed).collect();
    hub.apply_peer_notice("vm", peer.generation, PeerNotice::sessions_from_values(rows));
    peer.set_list_cursor_for_test(cursor.clone());
    hub.apply_peer_notice("vm", peer.generation, changed(json!({"sessionId": "c0"}), "purged"));
    assert_eq!(peer.list_cursor_for_test(), cursor);

    // A whole list that comes after, with the left-out row, keeps the newest again.
    let (hub, peer) = hub_with_peer("vm");
    let rows: Vec<Value> = (0..=CLOSED_KEPT).map(closed).collect();
    hub.apply_peer_notice("vm", peer.generation, PeerNotice::sessions_from_values(rows));
    hub.apply_peer_notice("vm", peer.generation, changed(json!({"sessionId": "c1"}), "purged"));
    let rows: Vec<Value> = (0..=CLOSED_KEPT).filter(|n| *n != 1).map(closed).collect();
    hub.apply_peer_notice("vm", peer.generation, PeerNotice::sessions_from_values(rows));
    let ids = listed_ids(&hub);
    assert_eq!(ids.len(), CLOSED_KEPT);
    assert!(ids.contains(&"c0".to_owned()), "{ids:?}");
}
