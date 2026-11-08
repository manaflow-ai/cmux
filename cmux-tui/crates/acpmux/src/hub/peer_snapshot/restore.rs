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
//! full, its thread gone, no answer, the disk or a copy that does not read) is "maybe ahead": it is read again ([`READ_WAITS`]), and
//! past them every prompt to the peer fails visibly until it reconnects. A copy not taken back
//! holds its own session the same way. Then, with nothing held, the deliveries the peer
//! accepted and may have lost with its disk are delivered again under their own prompt ids
//! (`server/outbox.rs` `redeliver_open`); with anything held, none is.
//!
//! A restore gives back, with the copy, the records the open deliveries hold as proof of their
//! prompts (`open_delivery.rs` `proofs_past`): a bound, a queue that overflowed or the disk's
//! eviction may have cut them from the copy, never from the delivery.

use super::*;
use crate::hub::open_delivery as od;
use crate::rpc::RpcError;
use tokio::sync::Notify;

/// A peer's row: its session id, its generation, and where a copy goes back from: its journal's
/// `lastSeq`, or its `recoveredAfter` when that is lower (`Hub::journal_ends`).
pub(crate) type Row = (String, u64, u64);
/// A copy ahead of its peer: the session id, its generation, where its row says it goes back
/// from (the restore's `afterSeq`), and the records past it.
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

    /// The decision of `peer`'s link `link`, if made.
    fn decision_on(&self, peer: &str, link: Link) -> Option<Decision> {
        let decided = self.decided.lock().unwrap_or_else(|e| e.into_inner());
        decided.get(peer).filter(|d| d.link >= link).cloned()
    }

    /// Waits until `peer`'s current link has its restore decision, while the link is up, at most
    /// [`GATE_WITHIN`]; then a prompt to `session` goes unless the decision holds it. A link that
    /// is down waits for nothing: the request is refused as unreachable as before.
    pub(crate) async fn wait(
        &self,
        peer: &crate::peer::Peer,
        session: &str,
    ) -> Result<Option<Link>, RpcError> {
        let deadline = tokio::time::Instant::now() + GATE_WITHIN;
        loop {
            let done = self.done.notified();
            tokio::pin!(done);
            done.as_mut().enable();
            if !peer.ready() {
                return Ok(None);
            }
            // Read once: the link checked is the one the decision is of.
            let link = (peer.generation, peer.link_epoch());
            if let Some(d) = self.decision_on(&peer.name, link) {
                return match d.held {
                    Some(held) if !held.contains(session) => Ok(Some(link)),
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
    /// [`ANSWER_WITHIN`], the disk or a copy that does not read: `Store::ahead`): that is "maybe
    /// ahead", never "none".
    fn ahead(&self, peer: &str, rows: Vec<Row>) -> Option<(Vec<Ahead>, od::Since)> {
        #[cfg(debug_assertions)]
        if test_unknown(peer) {
            return None;
        }
        // No copies kept (no directory for them), or no journal of the peer to compare: none
        // can be ahead, and that is known.
        if self.dir.is_none() || rows.is_empty() {
            return Some(Default::default());
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
        blocking(|| rx.recv_timeout(ANSWER_WITHIN)).ok().flatten()
    }

    fn restored(&self, (peer, mux): (&str, &str), at: (Link, u64), last: Option<u64>) {
        let key = (peer.to_owned(), mux.to_owned());
        let (link, generation) = at;
        let op = || Op::Restored { key, link, generation, last };
        self.admit(peer, OP_BYTES + mux.len() as u64, false, op);
    }

    /// Prompts to `peer`'s session `session` wait here until its link's restores are decided,
    /// and fail when the decision holds them. Answers the link (instance and epoch) whose
    /// decision let it go (review of #37284 at 4dcbe192, F2): the prompt goes on that link
    /// only. None: the link is down, and the request is refused as unreachable.
    pub(crate) async fn restores_done(
        &self,
        peer: &crate::peer::Peer,
        session: &str,
    ) -> Result<Option<Link>, RpcError> {
        self.restoring.wait(peer, session).await
    }
}

impl Store {
    /// Whether copy `c` stays over `page`, a page of a peer behind it: the peer said where its
    /// journal ends, and the copy holds records past it, which the peer can take back.
    pub(super) fn keeps_ahead(c: &Kept, page: &Page) -> bool {
        // A copy that starts past where the peer's journal ends stays too: the records between
        // are gone everywhere, and its own are only here (review of #37284, the move
        // simulation): they go back with that gap, never dropped.
        page.seen().is_some_and(|s| s < c.head.last_seq)
    }

    /// The copies of `peer`'s sessions past where `rows` say its journals end, with where each
    /// copy's open deliveries' proofs begin; None while that is not known (review of #37284 at
    /// 8b5f3063, F1): the disk is not read yet and does not read now (what an earlier run kept
    /// there is not in `copies`), or a copy ahead did not read. 8b5f3063 answered both as no
    /// copy ahead, and the gate let prompts take the seqs of the newer history on disk.
    pub(super) fn ahead(&mut self, peer: &str, rows: Vec<Row>) -> Option<(Vec<Ahead>, od::Since)> {
        if !self.scanned && !self.scan() && !crate::hub::journal_restore::rules_of_8b5f() {
            return None;
        }
        let mut out = Vec::new();
        let mut since = od::Since::new();
        for (mux, generation, last) in rows {
            let key = (peer.to_owned(), mux);
            if let Some(c) = self.copies.get(&key).filter(|c| c.head.generation == Some(generation))
            {
                since.insert(key.1.clone(), (generation, c.head.since));
            }
            // Past where the peer's journal ends, with a gap or not (`keeps_ahead`).
            let ahead = |c: &Kept| c.head.generation == Some(generation) && last < c.head.last_seq;
            if !self.copies.get(&key).is_some_and(ahead) {
                continue;
            }
            match self.read_in(&key, true) {
                Loaded::Yes => {}
                Loaded::Gone => continue,
                Loaded::Unread => return None,
            }
            let Some(records) = self.copies.get(&key).and_then(|c| c.records.as_ref()) else {
                continue;
            };
            let past: Vec<Value> = records.range(last + 1..).map(|(_, r)| r.clone()).collect();
            // One past what one restore takes too: it stays held (`with_proofs`).
            if !past.is_empty() {
                out.push((key.1, generation, last, past));
            }
        }
        Some((out, since))
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
        let (rows, lasts) = self.journal_ends(peer);
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
            let Some((ahead, since)) = ahead else {
                tracing::warn!(peer, "prompts to this peer are held until it reconnects");
                hub.peer_snapshots.restoring.decide(&peer, Decision { link, held: None });
                return;
            };
            // What the open deliveries hold as proof goes back with the copy.
            let proofs = od::proofs_past(&hub.outbox, &peer, &rows, &since);
            // Whether a copy is still ahead of the peer's journal: then nothing is delivered again,
            // since a resend could take the seqs its records need. One past what a restore
            // takes is held from the start.
            let (ahead, mut held) = with_proofs(ahead, proofs, &rows);
            // Where each journal ends once this link's restores ran (`redeliver_open`): its
            // `lastSeq`, not where its recovery began, so a proof the restore did not give back
            // is read against what the journal holds there, as before.
            let mut ends = lasts;
            for (mux, created_at, mut after, records) in ahead {
                let Some(mut through) = records.iter().filter_map(seq_of).max() else { continue };
                let files = restore_files(&hub.outbox, (&peer, &mux, created_at));
                let mut params = json!({"sessionId": mux, "createdAt": created_at,
                                    "afterSeq": after, "records": records, "files": files});
                let mut done = false;
                let mut waits: std::collections::VecDeque<Duration> = RETRY_WAITS.into();
                while let Some(wait) = waits.pop_front() {
                    let Some(to) = on_link() else { return };
                    // On this link's epoch only (review of #37284 at 98b4575a, F1): a link
                    // replaced since the check never carries it to the next machine.
                    let answer = to
                        .request_on("_acpmux/journal_restore", params.clone(), Some(link.1))
                        .await;
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
                            if let Some(last) = last {
                                ends.insert(mux.clone(), (created_at, last));
                            }
                            done = true;
                            break;
                        }
                        // Its journal ends with its own recovery, from `afterSeq` on (review of
                        // #37284 at 4dcbe192, F1): the copy goes back from there, once.
                        Err(e) if recovered(&e).is_some_and(|a| a < after) => {
                            let from = recovered(&e).unwrap_or(after);
                            let row = vec![(mux.clone(), created_at, from)];
                            let (h, p, r) = (hub.clone(), peer.clone(), row.clone());
                            let read =
                                tokio::task::spawn_blocking(move || h.peer_snapshots.ahead(&p, r));
                            let Some((ahead, since)) = read.await.ok().flatten() else { break };
                            let proofs = od::proofs_past(&hub.outbox, &peer, &row, &since);
                            let (ahead, over) = with_proofs(ahead, proofs, &row);
                            let Some((.., records)) = ahead.into_iter().find(|a| a.0 == mux) else {
                                held.extend(over);
                                break;
                            };
                            tracing::info!(peer, session = %mux, from, "the peer's journal ends with its own recovery; the copy goes back from where it began");
                            through = records.iter().filter_map(seq_of).max().unwrap_or(through);
                            after = from;
                            params = json!({"sessionId": mux, "createdAt": created_at,
                                            "afterSeq": after, "records": records, "files": files});
                            // Sent again at once, as the same try.
                            waits.push_front(wait);
                            continue;
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
                crate::server::outbox::redeliver_open(&hub, &peer, link, ends);
            }
        });
    }
}

/// `ahead` with the proofs' records (`od::proofs_past`) of each session merged in, by seq: a
/// session whose copy is not ahead (or went) restores from them alone, after its row's
/// `lastSeq`. Each proof goes whole or not at all: one with a record at a seq where the copy
/// (or a proof merged before it) holds another record is of another history than the copy, and
/// giving back the rest of it would bring back a prompt without its end (the move simulation,
/// round 9); it stays open, and its machine's journal settles it (`od::step`). A session with
/// more than one restore takes ([`MAX_RECORDS`]) is not restored and comes back held (review
/// of #37284 at 91b1343d, F5): its prompts stay held and its open deliveries open, until they
/// lapse, failing visibly; it is never dropped as clear.
///
/// [`MAX_RECORDS`]: crate::hub::journal_restore::MAX_RECORDS
pub(crate) fn with_proofs(
    mut ahead: Vec<Ahead>,
    proofs: HashMap<String, Vec<Vec<Value>>>,
    rows: &[Row],
) -> (Vec<Ahead>, HashSet<String>) {
    for (session, proofs) in proofs {
        let mut by_seq: BTreeMap<u64, Value> = BTreeMap::new();
        let at = ahead.iter().position(|(s, ..)| *s == session);
        if let Some((.., copy)) = at.and_then(|i| ahead.get_mut(i)) {
            by_seq.extend(copy.drain(..).filter_map(|r| Some((seq_of(&r)?, r))));
        }
        for records in proofs {
            let fits = records.iter().all(|r| {
                seq_of(r).is_some_and(|s| {
                    by_seq.get(&s).is_none_or(|held| od::same_record(r, Some(held)))
                })
            });
            if !fits {
                tracing::warn!(
                    session,
                    "a proof is of another history than the copy; it is not given back"
                );
                continue;
            }
            for r in records {
                if let Some(s) = seq_of(&r) {
                    by_seq.entry(s).or_insert(r);
                }
            }
        }
        if by_seq.is_empty() {
            continue;
        }
        let records: Vec<Value> = by_seq.into_values().collect();
        match at.and_then(|i| ahead.get_mut(i)) {
            Some((.., copy)) => *copy = records,
            None => {
                if let Some((_, generation, last)) = rows.iter().find(|(s, ..)| *s == session) {
                    ahead.push((session, *generation, *last, records));
                }
            }
        }
    }
    let mut held = HashSet::new();
    ahead.retain(|(session, .., records)| {
        let over = records.len() > crate::hub::journal_restore::MAX_RECORDS;
        if over && !crate::hub::journal_restore::rules_of_91b() {
            tracing::warn!(
                session,
                records = records.len(),
                "a copy holds more than one restore takes; its session stays held"
            );
            held.insert(session.clone());
        }
        !over
    });
    (ahead, held)
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
/// The files the open deliveries pinned to `pinned` (peer, session, generation) saved their
/// prompts as on the machine (`od::proof_files`): a restore writes them back before its records
/// (review of #37284 at 4dcbe192, F4).
pub(crate) fn restore_files(
    outbox: &crate::hub::outbox::Outbox,
    pinned: (&str, &str, u64),
) -> Vec<Value> {
    use base64::Engine as _;
    let mut files: BTreeMap<std::path::PathBuf, Vec<u8>> = BTreeMap::new();
    // And their images, by id, which the machine keeps where it keeps a prompt's images
    // (review of #37284 at a088585e, F2).
    let mut images: BTreeMap<String, Vec<u8>> = BTreeMap::new();
    for d in outbox.pinned_to(pinned) {
        files.extend(od::proof_files(&d));
        if !crate::hub::journal_restore::rules_of_a088() {
            images.extend(od::proof_images(&d));
        }
    }
    let data = |bytes: Vec<u8>| base64::engine::general_purpose::STANDARD.encode(bytes);
    let files = files.into_iter().map(|(path, bytes)| json!({"path": path, "data": data(bytes)}));
    let images = images.into_iter().map(|(id, bytes)| json!({"image": id, "data": data(bytes)}));
    files.chain(images).collect()
}

/// Where the peer's journal's own recovery begins, when it refused a restore past it.
fn recovered(e: &RpcError) -> Option<u64> {
    let data = e.data.as_ref()?;
    (data.get("reason")?.as_str()? == "recovered").then(|| data.get("afterSeq")?.as_u64())?
}

fn refused(e: &RpcError) -> bool {
    let reason = e.data.as_ref().and_then(|d| d.get("reason")).and_then(Value::as_str);
    matches!(reason, Some("generation" | "diverged"))
}

impl Hub {
    /// Each listed session of `peer`: its id, its generation and where a copy goes back from
    /// ([`Row`]); and where each journal ends (session: generation, `lastSeq`).
    ///
    /// A journal that ends with what the peer's own recovery wrote after a restart names where
    /// that began (`recoveredAfter`, `hub/journal_restore.rs`): the copy goes back from there,
    /// however far the recovery went (review of #37284 at 8b5f3063, F2). 8b5f3063 compared the
    /// copy with `lastSeq` alone: a recovery that wrote as many records as the copy held past
    /// where it began hid the copy, and the turn's own end was lost to its unknown outcome. The
    /// copy (and the proofs) past that point go back as any copy ahead does (`Store::ahead`,
    /// `od::proofs_past`); one that ends at or before it has nothing to give back.
    fn journal_ends(&self, peer: &str) -> (Vec<Row>, HashMap<String, (u64, u64)>) {
        let old = self.at_8b5f();
        let map = self.remote_sessions.lock().unwrap_or_else(|e| e.into_inner());
        let mut rows = Vec::new();
        let mut lasts = HashMap::new();
        for (_, r) in map.of_peer(peer) {
            let mux = &r.receipt.mux_session_id;
            let Some((row, last)) = row_of(mux, &r.summary, old) else { continue };
            lasts.insert(mux.clone(), (row.1, last));
            rows.push(row);
        }
        (rows, lasts)
    }
}

/// Session `mux`'s [`Row`] from its listed `summary`, and its journal's `lastSeq`; None when the
/// summary names no generation or end. `old`: 8b5f3063's rules, by `lastSeq` alone.
pub(crate) fn row_of(mux: &str, summary: &Value, old: bool) -> Option<(Row, u64)> {
    let u64_of = |key: &str| summary.get(key).and_then(Value::as_u64);
    let (created, last) = (u64_of("createdAt")?, u64_of("lastSeq")?);
    let from = u64_of("recoveredAfter").filter(|_| !old).map_or(last, |f| f.min(last));
    Some(((mux.to_owned(), created, from), last))
}
