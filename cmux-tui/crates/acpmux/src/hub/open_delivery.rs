//! Part of `Hub`; see `hub/mod.rs`. A message a peer's session took, from its acceptance until
//! nothing can lose it (review of #37284, sixth and seventh rounds: "make the copy the only
//! proof", "protect, don't reopen").
//!
//! - Pinned: the attempt reads the peer's session (its id, its generation `createdAt`, the link)
//!   before it starts ([`pin`]) and names that generation in the request ([`name_generation`]);
//!   the answer is recorded against that pin and nothing read after it ([`accepted`]). A session
//!   purged and made again under the same id refuses it as stale.
//! - Open: an accepted message to a peer's session stays open (`Delivery::open_on_peer`): the
//!   machine may lose it with its disk (a VM back on an older snapshot, a session moved to a
//!   fresh machine). "Accepted" and "duplicate" only say the peer saw it; neither survives a
//!   restart from an older disk.
//! - Proven: once the owner's copy of the pinned session and generation wrote records of the
//!   message's prompt to disk (`peer_snapshot.rs` reports what each write held, never a record
//!   a bound cut before it), the delivery holds them itself ([`take_proof`]: every record of the
//!   prompt's life, queued, edited, started, ended or taken off the queue). The copy's bounds,
//!   a queue that overflows and the disk's eviction cannot drop them there. A proven delivery is
//!   never sent again: a link whose machine ends before them gives them back with the copy
//!   (`peer_snapshot/restore.rs`, [`proofs_past`]), unless the copy did not see the prompt's
//!   whole life since its first record and giving it back would start its work again
//!   ([`whole`]): then nothing goes back, nothing runs again, and it stays open.
//! - Released ([`step`]): when a later link than the one its proof came on lists the session,
//!   of its generation, with a journal that ends past the proof and holds each of its records
//!   (read on that link, by seq, time and kind: [`Hub::proof_held`]); or it fails, saying why:
//!   another history where its records were (a machine that wrote others there before its
//!   restore), another generation of the session (stale), or open past
//!   `outbox::OPEN_ON_PEER_FOR_MS` (lapsed). Never a quiet drop.
//! - Not proven yet: delivered again on every link of the peer while open, under its own prompt
//!   id and pinned generation (`server/outbox.rs` `redeliver_open`): a machine that has it
//!   answers with its first outcome and nothing runs twice; a stale or refused one fails it.
//!
//! Cost: a proven delivery holds its prompt's records (the prompt's text once more, and a few
//! small records) until the peer's next link shows them, at most 30 days: bounded by the open
//! deliveries times the size of their prompts' records.

use super::Hub;
use super::outbox::{Delivery, Outbox, Pin, Proof, State};
use serde_json::{Value, json};
use std::collections::{BTreeMap, HashMap, HashSet};

/// The peer's session `target` names, as it is now: None for a session of this daemon, or one
/// no peer lists.
pub(crate) fn pin(hub: &Hub, target: &str) -> Option<Pin> {
    if hub.resolve(target).is_ok() {
        return None;
    }
    let (peer, session, row) = hub.resolve_remote(target)?;
    let generation = row.get("createdAt").and_then(Value::as_u64)?;
    Some(Pin {
        peer: peer.name.clone(),
        session,
        generation,
        link: (peer.generation, peer.link_epoch()),
    })
}

/// Names the pinned generation in `request` (`_meta.acpmux.sessionCreatedAt`).
pub(crate) fn name_generation(request: &mut Value, pin: Option<&Pin>) {
    let Some(pin) = pin else { return };
    if let Some(mux) = request.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut) {
        mux.insert("sessionCreatedAt".into(), json!(pin.generation));
    }
}

/// An attempt that started with `pin` was accepted: delivered, and open on the peer when it
/// went to a peer's session, whatever the answer (a duplicate too).
pub(crate) fn accepted(d: &mut Delivery, pin: Option<Pin>, answer: Value) {
    d.state = State::Delivered;
    d.open_on_peer = pin.is_some();
    d.pin = pin;
    d.error = None;
    d.accepted = Some(answer);
}

