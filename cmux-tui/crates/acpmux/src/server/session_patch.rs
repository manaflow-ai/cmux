//! `_acpmux/session_patch`: a chat's row change as only what changed, to a client that asked for
//! it (`initialize` `_meta.acpmux.sessionChangedDelta: true`, capability
//! [`CAPABILITY`]). Every other client hears each change as the whole row in
//! `_acpmux/session_changed`, as before.
//!
//! Why: an attached chat's row carries its time breakdown, up to 512 spans (`time_breakdown.rs`
//! `MAX_SPANS`), its tools and its MCP servers, 37 to 77 KB on a 10,000-message chat, and the
//! whole row went out again on every record of a running turn: about 220 KB a minute to a phone
//! on cellular while one answer streamed (Leo, 2026-11-22: "i should still be getting things fast
//! and responsive and flowing, even on ostensibly infinitely long chats").
//!
//! The contract. Each `session_changed` this connection hears for a local chat carries `rowSeq`,
//! one more than the last row it heard of that chat. After that the connection hears
//! `_acpmux/session_patch {sessionId, patch, rowSeq, baseRowSeq, kind, recordKind, seq, listSeq}`
//! instead, which applies to the row it holds at `baseRowSeq` (the last `session_changed` or
//! `session_patch` of that chat) and makes the row at `rowSeq`. A connection whose row at
//! `baseRowSeq` is gone reads the chat's row with `_acpmux/info`; the daemon sends the whole row
//! again whenever it no longer knows what the connection holds (the row's kind changed with an
//! attach or a detach, or the connection holds more than [`MAX_ROWS`] chats' rows).
//!
//! `patch` is a JSON merge patch (RFC 7386): an object merges key by key, `null` removes the key
//! (a row field that is `null` and one that is absent mean the same), anything else replaces it.
//! One addition, for the long lists that grow at one end (the time breakdown's spans):
//! `{"$splice": [from, keep, items]}` in place of an array is `held[from..from + keep]` followed by
//! `items`.

use super::{Conn, Message, method};
use crate::no_panic::LockExt as _;
use serde_json::{Map, Value, json};
use std::collections::HashMap;
use std::hash::{Hash, Hasher};
use std::sync::atomic::Ordering;

/// The capability id `initialize` lists (`capabilities.rs`).
pub const CAPABILITY: &str = "session-changed-delta-v1";

/// The chats whose last row one connection keeps the shape of; past it, one is let go and its
/// next change goes out whole.
pub(crate) const MAX_ROWS: usize = 256;

/// A value as hashes: what a row was, without holding the row.
#[derive(Debug)]
enum Shape {
    Leaf(u64),
    Object(HashMap<String, Shape>),
    /// One hash per item.
    Array(Vec<u64>),
}

fn hash_value(v: &Value, h: &mut impl Hasher) {
    match v {
        Value::Null => 0u8.hash(h),
        Value::Bool(b) => (1u8, b).hash(h),
        Value::Number(n) => (2u8, n.to_string()).hash(h),
        Value::String(s) => (3u8, s).hash(h),
        Value::Array(a) => {
            (4u8, a.len()).hash(h);
            for item in a {
                hash_value(item, h);
            }
        }
        Value::Object(o) => {
            (5u8, o.len()).hash(h);
            for (k, item) in o {
                k.hash(h);
                hash_value(item, h);
            }
        }
    }
}

fn hash_of(v: &Value) -> u64 {
    let mut h = std::collections::hash_map::DefaultHasher::new();
    hash_value(v, &mut h);
    h.finish()
}

fn shape_of(v: &Value) -> Shape {
    match v {
        Value::Object(o) => {
            Shape::Object(o.iter().map(|(k, v)| (k.clone(), shape_of(v))).collect())
        }
        Value::Array(a) => Shape::Array(a.iter().map(hash_of).collect()),
        other => Shape::Leaf(hash_of(other)),
    }
}

/// What takes `old` to `new`, as a merge patch; None when nothing changed.
fn diff(old: &Shape, new: &Value) -> Option<Value> {
    match (old, new) {
        (Shape::Object(held), Value::Object(now)) => {
            let mut patch = Map::new();
            for (k, v) in now {
                match held.get(k) {
                    Some(was) => {
                        if let Some(p) = diff(was, v) {
                            patch.insert(k.clone(), p);
                        }
                    }
                    // Absent and null are the same row.
                    None if v.is_null() => {}
                    None => {
                        patch.insert(k.clone(), v.clone());
                    }
                }
            }
            let null = hash_of(&Value::Null);
            for (k, was) in held {
                let was_null = matches!(was, Shape::Leaf(h) if *h == null);
                if !now.contains_key(k) && !was_null {
                    patch.insert(k.clone(), Value::Null);
                }
            }
            (!patch.is_empty()).then_some(Value::Object(patch))
        }
        (Shape::Array(held), Value::Array(now)) => {
            let hashes: Vec<u64> = now.iter().map(hash_of).collect();
            if *held == hashes {
                return None;
            }
            Some(splice(held, &hashes, now).unwrap_or_else(|| new.clone()))
        }
        (Shape::Leaf(h), v) if !v.is_object() && !v.is_array() && *h == hash_of(v) => None,
        _ => Some(new.clone()),
    }
}

