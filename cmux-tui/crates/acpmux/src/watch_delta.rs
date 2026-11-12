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
//! The daemon makes each row's form as the link reads it (masked for a peer, `peer_text.rs`) and
//! its digest once, while the row's bytes stay the same ([`RowCache`]), and keeps them with the
//! list ([`Listed`]): a delta is cut from them with no parse and no hash. Before, every peer's
//! reconnect parsed the whole list, masked it and hashed every row again, on a runtime worker;
//! about 30 peers each did on every reconnect.

use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::ops::Range;
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

/// A whole list as the link reads it (`{"sessions": [...]}`), with where each row is and its
/// digest: what [`Listed::delta`] cuts a delta from.
pub struct Listed {
    pub text: Arc<String>,
    rows: Vec<ListedRow>,
}

struct ListedRow {
    id: Option<Arc<str>>,
    span: Range<usize>,
    digest: Arc<str>,
}

impl Listed {
    /// The delta reply to `known` of this list: the rows new or changed, the known ids gone, and
    /// how many are unchanged, as [`delta`] makes it of the list's text.
    pub fn delta(&self, known: &Map<String, Value>) -> String {
        let mut listed = HashSet::new();
        let mut sessions = Vec::new();
        for row in &self.rows {
            let text = self.text.get(row.span.clone()).unwrap_or("null");
            let Some(id) = row.id.as_deref() else {
                sessions.push(text);
                continue;
            };
            listed.insert(id);
            let held = known.get(id).and_then(Value::as_str);
            if held.is_none_or(|held| held != &*row.digest) {
                sessions.push(text);
            }
        }
        let removed: Vec<&str> =
            known.keys().map(String::as_str).filter(|id| !listed.contains(id)).collect();
        let unchanged = self.rows.len().saturating_sub(sessions.len());
        let removed = serde_json::to_string(&removed).unwrap_or_else(|_| "[]".to_owned());
        let rows: usize = sessions.iter().map(|row| row.len().saturating_add(1)).sum();
        let mut text = String::with_capacity(rows + removed.len() + 64);
        text.push_str("{\"delta\":true,\"removed\":");
        text.push_str(&removed);
        text.push_str(",\"sessions\":[");
        text.push_str(&sessions.join(","));
        text.push_str("],\"unchanged\":");
        text.push_str(&unchanged.to_string());
        text.push('}');
        text
    }
}

/// Every row of one list form as it was last made, by session id: its bytes as built, its text as
/// the link reads it, and that text's digest. A row whose bytes are the same as last time costs a
/// compare; only a new or changed row is parsed, masked and hashed. It holds the rows of the last
/// list made, no others: about two copies of that list's bytes.
#[derive(Default)]
pub struct RowCache {
    rows: HashMap<Arc<str>, CachedRow>,
}

struct CachedRow {
    built: Box<str>,
    read: Arc<str>,
    digest: Arc<str>,
}

impl RowCache {
    /// The list of `rows` (each its session id and its bytes as built, in list order), each read
    /// through `read` (a row's text as the link reads it; None: its bytes as built), the read form
    /// and digest of a row whose bytes are unchanged reused. Afterwards the cache holds exactly
    /// these rows.
    pub fn listed<'a>(
        &mut self,
        rows: impl IntoIterator<Item = (Option<&'a str>, &'a str)>,
        read: Option<&dyn Fn(Value) -> String>,
    ) -> Listed {
        let mut kept = HashMap::with_capacity(self.rows.len());
        let mut text = String::from("{\"sessions\":[");
        let mut listed = Vec::new();
        for (id, built) in rows {
            let cached = id
                .and_then(|id| self.rows.remove_entry(id))
                .filter(|(_, row)| *row.built == *built);
            let (id, row) = match cached {
                Some((id, row)) => (Some(id), row),
                None => {
                    // The digest the link makes of the row it parsed: of its compact JSON.
                    let value: Value = serde_json::from_str(built).unwrap_or_default();
                    let (read, digest): (Arc<str>, String) = match read {
                        Some(read) => {
                            let text = read(value);
                            let digest = digest_text(&text);
                            (text.into(), digest)
                        }
                        None => (built.into(), digest(&value)),
                    };
                    (
                        id.map(Arc::from),
                        CachedRow { built: built.into(), read, digest: digest.into() },
                    )
                }
            };
            if !listed.is_empty() {
                text.push(',');
            }
            let start = text.len();
            text.push_str(&row.read);
            listed.push(ListedRow {
                id: id.clone(),
                span: start..text.len(),
                digest: row.digest.clone(),
            });
            if let Some(id) = id {
                kept.insert(id, row);
            }
        }
        text.push_str("]}");
        self.rows = kept;
        Listed { text: Arc::new(text), rows: listed }
    }
}

/// The delta reply to `known` of a whole list `list` (`{"sessions": [...]}`, as the link reads
/// it): the rows new or changed, the known ids gone, and how many are unchanged. None if
/// `list` is not such a list. The daemon cuts it from a [`Listed`]; this is the same reply made
/// from the text, for a test's daemon.
#[cfg(test)]
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
