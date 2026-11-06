//! Part of `peer_snapshot.rs`: a peer back on an older disk gets back what this daemon kept of
//! its chats past where its journal ends (cmuxterm-hq plans/cloud ARCHITECTURE-2026-11.md, P4/E4:
//! kill the machine mid-turn, start a fresh one from an older snapshot, and nothing is lost).
//!
//! Once a peer's link is ready, its list names each chat's generation (`createdAt`) and its
//! journal's end (`lastSeq`). A copy of the same generation that holds every record past that
//! end (`ahead`) is sent to the peer as `_acpmux/journal_restore` (`hub/journal_restore.rs`), with the seqs it
//! had. Until it answers, a page of the peer does not replace the copy (`Store::keeps_ahead`);
//! once it took the records the peer's journal ends where the copy does, and its pages join the
//! copy again (`Store::restored`). A peer that refuses them (its journal ran past that end, or a
//! turn runs there) has another history: the copy goes, as before.
//!
//! A restore counts only once the peer answers that its journal ends at or past the copy's
//! last record: a peer that took part of it (a write that failed midway answers `append_failed`)
//! is sent the same records again, and while any copy is not taken back whole no delivery goes
//! again ([`RETRY_WAITS`], then the peer's next link).
//!
//! While a link's restores run, prompts to that peer wait for them (`Gate`, at most
//! [`GATE_WITHIN`]): a prompt the fresh machine ran first would take the seqs the restore
//! needs. Then the deliveries the peer accepted and may have lost with its disk are delivered
//! again under their own prompt ids (`server/outbox.rs` `redeliver_open`).

use super::*;
use crate::rpc::RpcError;
use tokio::sync::Notify;

/// A peer's row: its session id, its generation and its journal's `lastSeq`.
pub(crate) type Row = (String, u64, u64);
/// A copy ahead of its peer: the session id, its generation, the peer's `lastSeq`, and the
/// records past it.
pub(crate) type Ahead = (String, u64, u64, Vec<Value>);

/// The waits after each try of one copy's restore that did not take it whole; past them it waits
/// for the peer's next link.
const RETRY_WAITS: [Duration; 4] = [
    Duration::from_millis(500),
    Duration::from_secs(1),
    Duration::from_secs(2),
    Duration::from_secs(4),
];

/// The longest a prompt to a peer waits for that peer's restores.
const GATE_WITHIN: Duration = Duration::from_secs(30);

/// The peers whose restores run now.
#[derive(Default)]
pub(crate) struct Gate {
    peers: StdMutex<HashMap<String, u64>>,
    done: Notify,
}

impl Gate {
    fn open(&self, peer: &str) {
        *self
            .peers
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .entry(peer.to_owned())
            .or_default() += 1;
    }

    fn close(&self, peer: &str) {
        let mut peers = self.peers.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(n) = peers.get_mut(peer) {
            *n -= 1;
            if *n == 0 {
                peers.remove(peer);
            }
        }
        drop(peers);
        self.done.notify_waiters();
    }

    fn running(&self, peer: &str) -> bool {
        self.peers.lock().unwrap_or_else(|e| e.into_inner()).contains_key(peer)
    }

    /// Waits until no restore of `peer` runs, at most [`GATE_WITHIN`].
    pub(crate) async fn wait(&self, peer: &str) {
        let deadline = tokio::time::Instant::now() + GATE_WITHIN;
        loop {
            let done = self.done.notified();
            tokio::pin!(done);
            done.as_mut().enable();
            if !self.running(peer) {
                return;
            }
            if tokio::time::timeout_at(deadline, done).await.is_err() {
                tracing::warn!(peer, "journal restores still run; the prompt goes on");
                return;
            }
        }
    }
}

impl PeerSnapshots {
    /// The copies of `peer`'s chats that hold records past where `rows` say its journals end.
    fn ahead(&self, peer: &str, rows: Vec<Row>) -> Vec<Ahead> {
        let (tx, rx) = mpsc::sync_channel(1);
        let sent = {
            let mut dropped = self.dropped();
            self.send_unsent(&mut dropped)
                && self.reserve(OP_BYTES)
                && self.enqueue(OP_BYTES, Op::Ahead { peer: peer.to_owned(), rows, reply: tx })
        };
        if !sent {
            return Vec::new();
        }
        blocking(|| rx.recv_timeout(ANSWER_WITHIN)).unwrap_or_default()
    }

    fn restored(&self, (peer, mux): (&str, &str), last: Option<u64>) {
        let key = (peer.to_owned(), mux.to_owned());
        self.admit(peer, OP_BYTES + mux.len() as u64, false, || Op::Restored { key, last });
    }

    /// Prompts to `peer` wait here while its restores run.
    pub(crate) async fn restores_done(&self, peer: &str) {
        self.restoring.wait(peer).await;
    }
}

impl Store {
    /// Whether copy `c` stays over `page`, a page of a peer behind it: the peer said where its
    /// journal ends, and the copy holds every record past it, which the peer can take back.
    pub(super) fn keeps_ahead(c: &Kept, page: &Page) -> bool {
        let seen = page.host_last_seq.or(page.through);
        seen.is_some_and(|s| c.head.first_seq <= s + 1 && s < c.head.last_seq)
    }