/// `now` as the longest run of `held` it starts with and the items after it, when that is
/// smaller than `now` itself.
fn splice(held: &[u64], hashes: &[u64], now: &[Value]) -> Option<Value> {
    let first = *hashes.first()?;
    let from = held.iter().position(|h| *h == first)?;
    let keep = held.get(from..)?.iter().zip(hashes).take_while(|(a, b)| a == b).count();
    // Only the items after the run go out; a run of one or two saves nothing worth the form.
    if keep < 3 {
        return None;
    }
    let after = now.get(keep..)?;
    Some(json!({"$splice": [from, keep, after]}))
}

/// The last row of a chat one connection was sent.
#[derive(Debug)]
struct Sent {
    /// With its tools (an attached chat's, or a watch with `tools`), or the list's row.
    full: bool,
    row_seq: u64,
    shape: Shape,
}

/// Per connection: whether it asked for patches, and the shape of each chat's last row it heard.
#[derive(Debug, Default)]
pub(crate) struct SentRows {
    rows: HashMap<String, Sent>,
}

/// What one row change sends a connection.
pub(crate) enum Change {
    /// The whole row, as `session_changed` with this `rowSeq`.
    Whole { row_seq: u64 },
    /// `session_patch`.
    Patch { patch: Value, row_seq: u64 },
}

impl SentRows {
    /// The change of `session`'s row to `row` (`full`: the row with its tools), and what this
    /// connection holds of it from now on.
    pub(crate) fn change(&mut self, session: &str, full: bool, row: &Value) -> Change {
        let shape = shape_of(row);
        if let Some(sent) = self.rows.get_mut(session)
            && sent.full == full
        {
            let patch = diff(&sent.shape, row).unwrap_or_else(|| json!({}));
            sent.row_seq += 1;
            sent.shape = shape;
            return Change::Patch { patch, row_seq: sent.row_seq };
        }
        let row_seq = self.rows.get(session).map_or(1, |sent| sent.row_seq + 1);
        if self.rows.len() >= MAX_ROWS
            && !self.rows.contains_key(session)
            && let Some(gone) = self.rows.keys().next().cloned()
        {
            self.rows.remove(&gone);
        }
        self.rows.insert(session.to_owned(), Sent { full, row_seq, shape });
        Change::Whole { row_seq }
    }

    /// The chat is gone (purged): its next row, under the same id, goes out whole.
    pub(crate) fn forget(&mut self, session: &str) {
        self.rows.remove(session);
    }
}

/// Sends `conn` the change of `key`'s row to `row` (`full`: with its tools), when it asked for
/// patches: the whole row as `session_changed` with its `rowSeq`, or `session_patch`. `notice` is
/// the notification's other fields. False, with nothing sent, for a connection that did not ask:
/// the caller sends the whole row as before.
pub(super) fn send_row(conn: &Conn, key: &str, full: bool, row: &Value, notice: Value) -> bool {
    if !conn.session_delta.load(Ordering::SeqCst) {
        return false;
    }
    let change = conn.sent_rows.lock_or_recover().change(key, full, row);
    let Value::Object(mut params) = notice else { return false };
    match change {
        Change::Whole { row_seq } => {
            params.insert("session".into(), row.clone());
            params.insert("rowSeq".into(), json!(row_seq));
            conn.send(&Message::notification(method::MUX_SESSION_CHANGED, Value::Object(params)));
        }
        Change::Patch { patch, row_seq } => {
            params.insert("patch".into(), patch);
            params.insert("rowSeq".into(), json!(row_seq));
            params.insert("baseRowSeq".into(), json!(row_seq - 1));
            conn.send(&Message::notification(method::MUX_SESSION_PATCH, Value::Object(params)));
        }
    }
    true
}

/// `key`'s chat is gone from `conn`'s view: its next row goes out whole.
pub(super) fn forget(conn: &Conn, key: &str) {
    if conn.session_delta.load(Ordering::SeqCst) {
        conn.sent_rows.lock_or_recover().forget(key);
    }
}

/// Whether a connection hears row changes as patches: it asked in its `initialize`
/// (`_meta.acpmux.sessionChangedDelta: true`) and reads raw text. A patch is diffed from the raw
/// row, and the peer masker (`peer_text.rs`) knows a summary only whole, so a masked connection
/// always gets whole, masked rows.
pub(super) fn allowed(initialize: &Value, raw_text: bool) -> bool {
    raw_text
        && initialize.pointer("/_meta/acpmux/sessionChangedDelta").and_then(Value::as_bool)
            == Some(true)
}

#[cfg(test)]
#[path = "session_patch_tests.rs"]
mod tests;