/// Whether `record` is the journal record of prompt `prompt_id` that says it waits or ran (the
/// rules of 0c98c292, which the move simulation replays).
#[cfg(test)]
pub(crate) fn names_prompt(record: &Value, prompt_id: &str) -> bool {
    !prompt_id.is_empty()
        && matches!(kind(record), "queued" | "user_message")
        && prompt_of(record) == Some(prompt_id)
}

fn kind(r: &Value) -> &str {
    r.get("kind").and_then(Value::as_str).unwrap_or_default()
}

fn seq(r: &Value) -> Option<u64> {
    r.get("seq").and_then(Value::as_u64)
}

/// The prompt a journal record names (`msg.promptId`).
pub(crate) fn prompt_of(r: &Value) -> Option<&str> {
    r.pointer("/msg/promptId").and_then(Value::as_str)
}

fn turn_of(r: &Value) -> Option<&str> {
    r.pointer("/msg/turnId").and_then(Value::as_str)
}

/// Whether `record` may be of a prompt's life: it names a prompt or a turn
/// (`peer_snapshot.rs` reports only these).
pub(crate) fn of_a_prompt(record: &Value) -> bool {
    prompt_of(record).is_some() || turn_of(record).is_some()
}

/// Takes into `d`'s proof the records of its prompt's life among `records` (naming its prompt,
/// or a turn a record of its prompt names), which the owner's copy of its pinned session wrote
/// while the peer was on link `link`. Answers whether any was new.
pub(crate) fn take_proof(d: &mut Delivery, records: &[Value], link: (u64, u64)) -> bool {
    let prompt = d.prompt_id().to_owned();
    if prompt.is_empty() {
        return false;
    }
    let mut proof = d.proof.take().unwrap_or(Proof { records: Vec::new(), link });
    let mut turns: HashSet<String> =
        proof.records.iter().filter_map(turn_of).map(str::to_owned).collect();
    let mine = |r: &Value| prompt_of(r) == Some(prompt.as_str());
    turns.extend(records.iter().filter(|r| mine(r)).filter_map(turn_of).map(str::to_owned));
    let mut held: BTreeMap<u64, Value> =
        proof.records.drain(..).filter_map(|r| Some((seq(&r)?, r))).collect();
    let before = held.len();
    for r in records {
        if (mine(r) || turn_of(r).is_some_and(|t| turns.contains(t)))
            && let Some(s) = seq(r)
        {
            held.entry(s).or_insert_with(|| r.clone());
        }
    }
    let new = held.len() > before;
    proof.records = held.into_values().collect();
    if !proof.records.is_empty() {
        d.proof = Some(proof);
    }
    new
}

/// Whether a machine that holds only `records` of a prompt starts its work again once they are
/// given back (`log_load.rs` `settle_restored`): it waits in the queue with nothing after it
/// (`restore_queue` puts it back), or it left the queue or started with no end (the cut turn
/// is continued, or goes back ahead of the queue).
pub(crate) fn restarts(records: &[Value]) -> bool {
    let has = |kinds: &[&str]| records.iter().any(|r| kinds.contains(&kind(r)));
    let ended = has(&["turn_result", "queue_removed", "queue_declined", "prompt_retracted"]);
    let left = has(&["dequeued", "user_message", "turn_started"]);
    !ended && (left || has(&["queued"]))
}

/// The seq from which the owner's copy of each session saw every record, with its generation
/// (`peer_snapshot/restore.rs`).
pub(crate) type Since = HashMap<String, (u64, u64)>;

/// Whether `d`'s proof holds its prompt's life as far as a restore needs it: it ended, or the
/// copy of its session and generation saw every record since the proof's first one. A proof
/// with a gap after it (the copy was replaced past a gap, or went: a bound, a queue that
/// overflowed, the disk's eviction) may miss the records that ended it.
pub(crate) fn whole(d: &Delivery, since: &Since) -> bool {
    let (Some(pin), Some(proof)) = (&d.pin, &d.proof) else { return false };
    let first = proof.records.first().and_then(seq);
    !restarts(&proof.records)
        || since.get(&pin.session).is_some_and(|(generation, since)| {
            *generation == pin.generation && first.is_some_and(|f| *since <= f)
        })
}

