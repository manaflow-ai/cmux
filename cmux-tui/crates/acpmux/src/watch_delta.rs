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
//!
//! Rows travel from the link to the hub as their compact JSON text (`PeerNotice::Sessions`), and
//! `Known` holds the same text: a delta made whole shares each kept row, and the hub parses one
//! row at a time. 26 peers of 400 rows reconnecting at once held every row parsed, 414 MB.

use serde_json::value::RawValue;
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::sync::Arc;

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

/// A row's `sessionId`, read from its text without building the row.
fn id_of_text(text: &str) -> Option<String> {
    #[derive(serde::Deserialize)]
    struct Id {
        #[serde(rename = "sessionId")]
        session_id: Option<String>,
    }
    serde_json::from_str::<Id>(text).ok()?.session_id
}

/// The delta reply to `known` of a whole list `list` (`{"sessions": [...]}`, as the link reads
/// it): the rows new or changed, the known ids gone, and how many are unchanged. None if
/// `list` is not such a list.
///
/// Read row by row (rework stage 3, the heap attribution of 2026-11-12): each row stays the text
/// it is in `list`, and only its `sessionId` is parsed, so a delta holds one row's parse at a
/// time, not a `Value` of the whole list (about 6 times its text: 270 MB for a 42 MB list), once
/// per reconnecting peer. A row's digest is of its text; the own list is serde_json's compact
/// output with its keys sorted, which is what [`digest`] hashes, and a row whose text differed
/// would only be sent again. The reply is byte for byte the one the parsed list made.
pub fn delta(list: &str, known: &Map<String, Value>) -> Option<String> {
    #[derive(serde::Deserialize)]
    struct List<'a> {
        #[serde(borrow)]
        sessions: Vec<&'a RawValue>,
    }
    #[derive(serde::Deserialize)]
    struct Row {
        #[serde(rename = "sessionId")]
        session_id: Option<Value>,
    }
    /// Its fields in the order `json!` sorted them in.
    #[derive(serde::Serialize)]
    struct Reply<'a> {
        delta: bool,
        removed: Vec<&'a str>,
        sessions: Vec<&'a RawValue>,
        unchanged: usize,
    }
    let list: List<'_> = serde_json::from_str(list).ok()?;
    let mut ids = Vec::with_capacity(list.sessions.len());
    let mut sessions = Vec::new();
    for row in &list.sessions {
        let id = serde_json::from_str::<Row>(row.get())
            .ok()
            .and_then(|r| r.session_id)
            .and_then(|id| id.as_str().map(str::to_owned));
        let Some(id) = id else {
            sessions.push(*row);
            continue;
        };
        let held = known.get(&id).and_then(Value::as_str);
        if held.is_none_or(|held| held != digest_text(row.get())) {
            sessions.push(*row);
        }
        ids.push(id);
    }
    let listed: HashSet<&str> = ids.iter().map(String::as_str).collect();
    let removed: Vec<&str> =
        known.keys().map(String::as_str).filter(|id| !listed.contains(id)).collect();
    let unchanged = list.sessions.len().saturating_sub(sessions.len());
    serde_json::to_string(&Reply { delta: true, removed, sessions, unchanged }).ok()
}

/// The rows a link last read of its peer's list, each with its digest. It is empty until the
/// link reads a whole list, and then a delta is asked for. A delta is made whole again from
/// these rows, so the hub replaces the peer's rows as it does for any whole list. It must: it
/// marks them stale while the link is down. A digest the daemon still lists means its row is
/// the one kept here, whatever `session_changed` came between. Each row is kept as its compact
/// JSON, about as many bytes as the list itself, shared with the lists sent to the hub.
#[derive(Debug, Default)]
pub struct Known {
    rows: HashMap<String, (String, Arc<str>)>,
}

impl Known {
    /// `text` is the row's compact JSON (`serde_json::to_string`), as its digest is of.
    fn held(text: &Arc<str>) -> Option<(String, (String, Arc<str>))> {
        let id = id_of_text(text)?;
        Some((id, (digest_text(text), text.clone())))
    }

    /// A whole list was read: exactly its rows.
    pub fn listed(&mut self, rows: &[Arc<str>]) {
        self.rows = rows.iter().filter_map(Self::held).collect();
    }

    /// A delta was read: the whole list it stands for, its rows in place of theirs and its
    /// removed ids gone. A kept row is the text held here, shared, never parsed again.
    pub fn patched(&mut self, rows: Vec<Arc<str>>, removed: &[String]) -> Vec<Arc<str>> {
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
        whole.extend(kept.map(|(_, (_, text))| text.clone()));
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

/// A delta reply's removed ids; None for a whole list. Its rows are read with the list's
/// (`peer.rs` `watch_sessions`), not copied here.
pub fn read_delta(reply: &Value) -> Option<Vec<String>> {
    if reply.get("delta").and_then(Value::as_bool) != Some(true) {
        return None;
    }
    let removed = reply
        .get("removed")
        .and_then(Value::as_array)
        .map(|ids| ids.iter().filter_map(Value::as_str).map(str::to_owned).collect::<Vec<_>>());
    Some(removed.unwrap_or_default())
}

#[cfg(test)]
#[path = "watch_delta_tests.rs"]
mod tests;

#[cfg(all(test, target_os = "linux"))]
#[path = "watch_delta_bench.rs"]
mod watch_delta_bench;
