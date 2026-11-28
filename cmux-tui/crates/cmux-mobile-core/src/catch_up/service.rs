//! The Mac's `catch-up` link service (`cmux-mobile-host/src/catch_up.rs`): one request and one
//! reply for what a wake would otherwise ask in separate calls (`list-workspaces`,
//! `_acpmux/watch`, one `_acpmux/attach` per chat). Leo, 2026-11-24: "the syncing can arguably
//! happen in the background too, so deltas can be sipped and maintained".
//!
//! [`request`] builds the channel's open args from the cursors the phone holds, [`read`] parses
//! the one reply frame, and [`Cursors::apply_catch_up`] moves the cursors of the surfaces it
//! answered. A surface the reply names in `cut` keeps its cursor, so the next wake asks for it
//! again. A Mac without the service refuses the open with [`UNKNOWN_SERVICE`]
//! ([`falls_back`]): the phone then asks by today's separate calls ([`super::plan`]).

use std::collections::BTreeMap;

use serde_json::{Map, Value, json};

use super::{Cursors, RECENT_CHATS, Reply, WAKE_BUDGET_BYTES, Wake};

/// The link service's name.
pub const SERVICE: &str = "catch-up";
/// The request and reply format this module speaks.
pub const VERSION: u64 = 1;
/// The close code of a Mac that has no `catch-up` service (`services.rs`).
pub const UNKNOWN_SERVICE: &str = "unknown_service";
/// Chats one catch-up reads (the Mac's `MAX_CHATS`); the rest wait for the next wake.
pub const MAX_CHATS: usize = 32;
/// The most `budgetBytes` the Mac honours.
pub const MAX_BUDGET_BYTES: u64 = 256 * 1024;

/// Whether a refused `catch-up` open means "ask by today's calls": the Mac predates the
/// service. Any other refusal (a timeout, a closed link) is retried as a catch-up next wake.
pub fn falls_back(code: &str) -> bool {
    code == UNKNOWN_SERVICE
}

/// What a wake asks for besides the cursors.
#[derive(Debug, Clone, PartialEq)]
pub struct Ask {
    pub wake: Wake,
    /// Bytes the chats may answer with; 0 asks for [`WAKE_BUDGET_BYTES`].
    pub budget: u64,
    /// The `known` object of the tree the phone draws (`list-workspaces-known-v1`: the
    /// `tree_revision` and the revisions beside it). None: built from the cursor's revision,
    /// and `{}` (the whole tree) when there is none.
    pub known: Option<Value>,
    /// The capabilities the phone's `daemon` line lists in `set-client-info` (`page-tabs-v1`
    /// and the rest), so the tree reads as on that line.
    pub capabilities: Vec<String>,
    /// Ask by `since` when the Mac lists the delta capability. Only a phone that merges a delta
    /// sets it: a delta applied as a whole tree would empty it.
    pub workspace_delta: bool,
    /// Chats to bring up, newest screenful first: the one on screen, then the ones the person
    /// opened most recently, with the last event the phone holds of each (None: the cursor's).
    pub chats: Vec<(String, Option<u64>)>,
    /// The chat event kinds the phone draws; empty leaves the Mac's default.
    pub chat_kinds: Vec<String>,
}

impl Ask {
    pub fn new(wake: Wake) -> Self {
        Self {
            wake,
            budget: 0,
            known: None,
            capabilities: Vec::new(),
            workspace_delta: false,
            chats: Vec::new(),
            chat_kinds: Vec::new(),
        }
    }
}

