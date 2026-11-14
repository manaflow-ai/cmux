//! Part of `Hub`; see `hub/mod.rs`. A peer's session row as this daemon keeps it
//! (`RemoteSession::summary`): its JSON text, compact, and the few fields read hot (its id, name,
//! status, times, asks and tags pair), never a JSON tree. A tree of one row is several times its
//! text (a map per object, 640 bytes a leaf): the god fixture's mirrored rows held 166 MB of the
//! daemon's 229 MB heap peak as trees (2026-11-13). A list copies the text into its reply
//! ([`PeerRow::listed`]); a reader that needs the whole row parses it then ([`PeerRow::value`]).
//!
//! The members a list writes itself (`stale`, `peerState`) or leaves out or cuts without tools
//! (`tools`, `toolsMutable`, `title`), and `tags` (read on demand), are kept apart from the rest,
//! so a list writes the row with no parse and no member twice.

use super::*;
use serde_json::value::RawValue;

/// A member kept apart from the row's other text.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Apart {
    Stale,
    PeerState,
    Tags,
    Title,
    Tools,
    ToolsMutable,
}

impl Apart {
    fn of(key: &str) -> Option<Self> {
        Some(match key {
            "stale" => Self::Stale,
            "peerState" => Self::PeerState,
            "tags" => Self::Tags,
            "title" => Self::Title,
            "tools" => Self::Tools,
            "toolsMutable" => Self::ToolsMutable,
            _ => return None,
        })
    }

    fn key(self) -> &'static str {
        match self {
            Self::Stale => "stale",
            Self::PeerState => "peerState",
            Self::Tags => "tags",
            Self::Title => "title",
            Self::Tools => "tools",
            Self::ToolsMutable => "toolsMutable",
        }
    }
}

/// What the hot paths read of a row: paging (`page_first.rs`, `list_guard.rs`), lookups
/// (`peers.rs`, `locate.rs`, `key_route.rs`), the indexes (`remote_rows.rs`) and staleness
/// (`peer_cache.rs`).
#[derive(Clone, Debug, Default)]
struct Hot {
    session_id: Option<Box<str>>,
    name: Option<Box<str>>,
    status: Option<Box<str>>,
    peer: Option<Box<str>>,
    agent_session_id: Option<Box<str>>,
    family: Option<Box<str>>,
    harness: Option<Box<str>>,
    created_at: Option<u64>,
    updated_at: u64,
    pending: u64,
    last_seen: Option<u64>,
    stale: bool,
    /// Its `(mux.parent, mux.handle)` tags.
    pair: Option<(Box<str>, Box<str>)>,
}

impl Hot {
    fn of(summary: &Value) -> Self {
        let text = |key: &str| summary.get(key).and_then(Value::as_str).map(Box::from);
        let number = |key: &str| summary.get(key).and_then(Value::as_u64);
        Self {
            session_id: text("sessionId"),
            name: text("name"),
            status: text("status"),
            peer: text("peer"),
            agent_session_id: text("agentSessionId"),
            family: text("family"),
            harness: text("harness"),
            created_at: number("createdAt"),
            updated_at: number("updatedAt").unwrap_or_default(),
            pending: number("pendingPermissions").unwrap_or_default(),
            last_seen: number("lastSeen"),
            stale: summary.get("stale") == Some(&Value::Bool(true)),
            pair: pair_of(summary),
        }
    }
}

/// A row's `(mux.parent, mux.handle)` tags, as its summary lists them.
fn pair_of(summary: &Value) -> Option<(Box<str>, Box<str>)> {
    let tags = summary.get("tags")?;
    let tag = |key: &str| {
        tags.get(key)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|v| !v.is_empty())
            .map(Box::from)
    };
    Some((tag("mux.parent")?, tag("mux.handle")?))
}

#[derive(Clone, Debug, Default)]
pub struct PeerRow {
    /// `{...}`: every member but those kept apart, in the tree's order. A row that is not an
    /// object is its whole text.
    base: Box<str>,
    /// The members kept apart, each its value's text.
    apart: Box<[(Apart, Box<str>)]>,
    /// The title a list without tools shows (`views::without_summary_tools`), when it is cut.
    short_title: Option<Box<str>>,
    hot: Hot,
}

/// Two rows are the same when their text is: what changed detection compares.
impl PartialEq for PeerRow {
    fn eq(&self, other: &Self) -> bool {
        self.base == other.base && self.apart == other.apart
    }
}

impl From<Value> for PeerRow {
    fn from(summary: Value) -> Self {
        Self::new(&summary)
    }
}

/// JSON text of `value`, compact.
fn json_text(value: &impl serde::Serialize) -> String {
    let mut buf = Vec::new();
    let _ = serde_json::to_writer(&mut buf, value);
    String::from_utf8(buf).unwrap_or_default()
}

impl PeerRow {
    /// `summary`, packed.
    pub fn new(summary: &Value) -> Self {
        let hot = Hot::of(summary);
        let Some(map) = summary.as_object() else {
            return Self { base: json_text(summary).into(), hot, ..Self::default() };
        };
        let mut base = String::from("{");
        let mut apart = Vec::new();
        let mut short_title = None;
        for (key, value) in map {
            if let Some(which) = Apart::of(key) {
                if let (Apart::Title, Value::String(title)) = (which, value) {
                    let short = super::views::summary_title(title);
                    if short != *title {
                        short_title = Some(json_text(&short).into());
                    }
                }
                apart.push((which, json_text(value).into()));
                continue;
            }
            if base.len() > 1 {
                base.push(',');
            }
            base.push_str(&json_text(key));
            base.push(':');
            base.push_str(&json_text(value));
        }
        base.push('}');
        Self { base: base.into(), apart: apart.into(), short_title, hot }
    }

