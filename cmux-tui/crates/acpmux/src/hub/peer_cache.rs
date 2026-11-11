//! Part of `Hub`; see `hub/mod.rs`. Each peer's last-known sessions, kept
//! while the peer is down and saved to `peers/<name>.json`, so a daemon that
//! restarts while a peer is unreachable still lists them, marked stale, and
//! a request for one is refused as `peer_unreachable`, not `no_session`.

use super::*;

/// While a peer's sessions change, at most one save this often; a fresh
/// list and the first drop are saved at once.
pub(super) const SAVE_EVERY_MS: u64 = 30_000;

#[cfg(test)]
use super::peer_cache_disk::Saved;
use super::peer_cache_disk::{self as disk, Link, OnDisk};

/// Mark a peer's session as last-known: `status` `unreachable` (what older
/// clients read), `stale`, and when the peer was last seen. Returns whether
/// the row changed.
pub(super) fn mark_stale(summary: &mut Value, last_seen: Option<u64>) -> bool {
    // A completed chat stays completed even when its machine goes away.
    if summary["status"] == "closed" {
        return false;
    }
    let before = summary.clone();
    summary["status"] = Value::String("unreachable".into());
    if summary.get("state").is_some() {
        summary["state"] = Value::String("unreachable".into());
    }
    // Unreachable is not stuck: last-known stuck details would contradict `state`.
    for key in ["stuckReason", "stuckSince", "stuckError"] {
        if summary.get(key).is_some() {
            summary[key] = Value::Null;
        }
    }
    summary["stale"] = Value::Bool(true);
    summary["lastSeen"] = json!(last_seen);
    super::views::decide(summary);
    *summary != before
}

impl Hub {
    /// Serializes cache snapshots for one hub and peer without serializing different peers.
    /// The lock is deliberately separate from `peer_leases` and `remote_sessions`: it is held
    /// through serialization and the atomic rename, while both global locks are held only for
    /// their short snapshots.
    /// It also holds what this writer last left on disk (`peer_cache_disk.rs`).
    pub(super) fn peer_cache_writer(&self, peer: &str) -> Arc<StdMutex<OnDisk>> {
        let mut writers = self.peer_cache_writers.lock().unwrap_or_else(|e| e.into_inner());
        writers.entry(peer.to_owned()).or_default().clone()
    }

    /// Save `peer`'s rows, while `generation` is the instance registered
    /// under that name; unless `now`, at most once per `SAVE_EVERY_MS`.
    pub(super) fn save_peer_cache(&self, peer: &str, generation: u64, now: bool) {
        if !now {
            let Some(p) = self.peer(peer).filter(|p| p.generation == generation) else { return };
            if self.peer_leases.lock().unwrap_or_else(|e| e.into_inner()).contains_key(peer) {
                return;
            }
            // Publish the notice sequence before deciding whether this notice is throttled. The
            // stop flush can therefore see a notice even when the worker has not started yet.
            p.cache_dirty_seq.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            let at = now_ms();
            let last = p.cache_saved_at.load(std::sync::atomic::Ordering::SeqCst);
            if at.saturating_sub(last) < SAVE_EVERY_MS
                || p.cache_write_pending.swap(true, std::sync::atomic::Ordering::AcqRel)
            {
                return;
            }
            let Some(hub) = self.hub_ref.get().and_then(std::sync::Weak::upgrade) else {
                p.cache_write_pending.store(false, std::sync::atomic::Ordering::Release);
                // Unit fixtures can construct a hub outside a Tokio runtime, where the
                // self-weak is intentionally not installed. Keep their cache semantics without
                // spawning a worker that cannot own the hub.
                self.save_peer_cache_now(peer, generation, false);
                return;
            };
            let peer = peer.to_owned();
            let gate = hub.cache_write_gate.clone();
            let pending_peer = p.clone();
            let spawned =
                std::thread::Builder::new().name("acpmux-peer-cache".into()).spawn(move || {
                    let _gate = gate.lock().unwrap_or_else(|e| e.into_inner());
                    hub.save_peer_cache_now(&peer, generation, false);
                    pending_peer
                        .cache_write_pending
                        .store(false, std::sync::atomic::Ordering::Release);
                    // A leased peer leaves the registry on disconnect. Once its last queued
                    // writer is done, drop the per-peer gate unless a replacement already owns
                    // the name; the replacement may be using this same gate for ordering.
                    let mut writers =
                        hub.peer_cache_writers.lock().unwrap_or_else(|e| e.into_inner());
                    let peers = hub.peers.lock().unwrap_or_else(|e| e.into_inner());
                    if !peers.contains_key(&peer) {
                        writers.remove(&peer);
                    }
                });
            if spawned.is_err() {
                p.cache_write_pending.store(false, std::sync::atomic::Ordering::Release);
            }
            return;
        }
        self.save_peer_cache_now(peer, generation, now);
    }