/// What the open deliveries' proofs give back to `peer`'s journals that end before them, by
/// session: their records past where `rows` (session, generation, `lastSeq`) say each ends, of
/// the same generation, from proofs that are [`whole`]. A restore sends them with the copy.
pub(crate) fn proofs_past(
    outbox: &Outbox,
    peer: &str,
    rows: &[(String, u64, u64)],
    since: &Since,
) -> HashMap<String, Vec<Value>> {
    let mut out: HashMap<String, BTreeMap<u64, Value>> = HashMap::new();
    for d in outbox.open_on_peers() {
        let (Some(pin), Some(proof)) = (&d.pin, &d.proof) else { continue };
        let row = rows.iter().find(|(s, g, _)| *s == pin.session && *g == pin.generation);
        let Some((_, _, last)) = row else { continue };
        if pin.peer != peer || !whole(&d, since) {
            continue;
        }
        let past =
            proof.records.iter().filter_map(|r| Some((seq(r)?, r))).filter(|(s, _)| s > last);
        let into = out.entry(pin.session.clone()).or_default();
        for (s, r) in past {
            into.entry(s).or_insert_with(|| r.clone());
        }
    }
    out.into_iter().map(|(s, r)| (s, r.into_values().collect())).collect()
}

/// What a link's redelivery does with an open delivery ([`step`]).
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Step {
    /// Open past its bound: it fails, saying so.
    Lapse,
    /// Its machine's journal ends past its proof on a later link: read whether that journal
    /// holds the proof's records ([`held`], then [`checked`]).
    Check,
    /// Its machine holds its proof on a later link: closed, delivered.
    Release,
    /// Its machine's journal holds another history where its proof was: it fails, saying so.
    Lost,
    /// Its session is another generation there: it fails as stale.
    Stale,
    /// Proven, and not seen held yet: it stays open, and is not sent again.
    Wait,
    /// Not proven: delivered again.
    Again,
}

/// What the redelivery on link `link` does with open delivery `d` at `now`, its peer's journals
/// ending at `ends` (session: generation, `lastSeq`) once that link's restores ran.
pub(crate) fn step(
    d: &Delivery,
    now: u64,
    link: (u64, u64),
    ends: &HashMap<String, (u64, u64)>,
) -> Step {
    if d.open_lapsed(now) {
        return Step::Lapse;
    }
    let (Some(pin), Some(proof)) = (&d.pin, &d.proof) else { return Step::Again };
    let through = proof.records.iter().filter_map(seq).max();
    match ends.get(&pin.session) {
        Some((generation, _)) if *generation != pin.generation => Step::Stale,
        Some((_, last)) if link > proof.link && through.is_some_and(|t| t <= *last) => Step::Check,
        _ => Step::Wait,
    }
}

/// What a [`Step::Check`] found: every record of the proof held (by seq, time and kind, as
/// `journal_restore` compares them), another history there, or nothing read (it waits).
pub(crate) fn checked(held: Option<bool>) -> Step {
    match held {
        Some(true) => Step::Release,
        Some(false) => Step::Lost,
        None => Step::Wait,
    }
}

/// Whether `found`, the machine's record at the seq of `record` (None: it has none), is that
/// record.
pub(crate) fn same_record(record: &Value, found: Option<&Value>) -> bool {
    found.is_some_and(|f| {
        seq(f) == seq(record) && f.get("at") == record.get("at") && kind(f) == kind(record)
    })
}

/// The error of a proven delivery whose machine holds another history where its records were.
pub(crate) const LOST: &str = "the peer took this message, but its machine came back on an \
     older disk and wrote other records where it was; it may have run, and is not run again";

