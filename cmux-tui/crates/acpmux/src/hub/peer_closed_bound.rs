//! Part of `Hub`; see `hub/mod.rs`. How many of a peer's closed chats this daemon keeps: the
//! [`CLOSED_KEPT`] newest a peer lists (by `updatedAt`), every live one, and none older.
//!
//! A peer lists its whole history, closed chats included, and this daemon kept every row each
//! peer listed for as long as the peer did. On huge-blue (2026-11-19), linked to 25 peers, that
//! was 10,948 rows, 10,163 of them closed (8,477 untouched for over a week) and 10,923 of them
//! other machines': every list, each peer's relist and cache save, and each list page walked and
//! copied history that grows with every chat the fleet ever closed (the daemon held 11 to 15 GB
//! resident, and its paged list took 2.5 to 3 s). Leo: "Root-fix anything slow, stalling,
//! uncached or growing." Kept this way, a peer costs its live chats and [`CLOSED_KEPT`] more,
//! whatever its age.
//!
//! The bound is applied wherever a peer's rows come in: its whole list (`PeerNotice::Sessions`,
//! a follow's patch too), a row that closes (`PeerNotice::SessionChanged`), and the rows saved
//! from before a restart (`peer_cache.rs`). A row past it goes as a purge does (watchers hear it
//! went); the chat itself stays on its machine, which still lists it and answers for it there.

use super::*;
use std::collections::HashSet;

/// Closed chats kept for each peer, its newest; a live chat is always kept.
pub(crate) const CLOSED_KEPT: usize = if cfg!(test) { 4 } else { 64 };

/// What the bound reads of a row.
pub(super) struct Closed<K> {
    pub(super) key: K,
    pub(super) closed: bool,
    pub(super) updated: u64,
}

/// The keys of the closed rows past the [`CLOSED_KEPT`] newest (by `updatedAt`, then key, so a
/// tie is cut the same way each time).
pub(super) fn past_bound<K: Ord + Clone + std::hash::Hash>(
    rows: impl IntoIterator<Item = Closed<K>>,
) -> HashSet<K> {
    let mut closed: Vec<(u64, K)> =
        rows.into_iter().filter(|r| r.closed).map(|r| (r.updated, r.key)).collect();
    if closed.len() <= CLOSED_KEPT {
        return HashSet::new();
    }
    closed.sort_unstable_by(|a, b| b.cmp(a));
    closed.split_off(CLOSED_KEPT).into_iter().map(|(_, key)| key).collect()
}

/// A row's status and `updatedAt`, read from its text without building it.
#[derive(serde::Deserialize)]
struct Stamp {
    #[serde(default)]
    status: Option<String>,
    #[serde(rename = "updatedAt", default)]
    updated_at: Option<u64>,
}

/// The indexes of `list`'s rows (each a row's text, as a peer lists it) past the bound.
pub(super) fn listed_past_bound(list: &[Arc<str>]) -> HashSet<usize> {
    past_bound(list.iter().enumerate().map(|(key, text)| {
        let stamp = serde_json::from_str::<Stamp>(text).ok();
        let stamp = stamp.as_ref();
        Closed {
            key,
            closed: stamp.and_then(|s| s.status.as_deref()) == Some("closed"),
            updated: stamp.and_then(|s| s.updated_at).unwrap_or_default(),
        }
    }))
}

/// The summaries of `rows` (saved ones, `peer_cache.rs`) past the bound, by index.
pub(super) fn summaries_past_bound(rows: &[Value]) -> HashSet<usize> {
    past_bound(rows.iter().enumerate().map(|(key, row)| Closed {
        key,
        closed: row.get("status").and_then(Value::as_str) == Some("closed"),
        updated: row.get("updatedAt").and_then(Value::as_u64).unwrap_or_default(),
    }))
}

impl Hub {
    /// Applies a peer's notice (`peers.rs` `apply_peer_notice_rows`). When a follow's patch or a
    /// changed row takes one of the peer's closed rows out from under the bound (a purge, or a
    /// closed chat that runs again), a closed row this daemon left out may now be among the
    /// newest [`CLOSED_KEPT`]. A later follow rebuilds the list from the rows held here and
    /// cannot bring it back, so the peer's list position is dropped and its next link reads the
    /// whole list, which the bound picks from again.
    pub(super) fn apply_peer_notice(
        &self,
        peer: &str,
        generation: u64,
        notice: crate::peer::PeerNotice,
    ) {
        use crate::peer::PeerNotice;
        // A changed row can take a closed row away only when the row held for it is closed (it
        // is purged or runs again); a live or new one cannot, so the count, a walk over every
        // row of the peer, is skipped for those: nearly every change during a busy turn.
        let watched = match &notice {
            PeerNotice::SessionsPatch { .. } => true,
            PeerNotice::SessionChanged { session, .. } => {
                session.get("sessionId").and_then(Value::as_str).is_some_and(|mux| {
                    self.remote_sessions
                        .read()
                        .find_mux(peer, mux)
                        .is_some_and(|(_, row)| row.summary.closed())
                })
            }
            _ => false,
        };
        let before = watched.then(|| self.held_closed_peer_rows(peer));
        self.apply_peer_notice_rows(peer, generation, notice);
        let Some(before) = before else { return };
        if before >= CLOSED_KEPT
            && self.held_closed_peer_rows(peer) < CLOSED_KEPT
            && let Some(current) = self.peer(peer).filter(|p| p.generation == generation)
        {
            current.forget_list_cursor();
        }
    }

    /// How many of peer `peer`'s rows held here are closed.
    fn held_closed_peer_rows(&self, peer: &str) -> usize {
        self.remote_sessions.read().of_peer(peer).filter(|(_, row)| row.summary.closed()).count()
    }

    /// Drops peer `peer`'s closed rows past the bound, while `generation` is the instance
    /// registered under that name, and tells watchers they went. Called when one of its rows
    /// closes: that is the only change that can add a closed row, so the bound holds between
    /// whole lists too.
    pub(super) fn trim_closed_peer_rows(&self, peer: &str, generation: u64) {
        let gone = {
            // The rows writer lock, then the registry with no lock (`peer_table.rs`).
            let mut map = self.remote_sessions.write();
            let Some(current) = self.peers.get(peer).filter(|p| p.generation == generation) else {
                return;
            };
            let past = past_bound(map.of_peer(peer).map(|(key, row)| Closed {
                key: key.clone(),
                closed: row.summary.closed(),
                updated: row.summary.updated_ms(),
            }));
            if past.is_empty() {
                return;
            }
            let gone: Vec<Value> =
                past.iter().filter_map(|key| map.take(key)).map(|r| r.summary.value()).collect();
            current.remote_rows_epoch.fetch_add(1, std::sync::atomic::Ordering::Release);
            gone
        };
        self.save_peer_cache(peer, generation, false);
        for summary in gone {
            self.announce_remote(peer, summary, "purged");
        }
    }
}

#[cfg(test)]
mod tests {
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
        assert!(
            past_bound((0..CLOSED_KEPT as u64).map(|n| row(&n.to_string(), true, n))).is_empty()
        );
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
        let peer =
            crate::peer::Peer::new_with_lease("vm", "ws://127.0.0.1:9", None, None, tx, true);
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
        let mut ids: Vec<String> = hub
            .remote_sessions()
            .iter()
            .map(|r| r["sessionId"].as_str().unwrap().to_owned())
            .collect();
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
        let closed = |n: usize| json!({"sessionId": format!("c{n}"), "status": "closed", "updatedAt": 10 + n});
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
}
