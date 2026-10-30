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
//! A turn's diff (`codex.turn/diff/updated`) is stored without its `diff` the same way, noted as
//! `params.acpmuxSupersededDiff`, and the newest whole one is written before any record but the
//! agent's stream, or before the next turn's first diff.

use super::superseded::{call_of_msg, fields, only_output};
use super::*;
use serde_json::Map;

/// A snapshot this many times the bytes of its call's last stored one is stored whole.
const GROWTH: usize = 2;
/// A snapshot this long after its call's last stored one (or its first record) is stored whole.
pub const MAX_AGE_MS: u64 = 10_000;
/// Codex's whole-turn diff, as the app server's line is logged (`codex_app_server::tap_kind`).
const DIFF_KIND: &str = "codex.turn/diff/updated";
/// The note a turn diff stored without its `diff` carries in its `params`: the diff's bytes.
const DIFF_NOTE: &str = "acpmuxSupersededDiff";
const UPDATE_KIND: &str = "tool_call_update";

/// One chat's snapshots held back from its log while newer ones may replace them.
#[derive(Default)]
pub struct Deferral {
    calls: HashMap<String, Call>,
    /// The newest turn diff, not stored whole yet, and its turn.
    diff: Option<(Option<String>, Value)>,
}

struct Call {
    /// The text bytes of the content last stored whole, if any was.
    stored: Option<usize>,
    /// When it was stored, or the call's first record.
    since: u64,
    /// Its newest snapshot, held back: the message as the agent sent it.
    held: Option<Value>,
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
            if let Some(held) = self.calls.remove(&key).and_then(|call| call.held) {
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
            if !grown
                && !old
                && let Some(stub) = without_content(msg)
            {
                keep.stored = Some(stub);
                call.held = Some(msg.clone());
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
        } else if ends && let Some(held) = call.held.take() {
            keep.before.push((UPDATE_KIND, late(held)));
        }
        if ends {
            self.calls.remove(&key);
        }
        keep
    }

    /// Every held snapshot and turn diff, to be stored now.
    pub fn take_all(&mut self) -> Vec<(&'static str, Value)> {
        let mut out: Vec<(&'static str, Value)> = self
            .calls
            .values_mut()
            .filter_map(|call| call.held.take())
            .map(|held| (UPDATE_KIND, late(held)))
            .collect();
        out.extend(self.diff.take().map(|(_, diff)| (DIFF_KIND, diff)));
        out
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
        if let Some((held_turn, held)) = self.diff.take()
            && held_turn != turn
        {
            before.push((DIFF_KIND, held));
        }
        if !may_hold {
            return None;
        }
        let mut stub = msg.clone();
        let params = stub.get_mut("params")?.as_object_mut()?;
        if let Some(inner) = params.get_mut("params").and_then(Value::as_object_mut) {
            inner.remove("diff");
        }
        params.insert(DIFF_NOTE.into(), Value::from(diff.len()));
        self.diff = Some((turn, msg.clone()));
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
