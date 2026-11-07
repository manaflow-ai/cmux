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
//! Until a link's restores are decided, prompts to that peer wait for them (`Gate`, at most
//! [`GATE_WITHIN`], then they fail): a prompt the fresh machine ran first would take the seqs the
//! restore needs. Only a positive answer releases them: the copies read and none ahead, or each
//! one taken back whole (or refused as another history). A read that fails (the store's queue
//! full, its thread gone, no answer) is "maybe ahead": it is read again ([`READ_WAITS`]), and
//! past them every prompt to the peer fails visibly until it reconnects. A copy not taken back
//! holds its own session the same way. Then, with nothing held, the deliveries the peer
//! accepted and may have lost with its disk are delivered again under their own prompt ids
//! (`server/outbox.rs` `redeliver_open`); with anything held, none is.

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

/// The waits before each read again of whether a copy is ahead, when a read fails.
const READ_WAITS: [Duration; 5] = [
    Duration::from_millis(500),
    Duration::from_secs(1),
    Duration::from_secs(2),
    Duration::from_secs(4),
    Duration::from_secs(8),
];

/// The longest a prompt to a peer waits for that peer's restores, after which it fails.
const GATE_WITHIN: Duration = Duration::from_secs(30);

/// What a peer's link decided of its copies.
#[derive(Clone)]
struct Decision {
    link: Link,
    /// The sessions still held: a copy not taken back whole, or every one (None) when it could
    /// not be read whether any copy is ahead. A prompt to a held session fails visibly until a
    /// later link decides again; nothing is delivered again to the peer meanwhile.
    held: Option<HashSet<String>>,
}

/// For each peer, the link (instance and link epoch) whose restore decision is made. A prompt
/// to a peer on a link not decided yet waits ([`Gate::wait`]). The peer reads its link ready
/// before the hub hears of it (`peer.rs` sets `connected`, then sends `Connected`), so this goes
/// by the link the peer is on, not by a notice: no prompt reaches a fresh machine ahead of its
/// restore.
#[derive(Default)]
pub(crate) struct Gate {
    decided: StdMutex<HashMap<String, Decision>>,
    done: Notify,
}

impl Gate {
    fn decide(&self, peer: &str, decision: Decision) {
        let mut decided = self.decided.lock().unwrap_or_else(|e| e.into_inner());
        if decided.get(peer).is_none_or(|d| d.link <= decision.link) {
            decided.insert(peer.to_owned(), decision);
        }
        drop(decided);
        self.done.notify_waiters();
    }

    /// The decision of `peer`'s current link, if made.
    fn decision(&self, peer: &crate::peer::Peer) -> Option<Decision> {
        let link = (peer.generation, peer.link_epoch());
        let decided = self.decided.lock().unwrap_or_else(|e| e.into_inner());
        decided.get(&peer.name).filter(|d| d.link >= link).cloned()
    }

    /// Waits until `peer`'s current link has its restore decision, while the link is up, at most
    /// [`GATE_WITHIN`]; then a prompt to `session` goes unless the decision holds it. A link that
    /// is down waits for nothing: the request is refused as unreachable as before.
    pub(crate) async fn wait(
        &self,
        peer: &crate::peer::Peer,
        session: &str,
    ) -> Result<(), RpcError> {
        let deadline = tokio::time::Instant::now() + GATE_WITHIN;
        loop {
            let done = self.done.notified();
            tokio::pin!(done);
            done.as_mut().enable();
            if !peer.ready() {
                return Ok(());
            }
            if let Some(d) = self.decision(peer) {
                return match d.held {
                    Some(held) if !held.contains(session) => Ok(()),
                    _ => Err(held_error(&peer.name)),
                };
            }
            // A drop ends the wait at once too: its notice runs no restore, so the link is read
            // again at most every 100 ms.
            let poll = tokio::time::Instant::now() + Duration::from_millis(100);
            if tokio::time::timeout_at(deadline.min(poll), done).await.is_err()
                && tokio::time::Instant::now() >= deadline
            {
                return Err(held_error(&peer.name));
            }
        }
    }
}

fn held_error(peer: &str) -> RpcError {
    RpcError::new(
        -32000,
        format!(
            "{peer} came back on an older copy of its disk and this chat's newer history could not be given back to it yet; the prompt was not sent (it is tried again when {peer} reconnects)"
        ),
    )
    .with_data(json!({"reason": "restore_pending", "peer": peer}))
}

impl PeerSnapshots {
    /// The copies of `peer`'s chats that hold records past where `rows` say its journals end;
    /// None when it could not be read (the queue full, the store's thread gone, no answer within
    /// [`ANSWER_WITHIN`]): that is "maybe ahead", never "none".
    fn ahead(&self, peer: &str, rows: Vec<Row>) -> Option<Vec<Ahead>> {
        #[cfg(debug_assertions)]
        if test_unknown(peer) {
            return None;
        }
        // No copies kept (no directory for them), or no journal of the peer to compare: none
        // can be ahead, and that is known.
        if self.dir.is_none() || rows.is_empty() {
            return Some(Vec::new());
        }
        let (tx, rx) = mpsc::sync_channel(1);
        let sent = {
            let mut dropped = self.dropped();
            self.send_unsent(&mut dropped)
                && self.reserve(OP_BYTES)
                && self.enqueue(OP_BYTES, Op::Ahead { peer: peer.to_owned(), rows, reply: tx })
        };
        if !sent {
            return None;
        }
        blocking(|| rx.recv_timeout(ANSWER_WITHIN)).ok()
    }