/// The `catch-up` channel's open args for `ask` from `cursors`.
pub fn request(cursors: &Cursors, ask: &Ask) -> Value {
    let (wake, first, recent) = match &ask.wake {
        Wake::Foreground { chat, .. } => ("foreground", chat.as_deref(), 0),
        Wake::Push { chat } => ("background", chat.as_deref(), RECENT_CHATS),
        Wake::Refresh => ("background", None, RECENT_CHATS),
    };
    let budget = if ask.budget == 0 { WAKE_BUDGET_BYTES } else { ask.budget.min(MAX_BUDGET_BYTES) };

    let mut workspaces = Map::new();
    let known = ask.known.clone().filter(Value::is_object).unwrap_or_else(|| {
        match &cursors.list.tree_revision {
            Some(revision) => json!({ "tree_revision": revision }),
            None => json!({}),
        }
    });
    workspaces.insert("known".into(), known);
    if ask.workspace_delta && cursors.workspace_delta {
        let (epoch, seq) = match (&cursors.list.tree_epoch, cursors.list.tree_seq) {
            (Some(epoch), Some(seq)) => (epoch.clone(), seq),
            _ => (String::new(), 0),
        };
        workspaces.insert("since".into(), json!({ "epoch": epoch, "seq": seq }));
    }
    if !ask.capabilities.is_empty() {
        workspaces.insert("capabilities".into(), json!(ask.capabilities));
    }

    let mut chat_list = Map::new();
    // A follow needs both halves of the cursor: a position of another daemon run means nothing.
    if let (Some(seq), Some(epoch)) = (cursors.list.list_seq, &cursors.list.list_epoch) {
        chat_list.insert("afterSeq".into(), json!(seq));
        chat_list.insert("listEpoch".into(), json!(epoch));
    }

    // The chat on screen, then the ones the app names, then (in the background) the ones the
    // person opened most recently: each once, at most [`MAX_CHATS`].
    let mut ids: Vec<(String, Option<u64>)> = Vec::new();
    let mut push = |id: &str, held: Option<u64>| {
        if !id.is_empty() && ids.len() < MAX_CHATS && !ids.iter().any(|(known, _)| known == id) {
            ids.push((id.to_string(), held));
        }
    };
    if let Some(id) = first {
        let held = ask.chats.iter().find(|(known, _)| known == id).and_then(|(_, seq)| *seq);
        push(id, held);
    }
    for (id, held) in &ask.chats {
        push(id, *held);
    }
    let mut by_recency: Vec<_> = cursors.chats.iter().collect();
    by_recency.sort_by(|a, b| b.1.opened_at.cmp(&a.1.opened_at).then(a.0.cmp(b.0)));
    for (id, _) in by_recency.into_iter().take(recent) {
        push(id, None);
    }
    let chats: Vec<Value> = ids
        .into_iter()
        .map(|(id, held)| {
            let last_seq =
                held.or_else(|| cursors.chats.get(&id).map(|cursor| cursor.last_seq)).unwrap_or(0);
            json!({ "sessionId": id, "lastSeq": last_seq, "first": "screenful" })
        })
        .collect();

    let mut args = json!({
        "v": VERSION,
        "wake": wake,
        "budgetBytes": budget,
        "workspaces": workspaces,
        "chatList": chat_list,
        "chats": chats,
    });
    if !ask.chat_kinds.is_empty() {
        args["chatKinds"] = json!(ask.chat_kinds);
    }
    args
}

/// What the reply said of the workspace tree.
#[derive(Debug, Clone, PartialEq)]
pub enum Workspaces {
    /// The whole tree: the daemon's `list-workspaces` `data`, as the `daemon` line answers it.
    Tree(Value),
    /// `known` was current: the tree the phone draws stands.
    Unchanged(Value),
    /// The entries changed since `since` (`delta: true`).
    Delta(Value),
}

impl Workspaces {
    pub fn data(&self) -> &Value {
        match self {
            Self::Tree(data) | Self::Unchanged(data) | Self::Delta(data) => data,
        }
    }

    fn of(data: Value) -> Self {
        if data.get("unchanged").and_then(Value::as_bool) == Some(true) {
            Self::Unchanged(data)
        } else if data.get("delta").and_then(Value::as_bool) == Some(true) {
            Self::Delta(data)
        } else {
            Self::Tree(data)
        }
    }
}

/// One chat's page: the `_acpmux/attach` result as the Mac read it.
#[derive(Debug, Clone, PartialEq)]
pub struct ChatPage {
    pub session_id: String,
    /// The attach result (`events`, `lastSeq`, `pageThrough`, `hasMore`, ...).
    pub page: Value,
    /// The last event the page holds (`pageThrough`, else `lastSeq`).
    pub through_seq: Option<u64>,
    pub has_more: bool,
    /// A newest-first page with older records behind it: the first seq it holds, where an
    /// ordinary `_acpmux/attach {beforeSeq}` pages on.
    pub older_before: Option<u64>,
}

/// The parsed reply.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Answer {
    pub workspaces: Option<Workspaces>,
    /// The `_acpmux/watch` result: a follow (`follow: true`, the rows changed and `gone`) or
    /// the list's first page (`sessions`, `nextCursor`; `reset` when the cursor was stale).
    pub chat_list: Option<Value>,
    pub chats: Vec<ChatPage>,
    /// The surfaces not answered (`workspaces`, `chatList`, `chats:<id>`): their cursors stay.
    pub cut: Vec<String>,
    pub cut_why: BTreeMap<String, String>,
    /// The relay position each surface's answered state reached (`relay`: `{surface: {epoch,
    /// seq}}`): where a relay catch-up ([`super::relay`]) resumes. Empty from a Mac that does not
    /// publish to the relay.
    pub relay_heads: BTreeMap<String, (u64, u64)>,
}

impl Answer {
    pub fn is_cut(&self, name: &str) -> bool {
        self.cut.iter().any(|cut| cut == name)
    }

    pub fn chat_cut(&self, session: &str) -> bool {
        self.cut.iter().any(|cut| cut.strip_prefix("chats:") == Some(session))
    }
}

/// Why a reply frame could not be read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReadError {
    NotJson(String),
    NotAnObject,
    /// A format this module does not speak.
    Version(Option<u64>),
}

