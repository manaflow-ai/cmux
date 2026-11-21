//! Snapshots a newer record of the same call replaces, kept out of the log as they are appended.
//!
//! codex-acp sends a running command's whole output so far as the `content` of a
//! `tool_call_update` (with the increment beside it in `_meta.terminal_output_delta`), and Codex's
//! app server sends the whole turn's diff in each `turn/diff/updated`. So a Codex chat's log grows
//! with the square of a command's output: in five Codex logs on one host (2026-10-30), those
//! re-sent snapshots were 45 to 70% of every byte. `store/superseded.rs` leaves them out of a
//! chat's open page; this keeps most of them off the disk.
//!
//! Readers fold a call's updates with `content` replacing the call's content and an absent
//! `content` leaving it (the web client's `mergeToolItem`, `transcript.rs`, the iOS `ACPModel`),
//! and nothing reads a turn diff or the increments. So a snapshot that carries nothing but output
//! (`superseded::only_output`) of a running call is stored without its content, noted as
//! `_meta.acpmux.supersededContent` (bytes), and held here, while it is newest. It is written
//! after all, as a record of its own (its content alone: the stub logged the rest), just before
//! the first of:
//! - the update that ends its call, when that carries no content;
//! - the call's next `tool_call` (an id used again);
//! - any record but the agent's stream (`streams`): a prompt, the turn's end, a status, an exit.
//!
//! A newer update of the call that carries content makes it moot, and it is dropped. A snapshot
//! is stored whole when it is twice the bytes of the call's last stored one, or
//! [`MAX_AGE_MS`] after it (or after the call's first record), so a log read while the command
//! runs is at most that far behind. So every call folds, at the end of the log and at every
//! record that is not the agent's stream, to what it did before. The live stream is not touched:
//! clients hear every record as the agent sent it. Every increment stays in the log.
//!
//! A held body is written beside the log before its stub is (`Store::keep_held`, one file per call
//! or turn, in a numbered slot: [`Deferral::slot`]), and removed once the log holds it or something
//! that replaces it ([`Deferral::settled`]). So a daemon that dies without its shutdown
//! (`Hub::store_deferred`) loses nothing the stream showed: the next one stores what the files
//! hold, unless a record past where each was written replaces it ([`HeldBack`],
//! `Hub::take_back_held`). A snapshot of more than [`MAX_HELD_BYTES`], one past [`MAX_HELD_TOTAL`]
//! held in the chat, or one with [`MAX_HELD_FILES`] bodies written already, is stored whole.
//!
//! A turn's diff (`codex.turn/diff/updated`) is stored without its `diff` the same way, noted as
//! `params.acpmuxSupersededDiff`, and the newest whole one is written before any record but the
//! agent's stream, or before the next turn's first diff.

use super::superseded::{call_of_msg, fields, only_output};
use super::*;
use serde::{Deserialize, Serialize};
use serde_json::Map;

/// A snapshot this many times the bytes of its call's last stored one is stored whole.
const GROWTH: usize = 2;
/// A snapshot this long after its call's last stored one (or its first record) is stored whole.
pub const MAX_AGE_MS: u64 = 5_000;
/// A snapshot or turn diff of more bytes than this is stored whole, never held.
pub const MAX_HELD_BYTES: usize = 1 << 20;
/// What one chat holds at most, in snapshot and diff bytes; past it a snapshot is stored whole.
pub const MAX_HELD_TOTAL: usize = 8 << 20;
/// Codex's whole-turn diff, as the app server's line is logged (`codex_app_server::tap_kind`).
const DIFF_KIND: &str = "codex.turn/diff/updated";
/// The note a turn diff stored without its `diff` carries in its `params`: the diff's bytes.
const DIFF_NOTE: &str = "acpmuxSupersededDiff";
const UPDATE_KIND: &str = "tool_call_update";
/// The version of a held body's file ([`held_file`]); a file of another is removed unread.
const HELD_VERSION: u32 = 1;
/// The bodies one chat has written beside its log at most; past it a snapshot is stored whole. So
/// a chat's `held/` never names more files than this, however many calls it runs.
pub const MAX_HELD_FILES: usize = 64;