    /// Performs one ordered snapshot and write. Non-final saves run off the notice loop; the
    /// per-peer writer makes queued snapshots land in order, and a final `now` save waits behind
    /// them before taking its own current snapshot.
    pub(super) fn save_peer_cache_now(&self, peer: &str, generation: u64, now: bool) {
        let writer = self.peer_cache_writer(peer);
        let mut on_disk = writer.lock().unwrap_or_else(|e| e.into_inner());
        // A leased peer leaves nothing on disk (`peer_lease.rs`). This check is intentionally
        // short: the lease mutex must never be held through cloning or the disk write.
        if self.peer_leases.lock().unwrap_or_else(|e| e.into_inner()).contains_key(peer) {
            return;
        }
        let p = self.peer(peer).filter(|p| p.generation == generation);
        let (Some(dir), Some(p)) = (self.store.peer_cache_dir(), p) else { return };
        let at = now_ms();
        let last = p.cache_saved_at.load(std::sync::atomic::Ordering::SeqCst);
        if !now && at.saturating_sub(last) < SAVE_EVERY_MS {
            return;
        }
        // A forced save is owed even when no session notice preceded it (for example, an outage
        // metadata change). Mark it before the write so a failure remains eligible for shutdown's
        // retry rather than making stale disk state look flushed.
        if now {
            p.cache_dirty_seq.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        }
        // Snapshot each shared structure independently. The writer gate preserves ordering for
        // one peer, while readers and notices for every other peer continue immediately.
        let snapshot_seq = p.cache_dirty_seq.load(std::sync::atomic::Ordering::SeqCst);
        // The rows' own `Arc`s, not copies: the save writes only those that changed.
        let rows: Vec<(String, Arc<RemoteSession>)> = self
            .remote_sessions
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .of_peer(peer)
            .map(|(key, r)| (key.clone(), r.clone()))
            .collect();
        let link = p.link();
        let link = Link {
            last_seen: link.last_seen,
            down_since: link.down_since,
            next_retry_at: link.next_retry_at,
        };
        let write = || -> anyhow::Result<()> {
            #[cfg(test)]
            {
                self.cache_test_writes.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                self.cache_test_write_started.store(true, std::sync::atomic::Ordering::SeqCst);
                let delay_peer =
                    self.cache_test_delay_peer.lock().unwrap_or_else(|e| e.into_inner()).clone();
                let delay =
                    self.cache_test_write_delay_ms.load(std::sync::atomic::Ordering::SeqCst);
                if delay != 0 && delay_peer.as_deref().is_none_or(|p| p == peer) {
                    std::thread::sleep(std::time::Duration::from_millis(delay));
                }
            }
            let wrote = on_disk.save(&dir, peer, rows, link)?;
            let (bytes, snapshot) = (wrote.total(), wrote.snapshot);
            tracing::trace!(peer = %peer, bytes, snapshot, "peer cache saved");
            #[cfg(test)]
            self.cache_test_bytes.fetch_add(wrote.total(), std::sync::atomic::Ordering::SeqCst);
            Ok(())
        };
        if let Err(e) = write() {
            tracing::warn!(peer = %peer, "saving the peer's last-known sessions failed: {e}");
        } else {
            #[cfg(test)]
            if let Some((entered, release)) =
                self.cache_test_flush_pause.lock().unwrap_or_else(|e| e.into_inner()).take()
            {
                let _ = entered.send(());
                let _ = release.recv();
            }
            p.cache_saved_at.store(at, std::sync::atomic::Ordering::SeqCst);
            p.cache_flushed_seq.store(snapshot_seq, std::sync::atomic::Ordering::Release);
            p.cache_saved_outage
                .store(link.down_since.is_some(), std::sync::atomic::Ordering::SeqCst);
        }
    }

    /// A peer that starts with no rows here (this daemon just started) lists
    /// its saved ones, stale, until its first handshake replaces them.
    pub(super) fn load_peer_cache(&self, peer: &crate::peer::Peer) {
        let Some(dir) = self.store.peer_cache_dir() else { return };
        let Some(saved) = disk::load(&dir, &peer.name) else { return };
        peer.seed_cached_link(saved.last_seen, saved.down_since, saved.next_retry_at);
        peer.cache_saved_outage
            .store(saved.down_since.is_some(), std::sync::atomic::Ordering::SeqCst);
        let mut map = self.remote_sessions.lock().unwrap_or_else(|e| e.into_inner());
        if map.has_peer(&peer.name) {
            return;
        }
        for mut summary in saved.sessions {
            let Some(receipt) = super::peers::session_receipt(&summary) else { continue };
            mark_stale(&mut summary, saved.last_seen);
            // An older build saved rows with a peer's own display line.
            super::drop_display_lines(&mut summary);
            let remote = RemoteSession { peer: peer.name.clone(), summary, receipt };
            map.insert(remote.receipt.qualified_id(), remote);
        }
    }

    /// `forget_peer_files` under the rows lock (`remove_peer` holds it itself).
    #[cfg(test)]
    pub(super) fn forget_peer_cache(&self, peer: &str) {
        let writer = self.peer_cache_writer(peer);
        let _writer = writer.lock().unwrap_or_else(|e| e.into_inner());
        let _rows = self.remote_sessions.lock().unwrap_or_else(|e| e.into_inner());
        self.forget_peer_files(peer);
    }

    /// `forget_peer_cache` with the rows lock held by the caller (`remove_peer`).
    pub(super) fn forget_peer_files(&self, peer: &str) {
        if let Some(dir) = self.store.peer_cache_dir() {
            disk::remove(&dir, peer);
        }
        // And its sessions' event snapshots (`peer_snapshot.rs`), under the rows lock once the
        // peer has left the registry (`remove_peer`): a listing or capture of it that found it
        // current (under this lock) has sent its op already and none after it does, so no
        // listing that lets a page start a copy again comes after this.
        self.peer_snapshots.forget_peer(peer);
    }

