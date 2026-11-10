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
//! - Not proven yet, or proven only by records no machine could run it again from (a
//!   `user_message` with an attachment's hidden context, waiting in no queue, started or not:
//!   [`rerunnable`]): delivered again on every link of the peer while open, under its own prompt
//!   id, to its pinned session and generation ([`again_request`], `server/outbox.rs`
//!   `redeliver_open`): a machine that has it answers with its first outcome and nothing runs
//!   twice; a stale or refused one fails it. A cut turn of an attachment prompt a restore gave
//!   back is settled for that resend to run it whole ([`RERUN_ON_RESEND`]).
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

/// The request a delivery again of `d` sends: its own, as a resend of its prompt id, addressed
/// to the session it was pinned to (`pin.peer`/`pin.session`) in the pinned generation (review
/// of #37284 at 4bce04df, F2). A delivery first addressed by a name (`peer/name`) would resolve
/// that name again, and a session renamed meanwhile (its name maybe another session's now) was
/// refused as stale for good, though the pinned session still held it; 4bce04df kept the
/// address it was sent to.
pub(crate) fn again_request(d: &Delivery, pin: &Pin) -> Value {
    let mut request = d.request.clone();
    if let Some(mux) = request.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut) {
        mux.insert("resend".into(), json!(true));
    }
    if !crate::hub::journal_restore::rules_of_4bce()
        && let Some(fields) = request.as_object_mut()
    {
        fields.insert("sessionId".into(), json!(format!("{}/{}", pin.peer, pin.session)));
    }
    name_generation(&mut request, Some(pin));
    request
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
    prompt_of(record).is_some()
        || turn_of(record).is_some()
        || (queue_wide(record) && !crate::hub::journal_restore::rules_of_4dcb())
}

/// Whether `record` changes the whole queue's state (a Stop's hold, a resume, an order): it
/// affects the prompts its list names (`held`, `promptIds`, `order`), or every one when it names
/// none (review of #37284 at 4dcbe192, F5: a Stop's `queue_paused` names what it held).
fn queue_wide(record: &Value) -> bool {
    matches!(kind(record), "queue_paused" | "queue_resumed" | "queue_order")
}

/// Whether queue-wide `record` ([`queue_wide`]) affects prompt `prompt`.
fn affects(record: &Value, prompt: &str) -> bool {
    if !queue_wide(record) || crate::hub::journal_restore::rules_of_4dcb() {
        return false;
    }
    let lists: Vec<&Vec<Value>> = ["held", "promptIds", "order"]
        .iter()
        .filter_map(|k| record.pointer(&format!("/msg/{k}")).and_then(Value::as_array))
        .collect();
    lists.is_empty() || lists.iter().any(|l| l.iter().any(|v| v.as_str() == Some(prompt)))
}