/// One chat's snapshots held back from its log while newer ones may replace them.
#[derive(Default)]
pub struct Deferral {
    calls: HashMap<String, Call>,
    /// The newest turn diff, not stored whole yet, its turn and its bytes.
    diff: Option<(Option<String>, Value, usize)>,
    /// Records made due that the store refused, in order: stored before anything else.
    retry: Vec<(&'static str, Value)>,
    /// The slots whose body is written beside the log (`Store::keep_held`) and not removed yet,
    /// each with what it is the body of. At most [`MAX_HELD_FILES`] but for those an earlier run
    /// left ([`Deferral::adopt`]).
    written: Vec<(u32, Owner)>,
}

/// What a held body is the body of: a call ([`call_of_msg`]'s key), or a turn's diff (as
/// [`Deferral::diff`] reads its turn: a turn id that is no string is no turn).
#[derive(Clone, Debug, PartialEq, Eq)]
enum Owner {
    Call(String),
    Diff(Option<String>),
}

struct Call {
    /// The text bytes of the content last stored whole, if any was.
    stored: Option<usize>,
    /// When it was stored, or the call's first record.
    since: u64,
    /// Its newest snapshot, held back: the message as the agent sent it, and its text bytes.
    held: Option<(Value, usize)>,
}

/// What the log keeps for one record.
#[derive(Default, Debug)]
pub struct Keep {
    /// Agent records (`dir` "in") the log stores first, with their kinds: held snapshots this
    /// record makes due.
    pub before: Vec<(&'static str, Value)>,
    /// The message the log stores in place of the record's, when it is not stored as sent.
    pub stored: Option<Value>,
}

impl Deferral {
    /// What the log keeps for a record the chat appends now (`at`, Unix ms). `may_hold`: whether
    /// this record may be held back; a copy (a fork's of its parent's turns) never is.
    pub fn keep(&mut self, dir: &str, kind: &str, msg: &Value, at: u64, may_hold: bool) -> Keep {
        let mut keep = self.keep_one(dir, kind, msg, at, may_hold);
        if !self.retry.is_empty() {
            let mut before = std::mem::take(&mut self.retry);
            before.append(&mut keep.before);
            keep.before = before;
        }
        keep
    }

    /// [`Deferral::keep`], less the records the store refused before.
    fn keep_one(&mut self, dir: &str, kind: &str, msg: &Value, at: u64, may_hold: bool) -> Keep {
        let mut keep = Keep::default();
        if dir == "in" && kind == DIFF_KIND {
            keep.stored = self.diff(msg, may_hold, &mut keep.before);
            return keep;
        }
        if !streams(dir, kind, msg) {
            keep.before = self.take_all();
            if starts_prompt(dir.as_bytes(), kind.as_bytes()) {
                // A call id names a call within one prompt (cx-jzhka).
                self.calls.clear();
            }
            return keep;
        }
        if dir != "in" || (kind != "tool_call" && kind != UPDATE_KIND) {
            return keep;
        }
        let Some((key, plain)) = call_of_msg(msg) else { return keep };
        if kind == "tool_call" {
            if let Some((held, _)) = self.calls.remove(&key).and_then(|call| call.held) {
                keep.before.push((UPDATE_KIND, late(held)));
            }
            self.calls.insert(key, Call { stored: None, since: at, held: None });
            return keep;
        }
        let Some(update) = msg.pointer("/params/update").and_then(Value::as_object) else {
            return keep;
        };
        if update.get("sessionUpdate").and_then(Value::as_str) != Some(UPDATE_KIND) {
            return keep;
        }
        let ends =
            matches!(update.get("status").and_then(Value::as_str), Some("completed" | "failed"));
        let held_elsewhere = self.held_bytes().saturating_sub(
            self.calls.get(&key).and_then(|c| c.held.as_ref()).map_or(0, |(_, bytes)| *bytes),
        );
        let call =
            self.calls.entry(key.clone()).or_insert(Call { stored: None, since: at, held: None });
        let content = update.get("content");
        let snapshot = content.and_then(Value::as_array).map(|parts| text_bytes(parts));
        if let Some(bytes) = snapshot
            && may_hold
            && plain
            && !ends
            && only_output(update, &fields(update))
        {
            let grown = call.stored.is_some_and(|last| bytes >= last.saturating_mul(GROWTH).max(1));
            let old = at.saturating_sub(call.since) >= MAX_AGE_MS;
            let fits =
                bytes <= MAX_HELD_BYTES && held_elsewhere.saturating_add(bytes) <= MAX_HELD_TOTAL;
            if !grown
                && !old
                && fits
                && let Some(stub) = without_content(msg)
            {
                keep.stored = Some(stub);
                call.held = Some((msg.clone(), bytes));
                return keep;
            }
        }
        if content.is_some() {
            // Its content replaces the held one's (an explicit `null` too).
            call.held = None;
            if let Some(bytes) = snapshot {
                call.stored = Some(bytes);
                call.since = at;
            }
        } else if ends && let Some((held, _)) = call.held.take() {
            keep.before.push((UPDATE_KIND, late(held)));
        }
        if ends {
            self.calls.remove(&key);
        }
        keep
    }