    fn restored(&self, (peer, mux): (&str, &str), at: (Link, u64), last: Option<u64>) {
        let key = (peer.to_owned(), mux.to_owned());
        let (link, generation) = at;
        let op = || Op::Restored { key, link, generation, last };
        self.admit(peer, OP_BYTES + mux.len() as u64, false, op);
    }

    /// Prompts to `peer`'s session `session` wait here until its link's restores are decided,
    /// and fail when the decision holds them.
    pub(crate) async fn restores_done(
        &self,
        peer: &crate::peer::Peer,
        session: &str,
    ) -> Result<(), RpcError> {
        self.restoring.wait(peer, session).await
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
        // The link this decides: the one the peer is on as its `Connected` is handled.
        let Some(link) = self
            .peer(peer)
            .filter(|p| p.generation == generation)
            .map(|p| (p.generation, p.link_epoch()))
        else {
            return;
        };
        let (hub, peer) = (self.clone(), peer.to_owned());
        tokio::spawn(async move {
            // Every step goes only on the link it started on: a task whose link was replaced
            // stops where it is, touching no copy, deciding nothing and delivering nothing again
            // (the new link's own task does all of it). An answer counts only when the link is
            // still this one once it is in.
            let on_link = || hub.peer(&peer).filter(|p| (p.generation, p.link_epoch()) == link);
            // Read again on the way while the read fails, at most [`READ_WAITS`] (15.5 s and
            // the reads' own [`ANSWER_WITHIN`]); never read is every session held.
            let mut ahead = None;
            for wait in std::iter::once(Duration::ZERO).chain(READ_WAITS) {
                tokio::time::sleep(wait).await;
                if on_link().is_none() {
                    return;
                }
                let (h, p, rows) = (hub.clone(), peer.clone(), rows.clone());
                ahead = tokio::task::spawn_blocking(move || h.peer_snapshots.ahead(&p, rows))
                    .await
                    .ok()
                    .flatten();
                if on_link().is_none() {
                    return;
                }
                if ahead.is_some() {
                    break;
                }
                tracing::warn!(
                    peer,
                    "could not read whether a copy is ahead of the peer; trying again"
                );
            }
            let Some(ahead) = ahead else {
                tracing::warn!(peer, "prompts to this peer are held until it reconnects");
                hub.peer_snapshots.restoring.decide(&peer, Decision { link, held: None });
                return;
            };
            // Whether a copy is still ahead of the peer's journal: then nothing is delivered again,
            // since a resend could take the seqs its records need.
            let mut held = HashSet::new();
            for (mux, created_at, after, records) in ahead {
                let Some(through) = records.iter().filter_map(seq_of).max() else { continue };
                let params = json!({"sessionId": mux, "createdAt": created_at,
                                    "afterSeq": after, "records": records});
                let mut done = false;
                for wait in RETRY_WAITS {
                    let Some(to) = on_link() else { return };
                    let answer = to.request("_acpmux/journal_restore", params.clone()).await;
                    if on_link().is_none() {
                        return;
                    }
                    match answer {
                        // Taken back whole: the peer's journal ends at or past the copy's last.
                        Ok(answer)
                            if answer
                                .get("lastSeq")
                                .and_then(Value::as_u64)
                                .is_some_and(|last| last >= through) =>
                        {
                            let last = answer.get("lastSeq").and_then(Value::as_u64);
                            tracing::info!(peer, session = %mux, after, ?last, "journal restored");
                            hub.peer_snapshots.restored((&peer, &mux), (link, created_at), last);
                            done = true;
                            break;
                        }
                        Err(e) if refused(&e) => {
                            tracing::info!(peer, session = %mux, "journal restore refused: {}", e.message);
                            hub.peer_snapshots.restored((&peer, &mux), (link, created_at), None);
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
                if !done {
                    held.insert(mux);
                }
            }
            // A copy not taken back whole holds its session's prompts, and every delivery to the
            // peer, until a later link decides again.
            if on_link().is_none() {
                return;
            }
            let clear = held.is_empty();
            hub.peer_snapshots.restoring.decide(&peer, Decision { link, held: Some(held) });
            if clear {
                crate::server::outbox::redeliver_open(&hub, &peer);
            }
        });
    }
}

/// Debug builds only: every read of whether a copy of `peer` is ahead fails, `n` times.
#[cfg(debug_assertions)]
static UNKNOWN: StdMutex<Option<(String, u32)>> = StdMutex::new(None);

#[cfg(debug_assertions)]
#[doc(hidden)]
pub fn reads_fail(peer: &str, n: u32) {
    *UNKNOWN.lock().unwrap_or_else(|e| e.into_inner()) = Some((peer.to_owned(), n));
}

#[cfg(debug_assertions)]
fn test_unknown(peer: &str) -> bool {
    let mut unknown = UNKNOWN.lock().unwrap_or_else(|e| e.into_inner());
    match unknown.as_mut() {
        Some((p, n)) if p == peer && *n > 0 => {
            *n -= 1;
            true
        }
        _ => false,
    }
}

/// The peer answered that its journal is another history than the copy's.
fn refused(e: &RpcError) -> bool {
    let reason = e.data.as_ref().and_then(|d| d.get("reason")).and_then(Value::as_str);
    matches!(reason, Some("generation" | "diverged"))
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
