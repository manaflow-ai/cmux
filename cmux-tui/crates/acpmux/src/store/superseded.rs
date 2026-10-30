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
//! record through [`Superseded::keep`]:
//! - An update whose every field a newer update of its call in the same read carries again is left
//!   out, unless it ends the call (its time is the call's end).
//! - Other updates drop `content` a newer one replaces, noted as `_meta.acpmux.supersededContent`
//!   (bytes).
//!
//! A call id names a call within one prompt only (an adapter that numbers calls per process reuses
//! one in a later prompt; the web client clears its calls at each prompt, cx-jzhka). So a
//! `user_message` or `turn_started` the read passes ends what newer updates cover, even when the
//! page's kinds leave it out ([`starts_prompt`]). Every call still folds to its state at the end of
//! the read. The log, the live stream, forward reads and reads with no byte bound are unchanged.

use super::*;
use serde_json::Map;

/// The note an update whose content was left out carries in `_meta.acpmux`: the content's bytes.
const NOTE: &str = "supersededContent";
/// `_meta` keys no reader folds: Codex's output increments, which the call's content holds too.
const UNREAD_META: &[&str] = &["terminal_output_delta"];

/// Whether a record with this `dir` and `kind` starts a prompt: no call id carries across it. A
/// read that leaves out superseded updates passes these to [`Superseded::keep`] whatever kinds its
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

/// The fields of an update a reader folds, `_meta` ones as `_meta.<key>` (and `_meta.acpmux.<key>`).
fn fields(update: &Map<String, Value>) -> BTreeSet<String> {
    let mut out = BTreeSet::new();
    for (key, value) in update {
        match (key.as_str(), value.as_object()) {
            ("toolCallId" | "sessionUpdate", _) => {}
            ("content", _) if value.is_null() => {}
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
    calls: HashMap<String, BTreeSet<String>>,
}

impl Superseded {
    /// Whether `rec`, the next older record of the read, stays; its content goes when a newer
    /// update of its call carries content. An update whose every field a newer one of its call
    /// carries goes whole, unless it ends the call. Every other record stays as it is.
    pub fn keep(&mut self, rec: &mut EventRecord) -> bool {
        // Older than a prompt: no newer update of this read is of the same call.
        if starts_prompt(rec.dir.as_bytes(), rec.kind.as_bytes()) {
            self.calls.clear();
            return true;
        }
        let Some(update) = update_of(rec) else { return true };
        let Some(id) = update.get("toolCallId").and_then(Value::as_str).map(str::to_owned) else {
            return true;
        };
        let fields = fields(update);
        let Some(newer) = self.calls.get_mut(&id) else {
            self.calls.insert(id, fields);
            return true;
        };
        let ends =
            matches!(update.get("status").and_then(Value::as_str), Some("completed" | "failed"));
        if !ends && fields.is_subset(newer) {
            return false;
        }
        if newer.contains("content") {
            leave_out_content(update);
        }
        newer.extend(fields);
        true
    }
}

#[cfg(test)]
#[path = "superseded_tests.rs"]
mod tests;