    /// Every held snapshot and turn diff, to be stored now.
    pub fn take_all(&mut self) -> Vec<(&'static str, Value)> {
        let mut out = std::mem::take(&mut self.retry);
        out.extend(
            self.calls
                .values_mut()
                .filter_map(|call| call.held.take())
                .map(|(held, _)| (UPDATE_KIND, late(held))),
        );
        out.extend(self.diff.take().map(|(_, diff, _)| (DIFF_KIND, diff)));
        out
    }

    /// The tool output it holds, as it would be stored now, left held: what a fork copies after
    /// its parent's log.
    pub fn pending(&self) -> Vec<Value> {
        let retried =
            self.retry.iter().filter(|(kind, _)| *kind == UPDATE_KIND).map(|(_, m)| m.clone());
        let held =
            self.calls.values().filter_map(|call| call.held.as_ref()).map(|(m, _)| late(m.clone()));
        retried.chain(held).collect()
    }

    /// Records [`Deferral::keep`] or [`Deferral::take_all`] gave to be stored that the store
    /// refused, in order: they are stored first at the next record, which keeps each call's fold
    /// (an older record before a newer one), until a record that replaces one is stored
    /// ([`Deferral::stored`]).
    pub fn retry(&mut self, refused: Vec<(&'static str, Value)>) {
        let mut later = std::mem::replace(&mut self.retry, refused);
        self.retry.append(&mut later);
    }

    /// A record (`dir`, `kind`, `msg`) is in the store: a waiting record it replaces
    /// ([`supersedes`]) is dropped, since stored after it, it would undo it.
    pub fn stored(&mut self, dir: &str, kind: &str, msg: &Value) {
        if !self.retry.is_empty() {
            self.retry.retain(|(late_kind, late)| !supersedes(dir, kind, msg, late_kind, late));
        }
    }

    /// The slot to write the held body of the record (`kind`, `msg`) in (`Store::keep_held`): the
    /// one its call or turn has, else the lowest free one, taken until it settles
    /// ([`Deferral::settled`]). A slot is a small number used again, never a name of the call's
    /// own: a watcher of the home keeps every path it is told of (`dead_temps`, #44520), and a
    /// chat runs calls without end. None for a record never held, or with [`MAX_HELD_FILES`]
    /// taken.
    pub fn slot(&mut self, kind: &str, msg: &Value) -> Option<String> {
        let owner = owner(kind, msg)?;
        if let Some((index, _)) = self.written.iter().find(|(_, o)| *o == owner) {
            return Some(slot_name(*index));
        }
        if self.written.len() >= MAX_HELD_FILES {
            return None;
        }
        let index = (0u32..).find(|i| self.written.iter().all(|(taken, _)| taken != i))?;
        self.written.push((index, owner));
        Some(slot_name(index))
    }

    /// The body of the record (`kind`, `msg`) an earlier run wrote in `slot` is to be stored
    /// (`Hub::take_back_held`): its slot is taken until it is.
    pub fn adopt(&mut self, slot: &str, kind: &str, msg: &Value) {
        if let Some(taken) = slot_index(slot).zip(owner(kind, msg)) {
            self.written.push(taken);
        }
    }

    /// The taken slots whose body it no longer holds (no held call's, not the held diff's, no
    /// record's waiting to be stored again), free again: their files are to be removed. Free while
    /// none is taken; it never copies a body.
    pub fn settled(&mut self) -> Vec<String> {
        if self.written.is_empty() {
            return Vec::new();
        }
        let (calls, diff, retry) = (&self.calls, &self.diff, &self.retry);
        let mut settled = Vec::new();
        self.written.retain(|(index, of)| {
            let held = match of {
                Owner::Call(key) => calls.get(key).is_some_and(|call| call.held.is_some()),
                Owner::Diff(turn) => diff.as_ref().is_some_and(|(held, _, _)| held == turn),
            };
            let waits = || retry.iter().any(|(kind, msg)| owner(kind, msg).as_ref() == Some(of));
            let stays = held || waits();
            if !stays {
                settled.push(slot_name(*index));
            }
            stays
        });
        settled
    }

    /// The snapshot and diff bytes held now, those waiting to be stored again included.
    fn held_bytes(&self) -> usize {
        let calls: usize =
            self.calls.values().filter_map(|c| c.held.as_ref()).map(|(_, bytes)| *bytes).sum();
        let retried: usize = self.retry.iter().map(|(_, msg)| late_bytes(msg)).sum();
        calls
            .saturating_add(retried)
            .saturating_add(self.diff.as_ref().map_or(0, |(_, _, bytes)| *bytes))
    }

    /// A turn diff: the stub to store in its place (it is held), if it is not stored whole. A held
    /// diff of another turn is stored first.
    fn diff(
        &mut self,
        msg: &Value,
        may_hold: bool,
        before: &mut Vec<(&'static str, Value)>,
    ) -> Option<Value> {
        let inner = msg.pointer("/params/params")?.as_object()?;
        let diff = inner.get("diff")?.as_str()?;
        let turn = inner.get("turnId").and_then(Value::as_str).map(str::to_owned);
        if let Some((held_turn, held, _)) = self.diff.take()
            && held_turn != turn
        {
            before.push((DIFF_KIND, held));
        }
        if !may_hold
            || diff.len() > MAX_HELD_BYTES
            || self.held_bytes().saturating_add(diff.len()) > MAX_HELD_TOTAL
        {
            return None;
        }
        let mut stub = msg.clone();
        let params = stub.get_mut("params")?.as_object_mut()?;
        if let Some(inner) = params.get_mut("params").and_then(Value::as_object_mut) {
            inner.remove("diff");
        }
        params.insert(DIFF_NOTE.into(), Value::from(diff.len()));
        self.diff = Some((turn, msg.clone(), diff.len()));
        Some(stub)
    }
}

/// Whether a record is part of the agent's stream, which held snapshots may wait past: its
/// session updates and its harness's raw lines. Anything else (a prompt, a request, the turn's
/// answer, acpmux's own records) comes after every snapshot held before it.
fn streams(dir: &str, kind: &str, msg: &Value) -> bool {
    dir == "in"
        && (msg.get("method").and_then(Value::as_str) == Some(crate::rpc::method::SESSION_UPDATE)
            || kind.starts_with("codex.")
            || kind.starts_with("claude."))
}

/// The text bytes of a content of text parts (`superseded::only_output`).
fn text_bytes(parts: &[Value]) -> usize {
    parts
        .iter()
        .filter_map(|part| part.get("text").or_else(|| part.pointer("/content/text")))
        .filter_map(Value::as_str)
        .map(str::len)
        .sum()
}

/// Whether a record (`dir`, `kind`, `msg`), stored after a late one, makes it wrong to store that
/// late one after it: a start of its call id (the id names a new call then: stored after it, the
/// late output would read as that call's), an update of its call with content (which replaces
/// it), or a newer diff of its turn that carries its diff. A stub (an update without content, a
/// diff without its `diff`) replaces nothing: the live path passes whole messages only, and the
/// log a restart reads ([`HeldBack`]) holds the stubs of the very bodies it looks for.
fn supersedes(dir: &str, kind: &str, msg: &Value, late_kind: &str, late: &Value) -> bool {
    if dir != "in" {
        return false;
    }
    if late_kind == DIFF_KIND {
        let turn = |m: &Value| m.pointer("/params/params/turnId").cloned();
        let whole = msg.pointer("/params/params/diff").is_some_and(Value::is_string);
        return kind == DIFF_KIND && whole && turn(msg) == turn(late);
    }
    let same_call = || call_of_msg(msg).zip(call_of_msg(late)).is_some_and(|(a, b)| a.0 == b.0);
    match kind {
        "tool_call" => same_call(),
        UPDATE_KIND => msg.pointer("/params/update/content").is_some() && same_call(),
        _ => false,
    }
}

/// What the record (`kind`, `msg`) is a body of, were it held. The same for a snapshot as sent
/// and as stored late ([`late`] keeps what [`call_of_msg`] reads). None for a record never held.
fn owner(kind: &str, msg: &Value) -> Option<Owner> {
    match kind {
        UPDATE_KIND => call_of_msg(msg).map(|(key, _)| Owner::Call(key)),
        DIFF_KIND => {
            let turn = msg.pointer("/params/params/turnId").and_then(Value::as_str);
            Some(Owner::Diff(turn.map(str::to_owned)))
        }
        _ => None,
    }
}

/// Whether `slot` could name a held body's file (`Store::keep_held`): a few lowercase hex digits
/// only, so it never names a path elsewhere.
pub fn is_slot(slot: &str) -> bool {
    (1..=8).contains(&slot.len()) && slot.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

/// The name of slot `index`: its number in lowercase hex.
fn slot_name(index: u32) -> String {
    format!("{index:x}")
}

/// The slot `name` names, if it is one's name as [`slot_name`] writes it.
fn slot_index(name: &str) -> Option<u32> {
    let index = u32::from_str_radix(name, 16).ok().filter(|_| is_slot(name))?;
    (slot_name(index) == name).then_some(index)
}

/// A held body's file (`Store::keep_held`): this version, the chat's seq when it was written
/// (`after`: a record past it may replace the body), its kind, and the message as sent, borrowed.
#[derive(Serialize)]
struct HeldFile<'a> {
    v: u32,
    after: u64,
    kind: &'a str,
    msg: &'a Value,
}

/// The bytes of a held body's file: the message `msg` of kind `kind`, held while the chat's seq
/// is `after`. Serialized from the borrowed message: the body is never copied.
pub fn held_file(after: u64, kind: &str, msg: &Value) -> serde_json::Result<Vec<u8>> {
    serde_json::to_vec(&HeldFile { v: HELD_VERSION, after, kind, msg })
}

/// The held bodies an earlier run wrote beside the log (`Store::kept_held`), read back at the next
/// start (`Hub::take_back_held`): each is stored unless a record of the log past where it was
/// written replaces it ([`supersedes`]). The log holds its stub, which replaces nothing; a late
/// record of it that run stored, or anything newer of its call or turn, does.
#[derive(Default)]
pub struct HeldBack {
    /// The bodies that read, oldest written first.
    found: Vec<Found>,
    /// The names of the files that do not read as a body of this build's (not a slot's name, not
    /// JSON, another version, a record never held): removed unread.
    pub unread: Vec<String>,
}

/// One body an earlier run left.
struct Found {
    slot: String,
    /// The chat's seq when it was written.
    after: u64,
    kind: &'static str,
    /// The record to store: an update's late form, a diff as sent.
    msg: Value,
    /// A record of the log past `after` replaces it.
    replaced: bool,
}

/// A body to store now (`Hub::take_back_held`): its slot, its kind and its record.
pub type HeldLate = (String, &'static str, Value);

impl HeldBack {
    /// Reads `files`, each a slot and its bytes.
    pub fn read(files: Vec<(String, Vec<u8>)>) -> Self {
        #[derive(Deserialize)]
        struct Written {
            v: u32,
            after: u64,
            kind: String,
            msg: Value,
        }
        let mut back = Self::default();
        for (slot, bytes) in files {
            let read = serde_json::from_slice::<Written>(&bytes)
                .ok()
                .filter(|read| read.v == HELD_VERSION && slot_index(&slot).is_some());
            let body = read.and_then(|read| {
                let kind = match read.kind.as_str() {
                    UPDATE_KIND => UPDATE_KIND,
                    DIFF_KIND => DIFF_KIND,
                    _ => return None,
                };
                let msg = if kind == UPDATE_KIND { late(read.msg) } else { read.msg };
                owner(kind, &msg).map(|_| (read.after, kind, msg))
            });
            match body {
                Some((after, kind, msg)) => {
                    back.found.push(Found { slot, after, kind, msg, replaced: false });
                }
                None => back.unread.push(slot),
            }
        }
        // Stored in the order they were written.
        back.found.sort_by_key(|found| found.after);
        back
    }

    /// The seq to read the log past (`Store::scan`'s `after`); None with no body to look for.
    pub fn after(&self) -> Option<u64> {
        self.found.first().map(|found| found.after)
    }

    /// `record`, read from the log in order: the bodies it replaces are dropped. False once every
    /// body is replaced, so the read can stop.
    pub fn saw(&mut self, record: &EventRecord) -> bool {
        for found in &mut self.found {
            if !found.replaced && record.seq > found.after {
                found.replaced =
                    supersedes(&record.dir, &record.kind, &record.msg, found.kind, &found.msg);
            }
        }
        self.found.iter().any(|found| !found.replaced)
    }

    /// The bodies to store now, oldest written first; and the slots of those the log replaced.
    pub fn into_late(self) -> (Vec<HeldLate>, Vec<String>) {
        let mut late = Vec::new();
        let mut replaced = Vec::new();
        for found in self.found {
            if found.replaced {
                replaced.push(found.slot);
            } else {
                late.push((found.slot, found.kind, found.msg));
            }
        }
        (late, replaced)
    }
}

/// The bytes of a late record's content or diff.
fn late_bytes(msg: &Value) -> usize {
    let content = msg.pointer("/params/update/content").and_then(Value::as_array);
    let diff = msg.pointer("/params/params/diff").and_then(Value::as_str);
    content.map_or(0, |parts| text_bytes(parts)).saturating_add(diff.map_or(0, str::len))
}

/// A held snapshot as stored late: its content alone. Its stub already logged the rest (its
/// status, the increments), and a status-only update may have come since.
fn late(mut msg: Value) -> Value {
    if let Some(update) = msg.pointer_mut("/params/update").and_then(Value::as_object_mut) {
        update.retain(|key, _| matches!(key.as_str(), "sessionUpdate" | "toolCallId" | "content"));
    }
    msg
}

/// The message with its update's `content` left out and noted, copied without copying the content.
fn without_content(msg: &Value) -> Option<Value> {
    let copy = |object: &Map<String, Value>, skip: &str| -> Map<String, Value> {
        object.iter().filter(|(k, _)| *k != skip).map(|(k, v)| (k.clone(), v.clone())).collect()
    };
    let params = msg.get("params")?.as_object()?;
    let update = params.get("update")?.as_object()?;
    let mut stub_update = copy(update, "content");
    let bytes = serde_json::to_string(update.get("content")?).map_or(0, |s| s.len());
    let meta = stub_update.entry("_meta").or_insert_with(|| Value::Object(Map::new()));
    if let Some(meta) = meta.as_object_mut() {
        let acpmux = meta.entry("acpmux").or_insert_with(|| Value::Object(Map::new()));
        if let Some(acpmux) = acpmux.as_object_mut() {
            acpmux.insert(super::superseded::NOTE.into(), Value::from(bytes));
        }
    }
    let mut stub_params = copy(params, "update");
    stub_params.insert("update".into(), Value::Object(stub_update));
    let mut stub = copy(msg.as_object()?, "params");
    stub.insert("params".into(), Value::Object(stub_params));
    Some(Value::Object(stub))
}

#[cfg(test)]
#[path = "deferred_tests.rs"]
mod tests;
