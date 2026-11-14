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
    /// [`SAVE_EVERY_MS`] (a test may set it shorter).
    pub(super) fn cache_save_every_ms(&self) -> u64 {
        #[cfg(test)]
        {
            self.cache_test_save_every_ms.load(std::sync::atomic::Ordering::Relaxed)
        }
        #[cfg(not(test))]
        SAVE_EVERY_MS
    }

    /// [`Hub::cache_save_every_ms`] as a duration.
    pub(super) fn cache_save_every(&self) -> std::time::Duration {
        std::time::Duration::from_millis(self.cache_save_every_ms())
    }

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
            if at.saturating_sub(last) < self.cache_save_every_ms()
                || p.cache_write_pending.swap(true, std::sync::atomic::Ordering::AcqRel)
            {
                // Put off: the notice loop saves it when it is due (`peer_cache_kick`).
                self.peer_cache_kick.notify_one();
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
        if !now && at.saturating_sub(last) < self.cache_save_every_ms() {
            self.peer_cache_kick.notify_one();
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
            .settled()
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
            // Still dirty: the notice loop tries again one interval later (the 30 s tick did).
            self.peer_cache_kick.notify_one();
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
        let mut map = self.remote_sessions.write();
        if map.has_peer(&peer.name) {
            return;
        }
        for mut summary in saved.sessions {
            let Some(receipt) = super::peers::session_receipt(&summary) else { continue };
            mark_stale(&mut summary, saved.last_seen);
            // An older build saved rows with a peer's own display line.
            super::drop_display_lines(&mut summary);
            let summary = PeerRow::new(&summary);
            let remote = RemoteSession { peer: peer.name.clone(), summary, receipt };
            map.insert(remote.receipt.qualified_id(), remote);
        }
    }

    /// `forget_peer_files` under the rows writer lock (`remove_peer` holds it itself).
    #[cfg(test)]
    pub(super) fn forget_peer_cache(&self, peer: &str) {
        let writer = self.peer_cache_writer(peer);
        let _writer = writer.lock().unwrap_or_else(|e| e.into_inner());
        let _rows = self.remote_sessions.fence();
        self.forget_peer_files(peer);
    }

    /// `forget_peer_cache` with the rows writer lock held by the caller (`remove_peer`).
    pub(super) fn forget_peer_files(&self, peer: &str) {
        if let Some(dir) = self.store.peer_cache_dir() {
            disk::remove(&dir, peer);
        }
        // And its sessions' event snapshots (`peer_snapshot.rs`), under the rows writer lock once the
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
        self.apply_peer_notice(name, peer.generation, PeerNotice::sessions_from_values(rows));
        self.apply_peer_notice(name, peer.generation, PeerNotice::Disconnected("down".into()));
        peer
    }

    /// `peer`'s link back and ready, listing `rows` again: what a finished handshake leaves.
    #[cfg(test)]
    pub(crate) fn seed_peer_back(&self, peer: &crate::peer::Peer, rows: Vec<Value>) {
        use crate::peer::PeerNotice;
        peer.connected.store(true, std::sync::atomic::Ordering::SeqCst);
        self.apply_peer_notice(&peer.name, peer.generation, PeerNotice::sessions_from_values(rows));
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
mod tests;