impl std::fmt::Display for ReadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotJson(error) => write!(f, "catch-up reply is not JSON: {error}"),
            Self::NotAnObject => f.write_str("catch-up reply is not an object"),
            Self::Version(v) => write!(f, "catch-up reply version {v:?} is not {VERSION}"),
        }
    }
}

impl std::error::Error for ReadError {}

/// Reads the one reply frame.
pub fn read(bytes: &[u8]) -> Result<Answer, ReadError> {
    let value: Value =
        serde_json::from_slice(bytes).map_err(|error| ReadError::NotJson(error.to_string()))?;
    let Value::Object(mut reply) = value else { return Err(ReadError::NotAnObject) };
    let version = reply.get("v").and_then(Value::as_u64);
    if version != Some(VERSION) {
        return Err(ReadError::Version(version));
    }
    let cut: Vec<String> = match reply.remove("cut") {
        Some(Value::Array(names)) => {
            names.into_iter().filter_map(|name| name.as_str().map(str::to_string)).collect()
        }
        _ => Vec::new(),
    };
    let cut_why = match reply.remove("cutWhy") {
        Some(Value::Object(why)) => why
            .into_iter()
            .filter_map(|(name, reason)| reason.as_str().map(|reason| (name, reason.to_string())))
            .collect(),
        _ => BTreeMap::new(),
    };
    let relay_heads = match reply.remove("relay") {
        Some(Value::Object(heads)) => heads
            .into_iter()
            .filter_map(|(surface, head)| {
                let part = |key: &str| {
                    let value = head.get(key)?;
                    value.as_u64().or_else(|| value.as_str()?.parse().ok())
                };
                Some((surface, (part("epoch")?, part("seq")?)))
            })
            .collect(),
        _ => BTreeMap::new(),
    };
    let mut answer = Answer { cut, cut_why, relay_heads, ..Answer::default() };
    if !answer.is_cut("workspaces")
        && let Some(data) = reply.remove("workspaces").filter(Value::is_object)
    {
        answer.workspaces = Some(Workspaces::of(data));
    }
    if !answer.is_cut("chatList") {
        answer.chat_list = reply.remove("chatList").filter(Value::is_object);
    }
    if let Some(Value::Array(chats)) = reply.remove("chats") {
        for page in chats {
            let Some(session_id) = page.get("sessionId").and_then(Value::as_str) else { continue };
            if session_id.is_empty() || answer.chat_cut(session_id) {
                continue;
            }
            let seq = |key: &str| page.get(key).and_then(Value::as_u64);
            answer.chats.push(ChatPage {
                session_id: session_id.to_string(),
                through_seq: seq("pageThrough").or_else(|| seq("lastSeq")),
                has_more: page.get("hasMore").and_then(Value::as_bool) == Some(true),
                older_before: seq("olderBefore"),
                page,
            });
        }
    }
    Ok(answer)
}

impl Cursors {
    /// Moves the cursor of each surface `answer` answered past what it held. A cut surface,
    /// and a chat the reply left out (the phone may not see it), keep theirs.
    pub fn apply_catch_up(&mut self, answer: &Answer, now: u64) {
        if let Some(workspaces) = &answer.workspaces {
            let data = workspaces.data();
            let revision = data.get("tree_revision").and_then(Value::as_str).map(str::to_string);
            let delta = match (data.get("epoch").and_then(Value::as_str), data.get("seq")) {
                (Some(epoch), Some(seq)) => seq.as_u64().map(|seq| (epoch.to_string(), seq)),
                _ => None,
            };
            match (revision.or_else(|| self.list.tree_revision.clone()), delta) {
                (Some(revision), delta) => self.apply(Reply::Workspaces { revision, delta }, now),
                (None, Some((epoch, seq))) => {
                    // A delta with no revision to keep: only its position moves.
                    let same = self.list.tree_epoch.as_deref() == Some(epoch.as_str());
                    if !same || self.list.tree_seq.is_none_or(|known| seq > known) {
                        self.list.tree_seq = Some(seq);
                    }
                    self.list.tree_epoch = Some(epoch);
                }
                (None, None) => {}
            }
        }
        if let Some(list) = &answer.chat_list
            && let (Some(seq), Some(epoch)) = (
                list.get("listSeq").and_then(Value::as_u64),
                list.get("listEpoch").and_then(Value::as_str),
            )
        {
            if list.get("reset").and_then(Value::as_bool) == Some(true) {
                // The old position could not be followed: the new one stands, even if lower.
                self.list.list_seq = Some(seq);
                self.list.list_epoch = Some(epoch.to_string());
            } else {
                self.apply(
                    Reply::ChatList { through_seq: seq, list_epoch: epoch.to_string() },
                    now,
                );
            }
        }
        for chat in &answer.chats {
            if let Some(through_seq) = chat.through_seq {
                self.apply(Reply::Chat { session: chat.session_id.clone(), through_seq }, now);
            }
        }
    }
}

#[cfg(test)]
#[path = "service_tests.rs"]
mod tests;
