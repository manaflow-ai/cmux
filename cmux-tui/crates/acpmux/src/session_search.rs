//! `_acpmux/session_search {sessionId, query, role?, sinceMs?, limit?}` (HQ#6365): the messages of
//! one session that hold every word of `query`, newest first: `{sessionId, hits: [{seq, at, role,
//! snippet}], entries, tookMs}`. `role` is `user` (a prompt), `assistant` (the agent's reply text,
//! its chunks joined into one message) or `tool` (a tool call's title); `seq` is the log record the
//! message starts at.
//!
//! Words match as `_acpmux/chats_search`'s do ([`Needle`]): every word, any case and order, within
//! one message. Raw grep over the log cannot find a sentence: the agent's text is logged a few
//! words per `agent_message_chunk` record. A file store keeps each segment's messages in a text
//! copy beside the log (`store/text_index.rs`), so a search reads those and only the log bytes
//! appended since, never the whole log again.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::chats::search::{Needle, flatten, snippet};
use crate::store::{EventRecord, Store};

/// One message's indexed text is at most this many bytes; the rest is left out.
pub const MAX_TEXT: usize = 64 * 1024;
/// Hits returned when the query names no limit, and the most it may name.
pub const DEFAULT_LIMIT: usize = 20;
pub const MAX_LIMIT: usize = 200;

/// The record kinds a message is read from, or that end the agent's message being written.
pub const KINDS: &[&str] =
    &["user_message", "agent_message_chunk", "tool_call", "turn_started", "turn_result"];

/// Who a message is from.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    User,
    Assistant,
    Tool,
}

impl Role {
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "user" => Some(Self::User),
            "assistant" => Some(Self::Assistant),
            "tool" => Some(Self::Tool),
            _ => None,
        }
    }
}

/// One searchable message: where it starts in the log, and its text.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Entry {
    pub seq: u64,
    pub at: u64,
    pub role: Role,
    pub text: String,
}

/// Turns log records, in order, into [`Entry`]s. The agent's chunks join into one message until
/// another `messageId`, a prompt, a tool call or a turn's start or end.
#[derive(Debug, Default)]
pub struct Projector {
    pub entries: Vec<Entry>,
    /// The `messageId` ("" when the chunks carry none) of the last entry while it still takes
    /// chunks.
    pub open: Option<String>,
}

impl Projector {
    pub fn feed(&mut self, rec: &EventRecord) {
        if rec.kind.ends_with(".replay") {
            return;
        }
        match rec.kind.as_str() {
            "user_message" => {
                self.open = None;
                if let Some(text) = rec.msg.get("text").and_then(Value::as_str) {
                    self.push(rec, Role::User, text);
                }
            }
            "agent_message_chunk" if rec.dir == "in" => {
                let Some(params) = rec.msg.get("params") else { return };
                // A subagent's text is the subagent's, as the transcript leaves it out.
                if crate::subagents::is_subagents(params) {
                    return;
                }
                let Some(text) = params.pointer("/update/content/text").and_then(Value::as_str)
                else {
                    return;
                };
                let id =
                    params.pointer("/update/messageId").and_then(Value::as_str).unwrap_or_default();
                if self.open.as_deref() == Some(id)
                    && let Some(last) = self.entries.last_mut()
                {
                    push_capped(&mut last.text, text);
                } else {
                    self.push(rec, Role::Assistant, text);
                    self.open = Some(id.to_owned());
                }
            }
            "tool_call" if rec.dir == "in" => {
                let Some(params) = rec.msg.get("params") else { return };
                if crate::subagents::is_subagents(params) {
                    return;
                }
                self.open = None;
                if let Some(title) = params.pointer("/update/title").and_then(Value::as_str) {
                    self.push(rec, Role::Tool, title);
                }
            }
            "turn_started" | "turn_result" => self.open = None,
            _ => {}
        }
    }

    fn push(&mut self, rec: &EventRecord, role: Role, text: &str) {
        let mut entry = Entry { seq: rec.seq, at: rec.at, role, text: String::new() };
        push_capped(&mut entry.text, text);
        self.entries.push(entry);
    }
}

/// `text` appended to `to` up to [`MAX_TEXT`] bytes, cut at a character boundary.
fn push_capped(to: &mut String, text: &str) {
    let room = MAX_TEXT.saturating_sub(to.len());
    if text.len() <= room {
        to.push_str(text);
        return;
    }
    let mut end = room;
    while end > 0 && !text.is_char_boundary(end) {
        end = end.saturating_sub(1);
    }
    to.push_str(text.get(..end).unwrap_or_default());
}

/// What one search asks.
#[derive(Debug)]
pub struct Query {
    pub needle: Needle,
    pub role: Option<Role>,
    pub since_ms: Option<u64>,
    pub limit: usize,
}

impl Query {
    /// The query in `_acpmux/session_search`'s params.
    pub fn from_params(params: &Value) -> Result<Self, String> {
        let text = params.get("query").and_then(Value::as_str).ok_or("query must be a string")?;
        let needle = Needle::parse(text)?;
        let role = match params.get("role") {
            None | Some(Value::Null) => None,
            Some(v) => Some(
                v.as_str().and_then(Role::parse).ok_or("role must be user, assistant or tool")?,
            ),
        };
        let since_ms = match params.get("sinceMs") {
            None | Some(Value::Null) => None,
            Some(v) => Some(v.as_u64().ok_or("sinceMs must be a number of ms since the epoch")?),
        };
        let limit = match params.get("limit") {
            None | Some(Value::Null) => DEFAULT_LIMIT,
            Some(v) => {
                let n = v.as_u64().filter(|n| *n > 0).ok_or("limit must be a positive number")?;
                usize::try_from(n).unwrap_or(MAX_LIMIT).min(MAX_LIMIT)
            }
        };
        Ok(Self { needle, role, since_ms, limit })
    }
}

/// The newest `query.limit` messages of session `id` that match, as `_acpmux/session_search`
/// answers.
pub fn search(store: &dyn Store, id: &str, query: &Query) -> anyhow::Result<Value> {
    let started = std::time::Instant::now();
    // Messages come oldest first: only the newest `limit` hits are kept, each as its snippet, so
    // a search holds at most `limit` snippets however many messages match.
    let mut hits: std::collections::VecDeque<Value> = std::collections::VecDeque::new();
    let mut entries = 0_u64;
    store.text_entries(id, &mut |entry: Entry| {
        entries = entries.saturating_add(1);
        if query.role.is_some_and(|r| r != entry.role)
            || query.since_ms.is_some_and(|since| entry.at < since)
        {
            return;
        }
        let flat = flatten(&entry.text);
        if let Some(at) = query.needle.find(&flat) {
            if hits.len() >= query.limit {
                hits.pop_front();
            }
            hits.push_back(json!({
                "seq": entry.seq,
                "at": entry.at,
                "role": entry.role,
                "snippet": snippet(&flat, at),
            }));
        }
    })?;
    let hits: Vec<Value> = hits.into_iter().rev().collect();
    Ok(json!({
        "sessionId": id,
        "hits": hits,
        "entries": entries,
        "tookMs": u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX),
    }))
}

#[cfg(test)]
#[path = "session_search_tests.rs"]
mod tests;
