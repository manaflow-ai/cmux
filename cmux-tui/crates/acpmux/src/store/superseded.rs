//! Tool call updates a newer update of the same call makes moot, left out of a page.
//!
//! codex-acp sends a running command's whole output so far as the `content` of each
//! `tool_call_update`, with the increment beside it in `_meta.terminal_output_delta`, so a long
//! command's records grow with the square of its output. One Codex chat (2026-10-29) logged 27,564
//! updates (150 MB) for 219 calls, and 123 MB of that was `content` a later update replaced. In ACP
//! an update's `content` replaces the call's content, and every reader folds it that way (the web
//! client's `mergeToolItem`, `transcript.rs`), and no reader folds the deltas. A chat opens from
//! the newest page of its log, bounded by bytes, so those snapshots filled it: a Codex chat's open
//! page held a few records of one running command.
//!
//! A page read newest first for a client that bounds it by bytes (`hub/paging.rs`) passes each
//! record through [`Superseded::read`]. Only an update that carries nothing but output is touched
//! (its `status`, and `content` of text alone, beside the increments no reader folds): never one
//! with a title, kind, input, raw output, locations, a diff, an image or any other `_meta` (a Codex
//! subagent's, say), so every other part of the fold (`mergeToolItem`, `showsNothing`, the
//! subagent folds) reads the same records.
//! - Such an update whose every field a newer update of its call in the same read carries again,
//!   and that does not end the call, is left out, unless it is the oldest the read holds of its
//!   call: the reader takes the call's start time from the first record of it that it sees.
//! - Such an update a newer one replaces the content of loses its `content`, noted as
//!   `_meta.acpmux.supersededContent` (bytes).
//!
//! A call id names a call within one prompt only (an adapter that numbers calls per process reuses
//! one in a later prompt; the web client clears its calls at each prompt, cx-jzhka). So a
//! `user_message` or `turn_started` the read passes ends what newer updates cover, even when the
//! page's kinds leave it out ([`starts_prompt`]). Every call still folds to its state at the end of
//! the read. The log, the live stream, forward reads and reads with no byte bound are unchanged.

use super::*;
use serde_json::Map;

/// The note an update whose content was left out carries in `_meta.acpmux`: the content's bytes.
pub(super) const NOTE: &str = "supersededContent";
/// `_meta` keys no reader folds: Codex's output increments, which the call's content holds too.
const UNREAD_META: &[&str] = &["terminal_output_delta"];

/// Whether a record with this `dir` and `kind` starts a prompt: no call id carries across it. A
/// read that leaves out superseded updates passes these to [`Superseded::read`] whatever kinds its
/// page holds.
pub fn starts_prompt(dir: &[u8], kind: &[u8]) -> bool {
    dir == b"mux" && matches!(kind, b"user_message" | b"turn_started")
}

/// The update of a `tool_call_update` record, if it is one.
fn update_of(rec: &mut EventRecord) -> Option<&mut Map<String, Value>> {
    if rec.kind != "tool_call_update" {
        return None;
    }
    let update = rec.msg.pointer_mut("/params/update")?.as_object_mut()?;
    let is_update = update.get("sessionUpdate").and_then(Value::as_str) == Some("tool_call_update");
    is_update.then_some(update)
}

/// The call a `tool_call` or `tool_call_update` record is of: its id within its owner (a native
/// subagent's calls, `params._meta.acpmux.subagent`, are numbered apart from the chat's), and
/// whether the record carries nothing at its `params` but that owner.
fn call_of(rec: &EventRecord) -> Option<(String, bool)> {
    call_of_msg(&rec.msg)
}

/// [`call_of`] a record's message.
pub(super) fn call_of_msg(msg: &Value) -> Option<(String, bool)> {
    let params = msg.get("params")?;
    let id = params.pointer("/update/toolCallId")?.as_str()?;
    let owner = params.pointer("/_meta/acpmux/subagent");
    // Any `_meta` but that owner, of any type, may be read: the record is not plain.
    let plain = params.get("_meta").is_none_or(|meta| {
        meta.as_object().is_some_and(|meta| {
            meta.len() == 1
                && meta
                    .get("acpmux")
                    .and_then(Value::as_object)
                    .is_some_and(|m| m.len() == 1 && owner.is_some())
        })
    });
    Some((format!("{}\u{0}{id}", owner.map(Value::to_string).unwrap_or_default()), plain))
}