    /// A peer `name` that is registered but whose link is down, having listed `rows` and taken
    /// attachments before it went: what a server test sends to while the peer is unreachable.
    #[cfg(test)]
    pub(crate) fn seed_down_peer(&self, name: &str, rows: Vec<Value>) -> Arc<crate::peer::Peer> {
        use crate::peer::PeerNotice;
        let (tx, _rx) = tokio::sync::mpsc::channel(8);
        let peer = crate::peer::Peer::new(name, "ws://127.0.0.1:9", None, None, tx);
        peer.seed_send_attach(true);
        self.peers.lock().unwrap().insert(name.to_owned(), peer.clone());
        self.apply_peer_notice(name, peer.generation, PeerNotice::Sessions(rows));
        self.apply_peer_notice(name, peer.generation, PeerNotice::Disconnected("down".into()));
        peer
    }

    /// `peer`'s link back and ready, listing `rows` again: what a finished handshake leaves.
    #[cfg(test)]
    pub(crate) fn seed_peer_back(&self, peer: &crate::peer::Peer, rows: Vec<Value>) {
        use crate::peer::PeerNotice;
        peer.connected.store(true, std::sync::atomic::Ordering::SeqCst);
        self.apply_peer_notice(&peer.name, peer.generation, PeerNotice::Sessions(rows));
        self.apply_peer_notice(&peer.name, peer.generation, PeerNotice::Connected);
    }