/// Takes into `d`'s proof the records of its prompt's life among `records` (naming its prompt,
/// or a turn a record of its prompt names), which the owner's copy of its pinned session wrote
/// while the peer was on link `link`. Answers whether any was new.
pub(crate) fn take_proof(d: &mut Delivery, records: &[Value], link: (u64, u64)) -> bool {
    let prompt = d.prompt_id().to_owned();
    if prompt.is_empty() {
        return false;
    }
    let mut proof = d.proof.take().unwrap_or_else(|| Proof {
        records: Vec::new(),
        link,
        incarnation: incarnation(),
    });
    let mut turns: HashSet<String> =
        proof.records.iter().filter_map(turn_of).map(str::to_owned).collect();
    let mine = |r: &Value| prompt_of(r) == Some(prompt.as_str());
    turns.extend(records.iter().filter(|r| mine(r)).filter_map(turn_of).map(str::to_owned));
    let mut held: BTreeMap<u64, Value> =
        proof.records.drain(..).filter_map(|r| Some((seq(&r)?, r))).collect();
    let before = held.len();
    for r in records {
        if (mine(r) || turn_of(r).is_some_and(|t| turns.contains(t)) || affects(r, &prompt))
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

/// Whether a machine that holds `records` of a prompt's life, and nothing else of it but the
/// bytes of `images` (the images the delivery can give back, by id), runs it again whole or knows
/// how it ended. It ended; or every image its records name is among `images` (a restore writes
/// them back, [`proof_images`]) and: it waits in the queue still, and its `queued` record holds
/// its blocks (`restore_queue` puts it back, its files too: [`proof_files`]); or its
/// `user_message` holds the rest of what the agent got (no hidden context, no inbox digest, no
/// part kept apart but an image) and its turn started (a cut turn is continued with its text and
/// images, `restart_resume.rs`) or not (`unstarted_prompt.rs` puts it back). A started turn's
/// continuation never carries a hidden context (an attachment's text, never logged), so that one
/// waits for its end, or for the resend a restore settled it for. Anything less
/// and a machine on another disk would run less than was sent, or nothing (review of #37284 at
/// 07f76930, F2, and at a088585e, F2: an image prompt started at once came back without its
/// images). Only a delivery again (`resend`), which carries the whole prompt, runs that one.
pub(crate) fn rerunnable(records: &[Value], images: &HashSet<String>) -> bool {
    if ended(records) {
        return true;
    }
    let has = |kinds: &[&str]| records.iter().any(|r| kinds.contains(&kind(r)));
    if !named_images(records).iter().all(|id| images.contains(*id)) {
        return false;
    }
    // A cut turn a restore settled for a resend to run whole ([`RERUN_ON_RESEND`]) is run again
    // only by that resend, whatever records of it came before. Only a prompt still waiting in
    // the queue (`queued`, and no record after it says its turn started) is put back whole from
    // its `queued` record: one that started from the queue and was cut is continued with its
    // text alone, never its attachment (review of #37284 at fd33a65b, F1). fd33a65b took any
    // `queued` record as enough, so a queued attachment prompt cut mid-turn was released and
    // never ran again.
    if crate::hub::journal_restore::rules_of_fd33() {
        if has(&["queued"]) {
            return true;
        }
    } else if records.iter().any(reruns_on_resend) {
        return false;
    } else if still_waiting(records) {
        return true;
    }
    let mut messages = records.iter().filter(|r| kind(r) == "user_message").peekable();
    messages.peek().is_some()
        && messages.all(|r| {
            let Some(msg) = r.get("msg") else { return false };
            let provenance = msg.pointer("/_meta/provenance/kind").and_then(Value::as_str);
            let apart = msg.get("inlineParts").and_then(Value::as_array).is_some_and(|parts| {
                parts.iter().any(|p| {
                    p.get("text").is_none()
                        && p.get("kind").and_then(Value::as_str) != Some("image")
                })
            });
            msg.get("hiddenContext").is_none()
                && provenance != Some(crate::hub::digest::DIGEST_KIND)
                && !apart
        })
}

/// Whether `records` of a prompt's life (in journal order) show it waiting in the queue still:
/// a `queued` record with nothing after it that says its turn started (`user_message`,
/// `turn_started`). Such a prompt is put back whole from its `queued` record (`restore_queue`,
/// its files too); a started one is not (review of #37284 at fd33a65b, F1).
fn still_waiting(records: &[Value]) -> bool {
    let Some(last) = records.iter().rposition(|r| kind(r) == "queued") else { return false };
    let left = ["user_message", "turn_started"];
    !records[last + 1..].iter().any(|r| left.contains(&kind(r)))
}

/// Whether `records` of a prompt's life show how it ended. A cut turn a restore settled for a
/// resend to run whole ([`RERUN_ON_RESEND`]) did not end: its prompt runs once the resend comes
/// (review of #37284 at 4bce04df, F1).
fn ended(records: &[Value]) -> bool {
    let ends = ["turn_result", "queue_removed", "queue_declined", "prompt_retracted"];
    let old = crate::hub::journal_restore::rules_of_4bce();
    records.iter().any(|r| ends.contains(&kind(r)) && (old || !reruns_on_resend(r)))
}

/// The field of the `turn_result` a restore writes for a cut turn whose prompt carried a hidden
/// context (an attachment's text, never logged, so no continuation can carry it): the turn is
/// settled with no continuation, and a resend of its prompt id runs the prompt again whole
/// (`log_load.rs` `mark_unknown_outcome`, `prompt_ledger.rs` `logged_prompt`; review of #37284
/// at 4bce04df, F1).
pub(crate) const RERUN_ON_RESEND: &str = "rerunOnResend";

/// Whether `record` is a `turn_result` marked [`RERUN_ON_RESEND`].
pub(crate) fn reruns_on_resend(record: &Value) -> bool {
    kind(record) == "turn_result"
        && record.pointer(&format!("/msg/{RERUN_ON_RESEND}")) == Some(&Value::Bool(true))
}

/// a088585e's [`rerunnable`]: a started turn, or a `user_message` without a hidden context, a
/// digest's provenance or an image, was enough.
fn rerunnable_at_a088(records: &[Value]) -> bool {
    let has = |kinds: &[&str]| records.iter().any(|r| kinds.contains(&kind(r)));
    if has(&["turn_result", "queue_removed", "queue_declined", "prompt_retracted"])
        || has(&["queued", "turn_started"])
    {
        return true;
    }
    records.iter().filter(|r| kind(r) == "user_message").any(|r| {
        let Some(msg) = r.get("msg") else { return false };
        let images = msg.get("images").and_then(Value::as_array).is_some_and(|i| !i.is_empty());
        msg.get("hiddenContext").is_none() && !images
    })
}

/// The ids of the images the records of a prompt's life name (`user_message`, `queued`,
/// `queue_updated`: `prompt_images.rs`).
fn named_images(records: &[Value]) -> std::collections::BTreeSet<&str> {
    records
        .iter()
        .filter(|r| matches!(kind(r), "user_message" | "queued" | "queue_updated"))
        .filter_map(|r| r.get("msg"))
        .flat_map(crate::hub::prompt_images::named_ids)
        .collect()
}

/// What one block of a prompt is to a machine that runs the prompt again (review of #37284 at
/// 77f91e5a, F1): the one place each kind of block is named. Every path that keeps, gives back
/// or checks what a prompt holds besides its records reads it: [`proof_needs`] (the files and
/// images a restore writes back, `peer_snapshot/restore.rs`; the uploads only the machine
/// holds; what `_acpmux/attachments_held` is asked, [`held_ask`]), [`kept_apart`] (what the
/// outbox keeps beside its book) and [`step`] (a block named here as none of the others is
/// delivered again whole). Reads no bytes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Part {
    /// What the records carry themselves: text (a hidden context too), a link to a URL or a
    /// file, a resource's text.
    Carried,
    /// An inline image with no attachment mark: the machine keeps it by id, and the owner's
    /// request holds its bytes.
    Image,
    /// An inline attachment (`attach::block`): `attach::receive` saves it on the machine, a file
    /// the `queued` record links to or an image kept by id, and the owner's request holds its
    /// bytes.
    Attachment,
    /// An upload of the chat's own, named by reference or resolved from one
    /// (`prompt_uploads.rs`): its bytes are only on the machine, which must hold it still.
    Upload,
    /// Anything else: nothing here says what a machine needs of it, so a prompt with one is not
    /// proven by its records alone and is delivered again whole.
    Unknown,
}

/// What `block` is to a machine that runs its prompt again ([`Part`]).
pub(crate) fn part(block: &Value) -> Part {
    if crate::attach::any(std::slice::from_ref(block)) {
        return Part::Attachment;
    }
    match crate::prompt_uploads::named_upload(block) {
        Some(Some(_)) => return Part::Upload,
        Some(None) => return Part::Unknown,
        None => {}
    }
    match block.get("type").and_then(Value::as_str) {
        Some("text" | "resource_link") => Part::Carried,
        Some("image") if block.get("data").is_some_and(Value::is_string) => Part::Image,
        Some("resource") if block.pointer("/resource/text").is_some_and(Value::is_string) => {
            Part::Carried
        }
        _ => Part::Unknown,
    }
}

/// Whether the outbox keeps `blocks`' bytes beside its book (`outbox.rs` `keep_attachments`):
/// some are inline attachments ([`Part::Attachment`]).
pub(crate) fn kept_apart(blocks: &[Value]) -> bool {
    blocks.iter().any(|b| part(b) == Part::Attachment)
}

/// What a machine needs, besides a proof's records, to run `d`'s prompt again ([`proof_needs`]).
#[derive(Debug, Default, PartialEq)]
pub(crate) struct Needs {
    /// The files its prompt was saved as on its machine (the `queued` record's links to its
    /// inline attachments), and their bytes: a restore writes them back.
    pub(crate) files: Vec<(std::path::PathBuf, Vec<u8>)>,
    /// The images its records name whose bytes the request holds, by id: a restore writes them
    /// back where the machine keeps a prompt's images.
    pub(crate) images: Vec<(String, Vec<u8>)>,
    /// The uploads it names (id, file name), which only the machine holds: none goes back, so
    /// the delivery goes only once the machine shows it holds each one.
    pub(crate) uploads: Vec<(String, String)>,
    /// A block [`part`] names as no other kind.
    pub(crate) unknown: bool,
}

/// What `d`'s prompt needs, besides its proof's records, for a machine to run it again: each
/// of its blocks, by [`part`], none passed over. An ended prompt needs no upload any more.
pub(crate) fn proof_needs(d: &Delivery) -> Needs {
    let mut needs = Needs::default();
    let Some(proof) = &d.proof else { return needs };
    let Some(blocks) = d.request.get("prompt").and_then(Value::as_array) else { return needs };
    let saved: HashMap<usize, String> = crate::attach::saved_names(blocks).into_iter().collect();
    let named = named_images(&proof.records);
    let links: Vec<(std::path::PathBuf, String)> = proof
        .records
        .iter()
        .filter(|r| kind(r) == "queued")
        .filter_map(|r| r.pointer("/msg/prompt").and_then(Value::as_array))
        .flat_map(|b| crate::attach::saved_links(b))
        .collect();
    let mut images: BTreeMap<String, Vec<u8>> = BTreeMap::new();
    for (index, block) in blocks.iter().enumerate() {
        let one = std::slice::from_ref(block);
        match part(block) {
            Part::Carried => {}
            kind @ (Part::Image | Part::Attachment) => {
                for (id, bytes) in crate::hub::prompt_images::image_bytes(one) {
                    if named.contains(id.as_str()) {
                        images.insert(id, bytes);
                    }
                }
                let name = saved.get(&index).filter(|_| kind == Part::Attachment);
                if let Some((name, bytes)) = name.zip(crate::attach::bytes_of(block)) {
                    for (path, _) in links.iter().filter(|(_, n)| n == name) {
                        needs.files.push((path.clone(), bytes.clone()));
                    }
                }
            }
            Part::Upload => {
                if let Some(Some(upload)) = crate::prompt_uploads::named_upload(block)
                    && !ended(&proof.records)
                {
                    needs.uploads.push(upload);
                }
            }
            Part::Unknown => needs.unknown = true,
        }
    }
    needs.images = images.into_iter().collect();
    needs
}

/// The images `d`'s proof names whose bytes its request holds, by id (review of #37284 at
/// a088585e, F2; [`proof_needs`]): a restore writes them back where the machine keeps a
/// prompt's images, so a prompt it continues or runs again has them, and the delivery goes only
/// once a later link shows them held ([`Hub::proof_held`]).
pub(crate) fn proof_images(d: &Delivery) -> Vec<(String, Vec<u8>)> {
    proof_needs(d).images
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
/// session, one list per proof: their records past where `rows` (session, generation,
/// `lastSeq`) say each ends, of the same generation, from proofs that are [`whole`]. A restore
/// sends them with the copy, each proof whole or not at all (`restore.rs` `with_proofs`).
pub(crate) fn proofs_past(
    outbox: &Outbox,
    peer: &str,
    rows: &[(String, u64, u64)],
    since: &Since,
) -> HashMap<String, Vec<Vec<Value>>> {
    let mut out: HashMap<String, Vec<Vec<Value>>> = HashMap::new();
    for d in outbox.open_on_peers() {
        let (Some(pin), Some(proof)) = (&d.pin, &d.proof) else { continue };
        let row = rows.iter().find(|(s, g, _)| *s == pin.session && *g == pin.generation);
        let Some((_, _, last)) = row else { continue };
        if pin.peer != peer || !whole(&d, since) {
            continue;
        }
        let past: Vec<Value> =
            proof.records.iter().filter(|r| seq(r).is_some_and(|s| s > *last)).cloned().collect();
        if !past.is_empty() {
            out.entry(pin.session.clone()).or_default().push(past);
        }
    }
    out
}

/// This owner daemon's start: a random id, new at each start (a proof's provenance, [`step`]).
pub(crate) fn incarnation() -> String {
    #[cfg(test)]
    if let Some(id) = INCARNATION.with(|i| i.borrow().clone()) {
        return id;
    }
    static ID: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    ID.get_or_init(|| uuid::Uuid::new_v4().to_string()).clone()
}

#[cfg(test)]
thread_local! {
    /// Tests only: this thread's owner start (a daemon restart in the move simulation).
    pub(crate) static INCARNATION: std::cell::RefCell<Option<String>> = const { std::cell::RefCell::new(None) };
}

/// The files `d`'s prompt was saved as on its machine, and their bytes (review of #37284 at
/// 4dcbe192, F4): the non-image attachments [`crate::attach::receive`] wrote there and its
/// `queued` record names by path. A restore writes them back before that record goes in, and
/// the bytes go only once a later link shows the machine holds them.
pub(crate) fn proof_files(d: &Delivery) -> Vec<(std::path::PathBuf, Vec<u8>)> {
    proof_needs(d).files
}

/// What [`Hub::proof_held`] asks `d`'s machine besides the records (`_acpmux/attachments_held`):
/// whether it holds each file, image and upload of [`proof_needs`]. None: nothing to ask.
/// `(at_a088, at_4dcb, at_77f9)`: the rules of those heads (tests only), which asked for no
/// image, nothing, and no upload.
pub(crate) fn held_ask(
    d: &Delivery,
    (at_a088, at_4dcb, at_77f9): (bool, bool, bool),
) -> Option<Value> {
    let pin = d.pin.as_ref()?;
    let needs = proof_needs(d);
    let files: Vec<Value> = needs
        .files
        .iter()
        .map(|(path, bytes)| json!({"path": path, "sha256": crate::attach::sha256(bytes)}))
        .collect();
    let images: Vec<&String> =
        if at_a088 { Vec::new() } else { needs.images.iter().map(|(id, _)| id).collect() };
    let uploads: Vec<Value> = if at_77f9 {
        Vec::new()
    } else {
        needs.uploads.iter().map(|(id, name)| json!({"uploadId": id, "fileName": name})).collect()
    };
    if at_4dcb || (files.is_empty() && images.is_empty() && uploads.is_empty()) {
        return None;
    }
    Some(json!({"sessionId": pin.session, "files": files, "images": images, "uploads": uploads}))
}

/// The machine's answer whether it holds the files a proof names ([`Hub::proof_held`]).
pub(crate) const ATTACHMENTS_HELD: &str = "_acpmux/attachments_held";

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
    // A proof that holds nothing a machine runs again from, whole, proves nothing yet (review of
    // #37284 at 07f76930, F2, and at a088585e, F2): delivered again, as one not proven is.
    let needs = proof_needs(d);
    let images: HashSet<String> = needs.images.into_iter().map(|(id, _)| id).collect();
    let rerun = if crate::hub::journal_restore::rules_of_a088() {
        rerunnable_at_a088(&proof.records)
    } else {
        // A block no rule names (at 77f91e5a, F1) is never taken as held.
        rerunnable(&proof.records, &images)
            && (!needs.unknown || crate::hub::journal_restore::rules_of_77f9())
    };
    if !rerun && !crate::hub::journal_restore::rules_of_07f7() {
        return Step::Again;
    }
    let through = proof.records.iter().filter_map(seq).max();
    // A link of this start after the proof's, or any link of a later start (F6).
    let later = link > proof.link
        || (proof.incarnation != incarnation() && !crate::hub::journal_restore::rules_of_4dcb());
    match ends.get(&pin.session) {
        Some((generation, _)) if *generation != pin.generation => Step::Stale,
        Some((_, last)) if later && through.is_some_and(|t| t <= *last) => Step::Check,
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
    pub(crate) async fn proof_held(&self, d: &Delivery, link: (u64, u64)) -> Option<bool> {
        let (pin, proof) = (d.pin.as_ref()?, d.proof.as_ref()?);
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
        // And the files its prompt was saved as, by their hashes (F4), its images (review of
        // #37284 at a088585e, F2) and its uploads, which only the machine holds (at 77f91e5a,
        // F1): until then it waits, its bytes kept, and lapses visibly.
        let rules = (self.at_a088(), self.at_4dcb(), self.at_77f9());
        if let Some(params) = held_ask(d, rules) {
            let held = peer.request_on(ATTACHMENTS_HELD, params, Some(link.1)).await.ok()?;
            if held.get("held") != Some(&Value::Bool(true)) {
                return None;
            }
        }
        Some(true)
    }

    /// Whether peer `peer` is on link `link` (its instance and link epoch) still.
    pub(crate) fn peer_on_link(&self, peer: &str, link: (u64, u64)) -> bool {
        self.peer(peer).is_some_and(|p| (p.generation, p.link_epoch()) == link)
    }

    /// Answers whether the proofs they made are on disk.
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
    ) -> bool {
        for path in take_written(&self.outbox, (peer, session, generation), records, link) {
            // 4dcbe192's rules only: the bytes went at the proof.
            let _ = std::fs::remove_file(path);
        }
        // Kept only once the outbox is on disk: the copy counts the records as not told until
        // then (`peer_snapshot.rs` `write_one`).
        self.at_a088() || self.outbox.saved_now()
    }
}

/// [`Hub::proof_written`] on `outbox`: each delivery pinned to `pinned` takes the records of its
/// prompt among `records` as proof; answers the attachment files they kept. A proven delivery is
/// never sent again, but its attachments' bytes stay until its release ([`proof_files`]).
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
        // 4dcbe192 let the bytes go at the proof (F4); they go now only at its release.
        let at_4dcb = crate::hub::journal_restore::rules_of_4dcb();
        if at_4dcb {
            files.extend(outbox.attachments_path(&d));
        }
        outbox.update(&d.id, |d| {
            take_proof(d, records, link);
            if at_4dcb {
                crate::attach::strip(&mut d.request);
            }
        });
    }
    files
}