/// The fields of an update a reader folds (an explicit `content: null` clears the call's output),
/// `_meta` ones as `_meta.<key>` (and `_meta.acpmux.<key>`).
pub(super) fn fields(update: &Map<String, Value>) -> BTreeSet<String> {
    let mut out = BTreeSet::new();
    for (key, value) in update {
        match (key.as_str(), value.as_object()) {
            ("toolCallId" | "sessionUpdate", _) => {}
            ("_meta", Some(meta)) => {
                for (k, v) in meta {
                    match (k.as_str(), v.as_object()) {
                        (k, _) if UNREAD_META.contains(&k) => {}
                        ("acpmux", Some(acpmux)) => out.extend(
                            acpmux
                                .keys()
                                .filter(|k| *k != NOTE)
                                .map(|k| format!("_meta.acpmux.{k}")),
                        ),
                        _ => {
                            out.insert(format!("_meta.{k}"));
                        }
                    }
                }
            }
            _ => {
                out.insert(key.clone());
            }
        }
    }
    out
}

/// Whether the update carries nothing but its call's output: no field but `status` and `content`
/// (beside the `_meta` no reader folds), and only text in the content.
pub(super) fn only_output(update: &Map<String, Value>, fields: &BTreeSet<String>) -> bool {
    let text = |part: &Value| match part.get("type").and_then(Value::as_str) {
        Some("text") => true,
        Some("content") => part.pointer("/content/type").and_then(Value::as_str) == Some("text"),
        _ => false,
    };
    fields.iter().all(|f| f == "status" || f == "content")
        && update
            .get("content")
            .is_none_or(|c| c.is_null() || c.as_array().is_some_and(|parts| parts.iter().all(text)))
}

/// Takes the update's content out and notes how many bytes it held.
fn leave_out_content(update: &mut Map<String, Value>) {
    let Some(content) = update.remove("content") else { return };
    let bytes = serde_json::to_string(&content).map_or(0, |s| s.len());
    let meta = update.entry("_meta").or_insert_with(|| Value::Object(Map::new()));
    if let Some(meta) = meta.as_object_mut() {
        let acpmux = meta.entry("acpmux").or_insert_with(|| Value::Object(Map::new()));
        if let Some(acpmux) = acpmux.as_object_mut() {
            acpmux.insert(NOTE.into(), Value::from(bytes));
        }
    }
}

/// A newest-first read of a log's records: what each tool call's newer updates already carry.
#[derive(Default)]
pub struct Superseded {
    calls: HashMap<String, Call>,
}

#[derive(Default)]
struct Call {
    /// The fields the call's updates newer than the read's place carry.
    fields: BTreeSet<String>,
    /// Where the read keeps the oldest update of the call it holds, when a newer one covers it.
    held: Option<usize>,
}

impl Superseded {
    /// Reads `rec`, the next older record of the read, which stays at `slot` of the read; its
    /// content goes when a newer update of its call replaces it. Returns the slot of a newer
    /// record that `rec` makes moot: an update of the same call newer ones cover, kept only while
    /// it was the oldest of its call.
    ///
    /// `delivered` says whether a record goes out whole (a page stubs one too big for a message,
    /// `hub/paging.rs` `fit`): a newer record that does not supersedes nothing older.
    pub fn read(
        &mut self,
        rec: &mut EventRecord,
        slot: usize,
        delivered: impl FnOnce(&EventRecord) -> bool,
    ) -> Option<usize> {
        // Older than a prompt: no newer update of this read is of the same call.
        if starts_prompt(rec.dir.as_bytes(), rec.kind.as_bytes()) {
            self.calls.clear();
            return None;
        }
        if rec.kind != "tool_call" && rec.kind != "tool_call_update" {
            return None;
        }
        let (key, plain) = call_of(rec)?;
        if rec.kind == "tool_call" {
            // The call's start: older than every update of it.
            return if delivered(rec) {
                self.calls.remove(&key).and_then(|call| call.held)
            } else {
                None
            };
        }
        let newer = self.calls.get(&key).map(|call| call.fields.contains("content"));
        let update = update_of(rec)?;
        let fields = fields(update);
        let output = plain && only_output(update, &fields);
        if output && newer == Some(true) {
            leave_out_content(update);
        }
        let ends =
            matches!(update.get("status").and_then(Value::as_str), Some("completed" | "failed"));
        if !delivered(rec) {
            return None;
        }
        let Some(call) = self.calls.get_mut(&key) else {
            self.calls.insert(key, Call { fields, held: None });
            return None;
        };
        if output && !ends && fields.is_subset(&call.fields) {
            return call.held.replace(slot);
        }
        call.fields.extend(fields);
        call.held.take()
    }
}

#[cfg(test)]
#[path = "superseded_tests.rs"]
mod tests;