/// The error of a proven delivery whose session is another generation on its machine now.
pub(crate) const STALE: &str = "the peer took this message, but its session there was purged \
     and made again since; it is not sent to the new one";

/// Closes `d`, proven and held by its machine: delivered, and its proof goes.
pub(crate) fn release(d: &mut Delivery) {
    d.open_on_peer = false;
    d.proof = None;
}

/// What a delivery again was answered.
pub(crate) enum Again {
    /// Taken (run now, or answered with its first outcome).
    Taken(Value),
    /// Refused for good: the session is gone there, or is another generation of it.
    Refused(String),
    /// Not answered (the link, a timeout): tried on the next link.
    Unknown,
}

/// A delivery again of open `d` was answered `again`: it stays open (only its proof, seen held
/// on a later link, closes it), or fails, saying why. Answers whether it settled.
pub(crate) fn after_again(d: &mut Delivery, again: Again) -> bool {
    match again {
        Again::Taken(answer) => {
            d.accepted = Some(answer);
            false
        }
        Again::Refused(error) => {
            d.fail_open(error);
            true
        }
        Again::Unknown => false,
    }
}

impl Hub {
    /// Whether peer `pin.peer`'s journal of `pin.session`, read on link `link`, holds every
    /// record of `proof` ([`same_record`]); None when it could not be read on that link.
    pub(crate) async fn proof_held(
        &self,
        pin: &Pin,
        link: (u64, u64),
        proof: &Proof,
    ) -> Option<bool> {
        let peer = self.peer(&pin.peer).filter(|p| (p.generation, p.link_epoch()) == link)?;
        for record in &proof.records {
            let at = seq(record)?;
            let params = json!({"sessionId": pin.session, "afterSeq": at - 1, "limit": 1});
            let page =
                peer.request_on(crate::rpc::method::MUX_EVENTS, params, Some(link.1)).await.ok()?;
            let events = page.get("events").and_then(Value::as_array)?;
            if !same_record(record, events.first()) {
                return Some(false);
            }
        }
        Some(true)
    }

    /// Whether peer `peer` is on link `link` (its instance and link epoch) still.
    pub(crate) fn peer_on_link(&self, peer: &str, link: (u64, u64)) -> bool {
        self.peer(peer).is_some_and(|p| (p.generation, p.link_epoch()) == link)
    }

    /// The owner's copy of peer `peer`'s session `session`, generation `generation`, wrote
    /// `records` to disk, which came on link `link` (review of #37284 at 98b4575a, F4: the
    /// write's own link, never the one the peer is on when the write runs): the deliveries
    /// pinned to it take their prompts' records as proof. Called on the copies' thread after the
    /// write (`peer_snapshot.rs`); blocks only on the outbox's own write.
    pub(crate) fn proof_written(
        &self,
        peer: &str,
        session: &str,
        (generation, link): (u64, (u64, u64)),
        records: &[Value],
    ) {
        for path in take_written(&self.outbox, (peer, session, generation), records, link) {
            let _ = std::fs::remove_file(path);
        }
    }
}

/// [`Hub::proof_written`] on `outbox`: each delivery pinned to `pinned` takes the records of its
/// prompt among `records` as proof; answers the attachment files they kept, to remove (a proven
/// delivery is never sent again).
pub(crate) fn take_written(
    outbox: &Outbox,
    pinned: (&str, &str, u64),
    records: &[Value],
    link: (u64, u64),
) -> Vec<std::path::PathBuf> {
    let prompts: HashSet<&str> = records.iter().filter_map(prompt_of).collect();
    let mut files = Vec::new();
    for d in outbox.pinned_to(pinned) {
        if d.proof.is_none() && !prompts.contains(d.prompt_id()) {
            continue;
        }
        if !take_proof(&mut d.clone(), records, link) {
            continue;
        }
        files.extend(outbox.attachments_path(&d));
        outbox.update(&d.id, |d| {
            take_proof(d, records, link);
            crate::attach::strip(&mut d.request);
        });
    }
    files
}