    /// The refusal for `PEER/name` when PEER is a peer that is down and
    /// lists no such session: the session may well be there, so say the
    /// peer is unreachable rather than that the session does not exist.
    pub fn peer_down_for(&self, key: &str) -> Option<RpcError> {
        let (name, rest) = key.split_once('/')?;
        let peer = self.peer(name).filter(|_| !rest.is_empty())?;
        (!peer.connected.load(std::sync::atomic::Ordering::SeqCst))
            .then(|| peer.unreachable_error())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::peer::PeerNotice;

    fn hub_at(dir: &std::path::Path) -> Arc<Hub> {
        let mut cfg = crate::config::Config::default();
        cfg.store.mode = crate::config::StoreMode::Local;
        let store = crate::store::open(&cfg.store, dir).unwrap();
        Hub::new(cfg, store)
    }

    fn test_hub() -> (Arc<Hub>, cmux_unix_socket::TestDir) {
        let dir = cmux_unix_socket::short_test_dir("acpmux-pc");
        (hub_at(dir.path()), dir)
    }

    #[tokio::test]
    async fn an_empty_peer_outage_survives_a_daemon_restart() {
        let (hub, dir) = test_hub();
        let peer = crate::peer::Peer::new(
            "absent",
            "invalid://peer",
            None,
            None,
            hub.peer_notices.clone(),
        );
        let down_since = now_ms() - 86_400_001;
        peer.seed_outage(Some(down_since));
        hub.peers.lock().unwrap().insert("absent".into(), peer.clone());
        let mut settled = peer.settled();
        let running = tokio::spawn(peer.clone().run());
        tokio::time::timeout(std::time::Duration::from_secs(5), settled.changed())
            .await
            .unwrap()
            .unwrap();
        peer.stop();
        running.await.unwrap();

        // The first daemon's shutdown seal: the journal's lock passes to the next one.
        hub.seal();
        let again = hub_at(dir.path());
        let restored = add_idle_peer(&again, "absent");
        again.load_peer_cache(&restored);
        assert_eq!(restored.link().down_since, Some(down_since));
        assert_eq!(restored.link().last_seen, None, "never reached is preserved");
        assert!(
            restored.link().next_retry_at.is_some_and(|at| at > now_ms()),
            "the remaining parked interval survives reboot"
        );
        assert!(again.remote_sessions().is_empty());
        let mut backoff = crate::peer_link::Backoff::default();
        assert_eq!(
            restored.link().retry_delay(&mut backoff, now_ms(), 0.0),
            std::time::Duration::from_secs(3_600)
        );
    }

    #[test]
    fn older_peer_caches_have_no_proven_outage_age() {
        let saved: Saved = serde_json::from_value(json!({"lastSeen": 1, "sessions": []})).unwrap();
        assert_eq!(saved.down_since, None);
        assert_eq!(saved.next_retry_at, None);
    }

    /// A peer that is registered but never runs: its link stays down.
    fn add_idle_peer(hub: &Hub, name: &str) -> Arc<crate::peer::Peer> {
        let (tx, _rx) = tokio::sync::mpsc::channel(8);
        let peer = crate::peer::Peer::new(name, "ws://127.0.0.1:9", None, None, tx);
        hub.peers.lock().unwrap().insert(name.to_owned(), peer.clone());
        peer
    }

    fn remote(id: &str, name: &str) -> Value {
        json!({"sessionId": id, "name": name, "status": "idle", "turnCount": 1, "updatedAt": 5})
    }

    #[test]
    fn a_down_peer_keeps_its_sessions_listed_as_stale_and_restarts_list_them_again() {
        let (hub, dir) = test_hub();
        let peer = add_idle_peer(&hub, "huge-blue");
        hub.apply_peer_notice(
            "huge-blue",
            peer.generation,
            PeerNotice::Sessions(vec![remote("m1", "lane")]),
        );
        let fresh = hub.remote_sessions();
        assert_eq!(fresh.len(), 1);
        assert_eq!(fresh[0]["stale"], false, "{fresh:?}");
        assert_eq!(fresh[0]["peer"], "huge-blue");

        peer.seed_last_seen(Some(now_ms() - 40_000));
        hub.apply_peer_notice(
            "huge-blue",
            peer.generation,
            PeerNotice::Disconnected("connect timed out".into()),
        );
        let stale = hub.remote_sessions();
        assert_eq!(stale.len(), 1, "kept, not dropped");
        assert_eq!(stale[0]["status"], "unreachable", "what older clients read");
        assert_eq!(stale[0]["stale"], true);
        assert!(stale[0]["lastSeen"].is_u64(), "{stale:?}");
        assert_eq!(stale[0]["peerState"], "reconnecting");
        assert_eq!(hub.peers()[0]["sessions"], 1);
        assert_eq!(hub.peers()[0]["state"], "reconnecting");
        assert!(dir.path().join("peers/huge-blue.json").is_file());

        // This daemon restarts while the peer is still down (its shutdown seal passes the
        // journal's lock to the next one).
        hub.seal();
        let again = hub_at(dir.path());
        let peer = add_idle_peer(&again, "huge-blue");
        again.load_peer_cache(&peer);
        let listed = again.remote_sessions();
        assert_eq!(listed.len(), 1, "{listed:?}");
        assert_eq!(listed[0]["name"], "huge-blue/lane");
        assert_eq!(listed[0]["stale"], true);
        assert_eq!(peer.state(), crate::peer_link::PeerState::Reconnecting);

        // Its first handshake replaces the saved rows with fresh ones.
        again.apply_peer_notice(
            "huge-blue",
            peer.generation,
            PeerNotice::Sessions(vec![remote("m1", "lane")]),
        );
        let back = again.remote_sessions();
        assert_eq!(back[0]["stale"], false, "{back:?}");
        assert_eq!(back[0]["status"], "idle");

        again.forget_peer_cache("huge-blue");
        assert!(!dir.path().join("peers/huge-blue.json").exists());
        assert!(!dir.path().join("peers/huge-blue.journal").exists());
    }

    /// A peer's list is input from another machine: a row that is not an object (a buggy or
    /// hostile peer) is skipped, and the daemon keeps the peer's good rows. Before, the row
    /// reached `views::decide`, whose `summary["indicator"] = ..` panics on a non-object, and
    /// the peer-notice loop runs under `supervise::once`: the daemon stopped, then stopped
    /// again each time the peer reconnected with the same list.
    #[test]
    fn a_peer_row_that_is_not_an_object_is_skipped_not_a_panic() {
        let (hub, _dir) = test_hub();
        let peer = add_idle_peer(&hub, "huge-blue");
        for row in [json!("x"), json!(7), json!([1]), json!(true), Value::Null] {
            let kept = Hub::remote_summary("huge-blue", row.clone());
            assert_eq!(kept, row, "a row that is not an object is not changed");
        }
        hub.apply_peer_notice(
            "huge-blue",
            peer.generation,
            PeerNotice::Sessions(vec![json!("x"), json!(7), json!([1]), remote("m1", "lane")]),
        );
        let listed = hub.remote_sessions();
        assert_eq!(listed.len(), 1, "{listed:?}");
        assert_eq!(listed[0]["name"], "huge-blue/lane");
    }

    /// A cache an older build saved can hold a peer's own display line on a pending ask: the
    /// row a restart lists carries none (`drop_display_lines`), the tool's own input kept.
    #[test]
    fn a_saved_rows_display_line_is_dropped_when_loaded() {
        let (hub, dir) = test_hub();
        let mut row = Hub::remote_summary("huge-blue", remote("m1", "lane"));
        row["pending"] = json!([{"permissionId": "p1", "request": {"toolCall": {
            "rawInput": {"_meta": {"acpmux": {"display": {"headline": "the tool's own input"}}}},
            "_meta": {"acpmux": {"display": {"headline": "Leo wants to say hi"}}}}}}]);
        std::fs::create_dir_all(dir.path().join("peers")).unwrap();
        let saved = json!({"lastSeen": now_ms() - 40_000, "sessions": [row]});
        std::fs::write(dir.path().join("peers/huge-blue.json"), saved.to_string()).unwrap();
        let peer = add_idle_peer(&hub, "huge-blue");
        hub.load_peer_cache(&peer);
        let listed = Value::from(hub.remote_sessions());
        assert_eq!(listed[0]["name"], "huge-blue/lane", "{listed}");
        assert!(!listed.to_string().contains("Leo wants to say hi"), "{listed}");
        assert!(listed.to_string().contains("the tool's own input"), "{listed}");
    }

    #[tokio::test]
    async fn a_request_for_a_down_peers_session_is_peer_unreachable_not_no_session() {
        let (hub, _dir) = test_hub();
        let peer = add_idle_peer(&hub, "huge-blue");
        *peer.last_error.lock().unwrap() = Some("connect timed out".into());
        peer.seed_last_seen(Some(now_ms() - 40_000));
        hub.apply_peer_notice(
            "huge-blue",
            peer.generation,
            PeerNotice::Sessions(vec![remote("m1", "lane")]),
        );
        hub.apply_peer_notice(
            "huge-blue",
            peer.generation,
            PeerNotice::Disconnected("connect timed out".into()),
        );

        let (found, id, _) = hub.resolve_remote("huge-blue/lane").expect("still listed");
        let e = found.request(method::SESSION_PROMPT, json!({"sessionId": id})).await.unwrap_err();
        assert!(
            e.message.starts_with("peer_unreachable: huge-blue (reconnecting, last seen 4"),
            "{}",
            e.message
        );
        assert!(
            e.message.contains(": connect timed out); the request was not sent"),
            "{}",
            e.message
        );
        assert_eq!(e.data.as_ref().unwrap()["reason"], "peer_unreachable");

        // A name the peer never listed here: still the peer, not no_session.
        let e = hub.peer_down_for("huge-blue/other").expect("peer is down");
        assert!(e.message.starts_with("peer_unreachable: huge-blue"), "{}", e.message);
        assert!(hub.peer_down_for("nopeer/lane").is_none());
        assert!(hub.peer_down_for("lane").is_none());
    }

    #[test]
    fn a_stale_row_is_unreachable_with_no_stuck_details() {
        let mut row = json!({"sessionId": "m1", "status": "ready", "state": "stuck",
            "stuckReason": "capacity", "stuckSince": 7, "stuckError": "HTTP 503"});
        assert!(mark_stale(&mut row, Some(9)));
        assert_eq!(row["state"], "unreachable", "{row}");
        for key in ["stuckReason", "stuckSince", "stuckError"] {
            assert!(row[key].is_null(), "{key}: {row}");
        }
    }

    #[test]
    fn a_burst_of_session_lists_is_coalesced_to_throttled_cache_writes() {
        let (hub, _dir) = test_hub();
        let peer = add_idle_peer(&hub, "builder");
        hub.cache_test_write_delay_ms.store(0, std::sync::atomic::Ordering::SeqCst);
        hub.cache_test_writes.store(0, std::sync::atomic::Ordering::SeqCst);
        hub.apply_peer_notice(
            "builder",
            peer.generation,
            PeerNotice::Sessions(vec![remote("m1", "lane")]),
        );
        for at in 0..32 {
            let mut row = remote("m1", "lane");
            row["updatedAt"] = json!(at + 10);
            hub.apply_peer_notice("builder", peer.generation, PeerNotice::Sessions(vec![row]));
        }
        let writes = hub.cache_test_writes.load(std::sync::atomic::Ordering::SeqCst);
        assert!(writes < 32, "writes={writes}");
    }

    #[test]
    fn a_burst_has_at_most_one_pending_cache_writer_per_peer() {
        let (hub, _dir) = test_hub();
        let peer = add_idle_peer(&hub, "builder");
        hub.cache_test_writes.store(0, std::sync::atomic::Ordering::SeqCst);
        hub.cache_test_write_started.store(false, std::sync::atomic::Ordering::SeqCst);
        hub.cache_test_write_delay_ms.store(200, std::sync::atomic::Ordering::SeqCst);
        hub.apply_peer_notice(
            "builder",
            peer.generation,
            PeerNotice::Sessions(vec![remote("m1", "lane")]),
        );
        for _ in 0..100_000 {
            if hub.cache_test_write_started.load(std::sync::atomic::Ordering::SeqCst) {
                break;
            }
            std::thread::yield_now();
        }
        for at in 0..32 {
            let mut row = remote("m1", "lane");
            row["updatedAt"] = json!(at + 10);
            hub.apply_peer_notice("builder", peer.generation, PeerNotice::Sessions(vec![row]));
        }
        assert_eq!(hub.cache_test_writes.load(std::sync::atomic::Ordering::SeqCst), 1);
        hub.cache_test_write_delay_ms.store(0, std::sync::atomic::Ordering::SeqCst);
        for _ in 0..100_000 {
            if !peer.cache_write_pending.load(std::sync::atomic::Ordering::SeqCst) {
                break;
            }
            std::thread::yield_now();
        }
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn an_immediate_stop_flushes_a_notice_before_its_worker_starts() {
        let (hub, dir) = test_hub();
        let peer = add_idle_peer(&hub, "builder");
        hub.cache_test_write_delay_ms.store(200, std::sync::atomic::Ordering::SeqCst);
        let mut changed = remote("m1", "lane");
        changed["status"] = json!("running");
        hub.apply_peer_notice("builder", peer.generation, PeerNotice::Sessions(vec![changed]));
        assert!(peer.cache_is_dirty());
        // This is the notice loop's shutdown flush: it only visits dirty peers, then waits for
        // the ordered writer before returning from shutdown.
        if peer.cache_is_dirty() {
            hub.save_peer_cache("builder", peer.generation, true);
        }
        hub.cache_test_write_delay_ms.store(0, std::sync::atomic::Ordering::SeqCst);
        let saved = disk::saved_json(&dir.path().join("peers"), "builder");
        assert_eq!(saved["sessions"][0]["status"], "running");
    }

    #[test]
    fn a_notice_during_a_write_remains_dirty_for_the_stop_flush() {
        let (hub, dir) = test_hub();
        let peer = add_idle_peer(&hub, "builder");
        hub.cache_test_write_started.store(false, std::sync::atomic::Ordering::SeqCst);
        hub.cache_test_write_delay_ms.store(200, std::sync::atomic::Ordering::SeqCst);
        hub.apply_peer_notice(
            "builder",
            peer.generation,
            PeerNotice::Sessions(vec![remote("old", "lane")]),
        );
        for _ in 0..100_000 {
            if hub.cache_test_write_started.load(std::sync::atomic::Ordering::SeqCst) {
                break;
            }
            std::thread::yield_now();
        }
        hub.apply_peer_notice(
            "builder",
            peer.generation,
            PeerNotice::Sessions(vec![remote("new", "lane")]),
        );
        hub.cache_test_write_delay_ms.store(0, std::sync::atomic::Ordering::SeqCst);
        for _ in 0..100_000 {
            if !peer.cache_write_pending.load(std::sync::atomic::Ordering::SeqCst) {
                break;
            }
            std::thread::yield_now();
        }
        assert!(peer.cache_is_dirty());
        if peer.cache_is_dirty() {
            hub.save_peer_cache("builder", peer.generation, true);
        }
        let saved = disk::saved_json(&dir.path().join("peers"), "builder");
        assert_eq!(saved["sessions"][0]["sessionId"], "new");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_notice_between_write_and_flush_publish_remains_dirty() {
        let (hub, dir) = test_hub();
        let peer = add_idle_peer(&hub, "builder");
        let (entered_tx, entered_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        *hub.cache_test_flush_pause.lock().unwrap() = Some((entered_tx, release_rx));
        hub.apply_peer_notice(
            "builder",
            peer.generation,
            PeerNotice::Sessions(vec![remote("old", "lane")]),
        );
        entered_rx
            .recv_timeout(std::time::Duration::from_secs(2))
            .expect("cache worker never reached the flush publication");
        let projection = super::peers::PeerNoticeProjectionHook::new();
        *hub.peer_notice_projection_hook.lock().unwrap() = Some(projection.clone());
        let (done_tx, done_rx) = std::sync::mpsc::channel();
        let notice = {
            let hub = hub.clone();
            let generation = peer.generation;
            std::thread::spawn(move || {
                hub.apply_peer_notice(
                    "builder",
                    generation,
                    PeerNotice::Sessions(vec![remote("new", "lane")]),
                );
                done_tx.send(()).unwrap();
            })
        };
        assert!(
            projection.wait_reached_timeout(std::time::Duration::from_secs(2)),
            "session notice never reached its projection fence"
        );
        release_tx.send(()).unwrap();
        projection.release();
        done_rx
            .recv_timeout(std::time::Duration::from_secs(2))
            .expect("interleaved session notice did not finish");
        notice.join().unwrap();
        for _ in 0..100_000 {
            if !peer.cache_write_pending.load(std::sync::atomic::Ordering::Acquire) {
                break;
            }
            std::thread::yield_now();
        }
        assert!(peer.cache_is_dirty(), "the interleaved notice lost its dirty marker");
        hub.save_peer_cache("builder", peer.generation, true);
        let saved = disk::saved_json(&dir.path().join("peers"), "builder");
        assert_eq!(saved["sessions"][0]["sessionId"], "new");
    }

    #[test]
    fn disconnect_forces_the_latest_dirty_rows_to_disk() {
        let (hub, dir) = test_hub();
        let peer = add_idle_peer(&hub, "builder");
        hub.cache_test_write_delay_ms.store(0, std::sync::atomic::Ordering::SeqCst);
        hub.cache_test_writes.store(0, std::sync::atomic::Ordering::SeqCst);
        hub.cache_test_write_started.store(false, std::sync::atomic::Ordering::SeqCst);
        hub.apply_peer_notice(
            "builder",
            peer.generation,
            PeerNotice::Sessions(vec![remote("m1", "lane")]),
        );
        for _ in 0..100_000 {
            if hub.cache_test_write_started.load(std::sync::atomic::Ordering::Acquire)
                && !peer.cache_write_pending.load(std::sync::atomic::Ordering::Acquire)
            {
                break;
            }
            std::thread::yield_now();
        }
        assert!(hub.cache_test_write_started.load(std::sync::atomic::Ordering::Acquire));
        assert!(!peer.cache_write_pending.load(std::sync::atomic::Ordering::Acquire));
        let mut changed = remote("m1", "lane");
        changed["status"] = json!("running");
        changed["turnCount"] = json!(7);
        hub.apply_peer_notice("builder", peer.generation, PeerNotice::Sessions(vec![changed]));
        hub.apply_peer_notice("builder", peer.generation, PeerNotice::Disconnected("down".into()));
        // The throttled change reached disk. Its stale marking need not: a load marks every row
        // stale itself (`peer_cache_disk::still_on_disk`).
        let saved = disk::saved_json(&dir.path().join("peers"), "builder");
        assert_eq!(saved["sessions"][0]["turnCount"], 7, "{saved}");
        assert!(hub.cache_test_writes.load(std::sync::atomic::Ordering::SeqCst) >= 2);
        let listed = hub.remote_sessions();
        hub.seal();
        let again = hub_at(dir.path());
        let restored = add_idle_peer(&again, "builder");
        again.load_peer_cache(&restored);
        let back = again.remote_sessions();
        assert_eq!(back[0]["status"], "unreachable", "{back:?}");
        assert_eq!(back[0]["turnCount"], 7, "{back:?}");
        assert_eq!(back[0]["stale"], listed[0]["stale"]);
    }

    #[test]
    fn a_stale_generation_cannot_replace_the_current_peer_rows() {
        let (hub, _dir) = test_hub();
        let old = add_idle_peer(&hub, "builder");
        hub.apply_peer_notice(
            "builder",
            old.generation,
            PeerNotice::Sessions(vec![remote("old", "old-lane")]),
        );
        let replacement = add_idle_peer(&hub, "builder");
        let stale = remote("stale", "stale-lane");
        hub.apply_peer_notice("builder", old.generation, PeerNotice::Sessions(vec![stale]));
        let rows = hub.remote_sessions();
        assert_eq!(replacement.generation, hub.peer("builder").unwrap().generation);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0]["sessionId"], "old");
    }

    #[test]
    fn a_newer_snapshot_wins_when_an_older_write_is_still_serializing() {
        let (hub, dir) = test_hub();
        let peer = add_idle_peer(&hub, "builder");
        hub.apply_peer_notice(
            "builder",
            peer.generation,
            PeerNotice::Sessions(vec![remote("old", "lane")]),
        );
        hub.cache_test_writes.store(0, std::sync::atomic::Ordering::SeqCst);
        hub.cache_test_write_started.store(false, std::sync::atomic::Ordering::SeqCst);
        hub.cache_test_write_delay_ms.store(100, std::sync::atomic::Ordering::SeqCst);
        let saving = {
            let hub = hub.clone();
            let generation = peer.generation;
            std::thread::spawn(move || hub.save_peer_cache("builder", generation, true))
        };
        for _ in 0..100_000 {
            if hub.cache_test_write_started.load(std::sync::atomic::Ordering::SeqCst) {
                break;
            }
            std::thread::yield_now();
        }
        let mut newer = remote("new", "lane");
        newer["updatedAt"] = json!(99);
        hub.apply_peer_notice("builder", peer.generation, PeerNotice::Sessions(vec![newer]));
        hub.save_peer_cache("builder", peer.generation, true);
        saving.join().unwrap();
        hub.cache_test_write_delay_ms.store(0, std::sync::atomic::Ordering::SeqCst);
        let saved = disk::saved_json(&dir.path().join("peers"), "builder");
        assert_eq!(saved["sessions"][0]["sessionId"], "new");
    }

    #[test]
    fn a_purge_after_an_inflight_snapshot_stays_purged_on_disk() {
        let (hub, dir) = test_hub();
        let peer = add_idle_peer(&hub, "builder");
        hub.cache_test_write_started.store(false, std::sync::atomic::Ordering::SeqCst);
        hub.cache_test_write_delay_ms.store(200, std::sync::atomic::Ordering::SeqCst);
        let mut listed = remote("m1", "lane");
        listed["createdAt"] = json!(5);
        hub.apply_peer_notice("builder", peer.generation, PeerNotice::Sessions(vec![listed]));
        for _ in 0..100_000 {
            if hub.cache_test_write_started.load(std::sync::atomic::Ordering::Acquire) {
                break;
            }
            std::thread::yield_now();
        }
        assert!(hub.cache_test_write_started.load(std::sync::atomic::Ordering::Acquire));

        let purging = {
            let hub = hub.clone();
            let generation = peer.generation;
            std::thread::spawn(move || hub.forget_remote(("builder", generation), "m1", Some(5)))
        };
        purging.join().unwrap();
        hub.cache_test_write_delay_ms.store(0, std::sync::atomic::Ordering::SeqCst);
        // The store keeps an exclusive journal lock for the hub lifetime. Release it before
        // constructing the restart fixture that reloads the cache.
        drop(hub);

        let again = hub_at(dir.path());
        let restored = add_idle_peer(&again, "builder");
        again.load_peer_cache(&restored);
        assert!(again.remote_sessions().is_empty(), "purged row was restored from cache");
    }

    #[test]
    fn a_failed_forced_save_remains_dirty_for_retry() {
        let (hub, dir) = test_hub();
        let peer = add_idle_peer(&hub, "builder");
        let peers_dir = dir.path().join("peers");
        std::fs::create_dir_all(&peers_dir).unwrap();
        std::fs::remove_dir(&peers_dir).unwrap();
        std::fs::write(&peers_dir, b"blocked").unwrap();

        hub.save_peer_cache("builder", peer.generation, true);
        assert!(peer.cache_is_dirty(), "a failed forced save was marked flushed");

        std::fs::remove_file(&peers_dir).unwrap();
        hub.save_peer_cache("builder", peer.generation, true);
        assert!(!peer.cache_is_dirty(), "a successful retry stayed dirty");
    }

    #[test]
    fn one_peer_cache_write_does_not_block_another_peer() {
        let (hub, _dir) = test_hub();
        let slow = add_idle_peer(&hub, "slow");
        let fast = add_idle_peer(&hub, "fast");
        for (name, peer) in [("slow", &slow), ("fast", &fast)] {
            hub.apply_peer_notice(
                name,
                peer.generation,
                PeerNotice::Sessions(vec![remote("m1", name)]),
            );
        }
        hub.cache_test_write_started.store(false, std::sync::atomic::Ordering::SeqCst);
        hub.cache_test_write_delay_ms.store(200, std::sync::atomic::Ordering::SeqCst);
        *hub.cache_test_delay_peer.lock().unwrap() = Some("slow".into());
        let saving = {
            let hub = hub.clone();
            let generation = slow.generation;
            std::thread::spawn(move || hub.save_peer_cache("slow", generation, true))
        };
        for _ in 0..100_000 {
            if hub.cache_test_write_started.load(std::sync::atomic::Ordering::SeqCst) {
                break;
            }
            std::thread::yield_now();
        }
        let started = std::time::Instant::now();
        hub.save_peer_cache("fast", fast.generation, true);
        let elapsed = started.elapsed();
        saving.join().unwrap();
        hub.cache_test_write_delay_ms.store(0, std::sync::atomic::Ordering::SeqCst);
        *hub.cache_test_delay_peer.lock().unwrap() = None;
        assert!(elapsed < std::time::Duration::from_millis(150), "fast save waited {elapsed:?}");
    }

    #[test]
    fn a_peer_notice_does_not_wait_for_another_peers_cache_write() {
        let (hub, _dir) = test_hub();
        let slow = add_idle_peer(&hub, "slow");
        let fast = add_idle_peer(&hub, "fast");
        hub.apply_peer_notice(
            "slow",
            slow.generation,
            PeerNotice::Sessions(vec![remote("m1", "slow")]),
        );
        hub.apply_peer_notice(
            "fast",
            fast.generation,
            PeerNotice::Sessions(vec![remote("m1", "fast")]),
        );
        hub.cache_test_write_started.store(false, std::sync::atomic::Ordering::SeqCst);
        hub.cache_test_write_delay_ms.store(200, std::sync::atomic::Ordering::SeqCst);
        *hub.cache_test_delay_peer.lock().unwrap() = Some("slow".into());
        let mut changed = remote("m1", "slow");
        changed["updatedAt"] = json!(99);
        hub.apply_peer_notice("slow", slow.generation, PeerNotice::Sessions(vec![changed]));
        for _ in 0..100_000 {
            if hub.cache_test_write_started.load(std::sync::atomic::Ordering::SeqCst) {
                break;
            }
            std::thread::yield_now();
        }
        let started = std::time::Instant::now();
        hub.apply_peer_notice(
            "fast",
            fast.generation,
            PeerNotice::Sessions(vec![remote("m1", "fast")]),
        );
        assert!(started.elapsed() < std::time::Duration::from_millis(150));
        hub.cache_test_write_delay_ms.store(0, std::sync::atomic::Ordering::SeqCst);
        *hub.cache_test_delay_peer.lock().unwrap() = None;
    }

    #[test]
    fn a_cache_worker_and_full_list_notice_complete_without_lock_order_deadlock() {
        let (hub, _dir) = test_hub();
        let peer = add_idle_peer(&hub, "builder");
        hub.apply_peer_notice(
            "builder",
            peer.generation,
            PeerNotice::Sessions(vec![remote("m1", "builder")]),
        );
        hub.cache_test_write_started.store(false, std::sync::atomic::Ordering::SeqCst);
        hub.cache_test_write_delay_ms.store(100, std::sync::atomic::Ordering::SeqCst);
        let saving = {
            let hub = hub.clone();
            let generation = peer.generation;
            std::thread::spawn(move || hub.save_peer_cache("builder", generation, true))
        };
        for _ in 0..100_000 {
            if hub.cache_test_write_started.load(std::sync::atomic::Ordering::Acquire) {
                break;
            }
            std::thread::yield_now();
        }
        let (done_tx, done_rx) = std::sync::mpsc::channel();
        let applying = {
            let hub = hub.clone();
            let generation = peer.generation;
            std::thread::spawn(move || {
                hub.apply_peer_notice(
                    "builder",
                    generation,
                    PeerNotice::Sessions(vec![remote("m1", "builder")]),
                );
                done_tx.send(()).unwrap();
            })
        };
        done_rx
            .recv_timeout(std::time::Duration::from_secs(1))
            .expect("cache worker and full-list notice deadlocked on hub locks");
        applying.join().unwrap();
        saving.join().unwrap();
        hub.cache_test_write_delay_ms.store(0, std::sync::atomic::Ordering::SeqCst);
    }

    #[test]
    fn a_session_changed_receipt_notice_finishes_without_relocking_peers() {
        let (hub, _dir) = test_hub();
        let peer = add_idle_peer(&hub, "builder");
        let mut session = remote("m1", "lane");
        session["sessionReceipt"] =
            crate::session_identity::SessionReceipt::new("builder", "m1", None, 1).to_value();
        let (done_tx, done_rx) = std::sync::mpsc::channel();
        let applying = {
            let hub = hub.clone();
            let generation = peer.generation;
            std::thread::spawn(move || {
                hub.apply_peer_notice(
                    "builder",
                    generation,
                    PeerNotice::SessionChanged { session, kind: "status".into(), seq: 1 },
                );
                done_tx.send(()).unwrap();
            })
        };
        done_rx
            .recv_timeout(std::time::Duration::from_secs(1))
            .expect("session_changed receipt notice re-locked the peers mutex");
        applying.join().unwrap();
    }

    #[test]
    fn held_ask_release_after_sessions_does_not_reenter_a_notice_lock() {
        let (hub, _dir) = test_hub();
        let peer = add_idle_peer(&hub, "builder");
        hub.held_peer_asks.hold(
            "builder",
            peer.generation,
            "m1",
            PeerNotice::SessionChanged {
                session: remote("m1", "lane"),
                kind: "status".into(),
                seq: 1,
            },
        );
        hub.apply_peer_notice(
            "builder",
            peer.generation,
            PeerNotice::Sessions(vec![remote("m1", "lane")]),
        );
        assert_eq!(hub.remote_sessions().len(), 1);
        hub.held_peer_asks.hold(
            "builder",
            peer.generation,
            "m2",
            PeerNotice::SessionChanged {
                session: remote("m2", "lane-2"),
                kind: "status".into(),
                seq: 2,
            },
        );
        hub.apply_peer_notice(
            "builder",
            peer.generation,
            PeerNotice::SessionChanged {
                session: remote("m2", "lane-2"),
                kind: "status".into(),
                seq: 3,
            },
        );
        assert_eq!(hub.remote_sessions().len(), 2);
    }

    #[test]
    fn removing_a_peer_cannot_be_followed_by_its_in_flight_cache_write() {
        let (hub, dir) = test_hub();
        let peer = add_idle_peer(&hub, "builder");
        hub.apply_peer_notice(
            "builder",
            peer.generation,
            PeerNotice::Sessions(vec![remote("m1", "lane")]),
        );
        hub.cache_test_write_started.store(false, std::sync::atomic::Ordering::SeqCst);
        hub.cache_test_write_delay_ms.store(100, std::sync::atomic::Ordering::SeqCst);
        let saving = {
            let hub = hub.clone();
            let generation = peer.generation;
            std::thread::spawn(move || hub.save_peer_cache("builder", generation, true))
        };
        for _ in 0..100_000 {
            if hub.cache_test_write_started.load(std::sync::atomic::Ordering::SeqCst) {
                break;
            }
            std::thread::yield_now();
        }
        let runtime = tokio::runtime::Runtime::new().unwrap();
        runtime.block_on(hub.remove_peer("builder")).unwrap();
        saving.join().unwrap();
        hub.cache_test_write_delay_ms.store(0, std::sync::atomic::Ordering::SeqCst);
        assert!(!dir.path().join("peers/builder.json").exists());
        assert!(!dir.path().join("peers/builder.journal").exists());
    }
}
