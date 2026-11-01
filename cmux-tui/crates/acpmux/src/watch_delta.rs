//! Deltas of a peer link's watch list, not the whole list again on every reconnect (Leo,
//! 2026-10-31: "why are we not following protocol/transport best practices"). A fleet daemon
//! lists its ~3,700 sessions at 2-4 KB each, and a link that dropped for a few seconds read all
//! of them again, though only a handful had changed.
//!
//! A link that read a whole list keeps a [`Known`] digest of every row it holds of that peer.
//! When it reconnects to a daemon that lists [`FEATURE`] and serves it as a peer, its
//! `_acpmux/watch` carries `known: {sessionId: digest}`, and the reply has `delta: true`:
//! `sessions` holds only the rows that are new or whose digest differs, and `removed` the known
//! ids the daemon no longer lists. A daemon that never heard of the field (every build before
//! this one) ignores it and answers the whole list, as before.
//!
//! A digest is the SHA-256 (first 8 bytes) of the row's compact JSON, `serde_json` keys in
//! their sorted order, on both sides, from the row as the peer reads it (masked for a peer that
//! is). Equal digests mean equal rows. If two builds serialize a row differently, the digests
//! differ and the row is just sent again. The link makes every delta whole from the rows it
//! kept (`Known`), and the hub replaces the peer's rows with that whole list, so a row it
//! learned of only from a `session_changed` and the daemon no longer lists goes, as with any
//! whole list.

use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};

/// The `initialize` feature of a daemon that answers `known` with a delta.
pub const FEATURE: &str = "watchDelta";

/// A row's digest: hex of the first 8 bytes of SHA-256 of its compact JSON.
pub fn digest(row: &Value) -> String {
    digest_text(&serde_json::to_string(row).unwrap_or_default())
}

fn digest_text(text: &str) -> String {
    Sha256::digest(text.as_bytes()).iter().take(8).map(|b| format!("{b:02x}")).collect()
}

fn id_of(row: &Value) -> Option<&str> {
    row.get("sessionId").and_then(Value::as_str)
}

/// The delta reply to `known` of a whole list `list` (`{"sessions": [...]}`, as the link reads
/// it): the rows new or changed, the known ids gone, and how many are unchanged. None if
/// `list` is not such a list.
pub fn delta(list: &str, known: &Map<String, Value>) -> Option<String> {
    let list: Value = serde_json::from_str(list).ok()?;
    let rows = list.get("sessions")?.as_array()?;
    let mut listed = HashSet::new();
    let mut sessions = Vec::new();
    for row in rows {
        let Some(id) = id_of(row) else {
            sessions.push(row);
            continue;
        };
        listed.insert(id);
        let held = known.get(id).and_then(Value::as_str);
        if held.is_none_or(|held| held != digest(row)) {
            sessions.push(row);
        }
    }
    let removed: Vec<&str> =
        known.keys().map(String::as_str).filter(|id| !listed.contains(id)).collect();
    let unchanged = rows.len().saturating_sub(sessions.len());
    Some(
        json!({"sessions": sessions, "removed": removed, "unchanged": unchanged, "delta": true})
            .to_string(),
    )
}

/// The rows a link last read of its peer's list, each with its digest. It is empty until the
/// link reads a whole list, and then a delta is asked for. A delta is made whole again from
/// these rows, so the hub replaces the peer's rows as it does for any whole list. It must: it
/// marks them stale while the link is down. A digest the daemon still lists means its row is
/// the one kept here, whatever `session_changed` came between. Each row is kept as its compact
/// JSON, about as many bytes as the list itself.
#[derive(Debug, Default)]
pub struct Known {
    rows: HashMap<String, (String, Box<str>)>,
}

impl Known {
    fn held(row: &Value) -> Option<(String, (String, Box<str>))> {
        let id = id_of(row)?.to_owned();
        let text = serde_json::to_string(row).ok()?;
        Some((id, (digest_text(&text), text.into_boxed_str())))
    }

    /// A whole list was read: exactly its rows.
    pub fn listed(&mut self, rows: &[Value]) {
        self.rows = rows.iter().filter_map(Self::held).collect();
    }

    /// A delta was read: the whole list it stands for, its rows in place of theirs and its
    /// removed ids gone.
    pub fn patched(&mut self, rows: Vec<Value>, removed: &[String]) -> Vec<Value> {
        for id in removed {
            self.rows.remove(id);
        }
        let mut sent = HashSet::new();
        for row in &rows {
            if let Some((id, held)) = Self::held(row) {
                sent.insert(id.clone());
                self.rows.insert(id, held);
            }
        }
        let mut whole = rows;
        let kept = self.rows.iter().filter(|(id, _)| !sent.contains(id.as_str()));
        whole.extend(kept.filter_map(|(_, (_, text))| serde_json::from_str(text).ok()));
        whole
    }

    pub fn is_empty(&self) -> bool {
        self.rows.is_empty()
    }

    /// The `known` of a watch request: every id with its digest.
    pub fn to_param(&self) -> Value {
        let rows = self.rows.iter().map(|(id, (digest, _))| (id.clone(), json!(digest)));
        Value::Object(rows.collect())
    }
}

/// A delta reply's rows and removed ids; None for a whole list.
pub fn read_delta(reply: &Value) -> Option<(Vec<Value>, Vec<String>)> {
    if reply.get("delta").and_then(Value::as_bool) != Some(true) {
        return None;
    }
    let rows = reply.get("sessions").and_then(Value::as_array).cloned().unwrap_or_default();
    let removed = reply
        .get("removed")
        .and_then(Value::as_array)
        .map(|ids| ids.iter().filter_map(Value::as_str).map(str::to_owned).collect::<Vec<_>>());
    Some((rows, removed.unwrap_or_default()))
}

#[cfg(test)]
#[path = "watch_delta_tests.rs"]
mod tests;