    pub(super) fn ahead(&mut self, peer: &str, rows: Vec<Row>) -> Vec<Ahead> {
        let mut out = Vec::new();
        for (mux, generation, last) in rows {
            let key = (peer.to_owned(), mux);
            let ahead = |c: &Kept| {
                c.head.generation == Some(generation)
                    && last < c.head.last_seq
                    && c.head.first_seq <= last + 1
            };
            if !self.copies.get(&key).is_some_and(ahead) || !self.load(&key) {
                continue;
            }
            let Some(records) = self.copies.get(&key).and_then(|c| c.records.as_ref()) else {
                continue;
            };
            let past: Vec<Value> = records.range(last + 1..).map(|(_, r)| r.clone()).collect();
            if !past.is_empty() && past.len() <= crate::hub::journal_restore::MAX_RECORDS {
                out.push((key.1, generation, last, past));
            }
        }
        out
    }

    /// The peer's answer to a restore of `key`: it ends at `last` now (its pages join again), or
    /// it refused (None: it is another history, and the copy goes).
    pub(super) fn restored(&mut self, key: &Key, last: Option<u64>) {
        match last {
            Some(last) => {
                if let Some(c) = self.copies.get_mut(key) {
                    c.head.host_last_seq = last.max(c.head.last_seq);
                    // A page of the new link joins it from now on.
                    c.joined = None;
                }
            }
            None => self.remove(key),
        }
    }
}

impl Hub {
    /// Peer `peer` (instance `generation`) is ready on a new link, its sessions listed: copies
    /// ahead of its journals go back to it, then what it accepted and may have lost is delivered
    /// again.
    pub(in crate::hub) fn restore_peer_journals(self: &Arc<Self>, peer: &str, generation: u64) {
        let rows = self.journal_ends(peer);
        let gate = &self.peer_snapshots.restoring;
        gate.open(peer);
        let (hub, peer) = (self.clone(), peer.to_owned());
        tokio::spawn(async move {
            struct Close(Arc<Hub>, String);
            impl Drop for Close {
                fn drop(&mut self) {
                    self.0.peer_snapshots.restoring.close(&self.1);
                }
            }
            let close = Close(hub.clone(), peer.clone());
            let ahead = {
                let (hub, peer) = (hub.clone(), peer.clone());
                tokio::task::spawn_blocking(move || hub.peer_snapshots.ahead(&peer, rows))
                    .await
                    .unwrap_or_default()
            };
            // Whether a copy is still ahead of the peer's journal: then nothing is delivered again,
            // since a resend could take the seqs its records need.
            let mut unfinished = false;
            for (mux, created_at, after, records) in ahead {
                let Some(through) = records.iter().filter_map(seq_of).max() else { continue };
                let params = json!({"sessionId": mux, "createdAt": created_at,
                                    "afterSeq": after, "records": records});
                let mut done = false;
                for wait in RETRY_WAITS {
                    let Some(link) = hub.peer(&peer).filter(|p| p.generation == generation) else {
                        break;
                    };
                    match link.request("_acpmux/journal_restore", params.clone()).await {
                        // Taken back whole: the peer's journal ends at or past the copy's last.
                        Ok(answer)
                            if answer
                                .get("lastSeq")
                                .and_then(Value::as_u64)
                                .is_some_and(|last| last >= through) =>
                        {
                            let last = answer.get("lastSeq").and_then(Value::as_u64);
                            tracing::info!(peer, session = %mux, after, ?last, "journal restored");
                            hub.peer_snapshots.restored((&peer, &mux), last);
                            done = true;
                            break;
                        }
                        Err(e) if refused(&e) => {
                            tracing::info!(peer, session = %mux, "journal restore refused: {}", e.message);
                            hub.peer_snapshots.restored((&peer, &mux), None);
                            done = true;
                            break;
                        }
                        // Partly taken, the link, or an older peer: the copy stays, and the same
                        // records go again (the peer appends only what it lacks).
                        Ok(answer) => {
                            tracing::warn!(peer, session = %mux, "journal restore short: {answer}");
                        }
                        Err(e) => {
                            tracing::warn!(peer, session = %mux, "journal restore failed: {}", e.message);
                        }
                    }
                    tokio::time::sleep(wait).await;
                }
                unfinished |= !done;
            }
            drop(close);
            // A copy not taken back whole waits for the peer's next link, and so does every
            // delivery to it.
            if !unfinished {
                crate::server::outbox::redeliver_open(&hub, &peer);
            }
        });
    }
}

/// The peer answered that its journal is another history than the copy's.
fn refused(e: &RpcError) -> bool {
    let reason = e.data.as_ref().and_then(|d| d.get("reason")).and_then(Value::as_str);
    matches!(reason, Some("generation" | "diverged" | "busy"))
}

impl Hub {
    /// Each listed session of `peer`: its id, its generation and its journal's `lastSeq`.
    fn journal_ends(&self, peer: &str) -> Vec<Row> {
        let map = self.remote_sessions.lock().unwrap_or_else(|e| e.into_inner());
        map.of_peer(peer)
            .filter_map(|(_, r)| {
                let created = r.summary.get("createdAt").and_then(Value::as_u64)?;
                let last = r.summary.get("lastSeq").and_then(Value::as_u64)?;
                Some((r.receipt.mux_session_id.clone(), created, last))
            })
            .collect()
    }
}