    /// The row as JSON text: every member, `stale` as `stale` says (else as kept), `peerState`
    /// as `peer_state` says (else as kept), and without tools (`tools`, `toolsMutable`, a long
    /// title cut) unless `tools`.
    fn text_with(&self, stale: Option<bool>, peer_state: Option<&str>, tools: bool) -> String {
        let Some(open) = self.base.strip_suffix('}') else {
            return self.base.to_string();
        };
        let extra: usize = self.apart.iter().map(|(_, v)| v.len() + 16).sum();
        let mut out = String::with_capacity(open.len() + extra + 48);
        out.push_str(open);
        let member = |out: &mut String, key: &str, value: &str| {
            if out.len() > 1 {
                out.push(',');
            }
            out.push('"');
            out.push_str(key);
            out.push_str("\":");
            out.push_str(value);
        };
        if let Some(stale) = stale {
            member(&mut out, "stale", if stale { "true" } else { "false" });
        }
        for (which, value) in self.apart.iter() {
            let value = match which {
                Apart::Stale if stale.is_some() => continue,
                Apart::PeerState if peer_state.is_some() => continue,
                Apart::Tools | Apart::ToolsMutable if !tools => continue,
                Apart::Title if !tools => self.short_title.as_ref().unwrap_or(value),
                _ => value,
            };
            member(&mut out, which.key(), value);
        }
        if let Some(state) = peer_state {
            member(&mut out, "peerState", &json_text(&state));
        }
        out.push('}');
        out
    }

    /// The row as a session list lists it (`peers::listed_remote_row`): `stale` always set,
    /// `peerState` its link's state when known, with tools only when `tools`. No parse.
    pub fn listed(&self, peer_state: Option<&str>, tools: bool) -> String {
        self.text_with(Some(self.hot.stale), peer_state, tools)
    }

    /// The whole row as JSON text.
    pub fn text(&self) -> String {
        self.text_with(None, None, true)
    }

    /// The whole row, parsed: for a reader that needs more than the hot fields.
    pub fn value(&self) -> Value {
        serde_json::from_str(&self.text()).unwrap_or(Value::Null)
    }

    /// Its `tags`, parsed.
    pub fn tags(&self) -> Option<Value> {
        let (_, text) = self.apart.iter().find(|(which, _)| *which == Apart::Tags)?;
        serde_json::from_str(text).ok()
    }

    /// Whether it carries tools (`tools` or `toolsMutable`).
    pub(super) fn has_tools(&self) -> bool {
        self.apart.iter().any(|(which, _)| matches!(which, Apart::Tools | Apart::ToolsMutable))
    }

    /// Its `tools` and `toolsMutable`, as kept.
    pub(super) fn tools(&self) -> impl Iterator<Item = (&'static str, Value)> + '_ {
        self.apart
            .iter()
            .filter(|(which, _)| matches!(which, Apart::Tools | Apart::ToolsMutable))
            .filter_map(|(which, text)| Some((which.key(), serde_json::from_str(text).ok()?)))
    }

    /// Marks it last-known (`peer_cache::mark_stale`): whether it changed.
    pub(super) fn mark_stale(&mut self, last_seen: Option<u64>) -> bool {
        if self.closed() {
            return false;
        }
        let mut summary = self.value();
        let changed = super::peer_cache::mark_stale(&mut summary, last_seen);
        if changed {
            *self = Self::new(&summary);
        }
        changed
    }

    pub fn session_id(&self) -> Option<&str> {
        self.hot.session_id.as_deref()
    }

    pub fn name(&self) -> Option<&str> {
        self.hot.name.as_deref()
    }

    pub fn status(&self) -> Option<&str> {
        self.hot.status.as_deref()
    }

    pub fn closed(&self) -> bool {
        self.status() == Some("closed")
    }

    pub fn peer(&self) -> Option<&str> {
        self.hot.peer.as_deref()
    }

    pub fn agent_session_id(&self) -> Option<&str> {
        self.hot.agent_session_id.as_deref()
    }

    /// Its `family`, else its `harness`.
    pub fn family(&self) -> Option<&str> {
        self.hot.family.as_deref().or(self.harness())
    }

    pub fn harness(&self) -> Option<&str> {
        self.hot.harness.as_deref()
    }

    pub fn created_at(&self) -> Option<u64> {
        self.hot.created_at
    }

    pub fn updated_ms(&self) -> u64 {
        self.hot.updated_at
    }

    pub fn pending_permissions(&self) -> u64 {
        self.hot.pending
    }

    pub fn last_seen(&self) -> Option<u64> {
        self.hot.last_seen
    }

    pub fn stale(&self) -> bool {
        self.hot.stale
    }

    /// Its `(mux.parent, mux.handle)` tags.
    pub fn pair(&self) -> Option<(String, String)> {
        self.hot.pair.as_ref().map(|(parent, handle)| (parent.to_string(), handle.to_string()))
    }
}

/// Written as the row's JSON (a peer cache's sessions, `peer_cache_disk.rs`), with no parse.
impl serde::Serialize for PeerRow {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let raw = RawValue::from_string(self.text()).map_err(serde::ser::Error::custom)?;
        raw.serialize(serializer)
    }
}

#[cfg(test)]
mod tests;
