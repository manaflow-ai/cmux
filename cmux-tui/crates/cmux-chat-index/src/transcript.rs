//! A chat's past turns, read on demand from the harness's own store (never cached): each
//! person prompt and the assistant text that answered it, for a client to show a chat that has
//! no ACP resume above a fresh session (cx-5esm). Tool calls, tool results and context a
//! harness injects in `<tags>` are left out.

use std::path::Path;

use rusqlite::types::ValueRef;
use serde_json::{Value, json};

use crate::entry::AdapterKind;
use crate::lines::{WHOLE_FILE_MAX, contains, fold_newest_lines, read_whole_json};
use crate::sqlite::{columns, open_read_only};
use crate::time::parse_rfc3339_ms;

/// One past exchange: the person's prompt and the assistant's answer text.
#[derive(Debug, Clone, PartialEq, Eq, Default, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Turn {
    pub prompt: String,
    pub answer: String,
    /// When the prompt was sent and the answer last written (ms since the epoch), when recorded.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub prompt_at: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub answer_at: Option<u64>,
}

/// At most this many turns (the newest), and this much text per prompt and per answer.
pub const MAX_TURNS: usize = 200;
pub const MAX_TEXT: usize = 20_000;

/// A JSONL store is read from its newest this many bytes (as adopt's reader reads a Claude Code or
/// Codex transcript), so one read is bounded however large the file is or however fast it grows.
const LINES_MAX: u64 = 64 << 20;

/// Why a chat's turns could not be read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TranscriptError {
    /// No transcript reader for this harness yet.
    Unsupported,
    /// The store file is past the size a whole-file read takes.
    TooLarge,
    /// The file could not be read.
    Unreadable(String),
}

impl TranscriptError {
    /// A stable name for clients (`transcript.<code>`).
    pub fn code(&self) -> &'static str {
        match self {
            Self::Unsupported => "unsupported",
            Self::TooLarge => "too_large",
            Self::Unreadable(_) => "unreadable",
        }
    }
}

impl std::fmt::Display for TranscriptError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unsupported => f.write_str("this harness's chats have no transcript reader"),
            Self::TooLarge => f.write_str("the chat's file is too large to read"),
            Self::Unreadable(e) => write!(f, "the chat's file could not be read: {e}"),
        }
    }
}

/// The turns of the `kind` chat `session_id` stored at `path` (its `ChatEntry::source_path`; a
/// SQLite store holds many chats).
pub fn read_turns(
    kind: AdapterKind,
    path: &Path,
    session_id: &str,
) -> Result<Vec<Turn>, TranscriptError> {
    let unreadable = |e: std::io::Error| TranscriptError::Unreadable(e.to_string());
    let mut turns = Turns::default();
    match kind {
        // JSONL: `{type:"message", timestamp, message:{role, content}}` per line.
        AdapterKind::Droid => {
            fold_newest_lines(path, LINES_MAX, |line| {
                if !contains(line, br#""type":"message""#) {
                    return;
                }
                let Ok(record) = serde_json::from_slice::<Value>(line) else { return };
                let at = record.get("timestamp").and_then(Value::as_str).and_then(parse_rfc3339_ms);
                turns.add(record.get("message").unwrap_or(&Value::Null), at);
            })
            .map_err(unreadable)?;
        }
        // One JSON file: `history[].message{role, content}`.
        AdapterKind::Continue => {
            let session = whole_json(path)?;
            for item in session.get("history").and_then(Value::as_array).into_iter().flatten() {
                turns.add(item.get("message").unwrap_or(&Value::Null), None);
            }
        }
        // One JSON thread: `messages[]{role, content}`.
        AdapterKind::Amp => {
            let thread = whole_json(path)?;
            for message in thread.get("messages").and_then(Value::as_array).into_iter().flatten() {
                turns.add(message, None);
            }
        }
        // v1: one JSON object, `chatMessages[]{role, content}`. v2/v3: JSONL events
        // `{type, timestamp, data}`, the prompt in `user.message` and the answer in
        // `assistant.message` (`data.content`, empty beside tool requests).
        AdapterKind::CopilotCli if path.extension().is_some_and(|ext| ext == "json") => {
            let file = whole_json(path)?;
            for message in file.get("chatMessages").and_then(Value::as_array).into_iter().flatten()
            {
                turns.add(message, None);
            }
        }
        AdapterKind::CopilotCli => {
            fold_newest_lines(path, LINES_MAX, |line| {
                let role = if contains(line, br#""type":"user.message""#) {
                    "user"
                } else if contains(line, br#""type":"assistant.message""#) {
                    "assistant"
                } else {
                    return;
                };
                let Ok(record) = serde_json::from_slice::<Value>(line) else { return };
                let content = record.pointer("/data/content").cloned().unwrap_or(Value::Null);
                let at = record.get("timestamp").and_then(Value::as_str).and_then(parse_rfc3339_ms);
                turns.add(&json!({"role": role, "content": content}), at);
            })
            .map_err(unreadable)?;
        }
        // One JSON object: `chatHistory[]{exchange{request_message, response_text}, finishedAt}`;
        // a prompt may be only in its first text node (`request_nodes[type 0].text_node`). An
        // exchange with no prompt is skipped, so its answer never lands on the turn before.
        AdapterKind::Auggie => {
            let file = whole_json(path)?;
            for item in file.get("chatHistory").and_then(Value::as_array).into_iter().flatten() {
                let exchange = item.get("exchange").unwrap_or(&Value::Null);
                let at = item.get("finishedAt").and_then(Value::as_str).and_then(parse_rfc3339_ms);
                let Some(prompt) = auggie_prompt(exchange) else { continue };
                let answer = exchange.get("response_text").cloned().unwrap_or(Value::Null);
                turns.add(&json!({"role": "user", "content": prompt}), at);
                turns.add(&json!({"role": "assistant", "content": answer}), at);
            }
        }
        // `sessions.db`: `messages{session_id, role, content_json, created_timestamp,
        // metadata_json}`, hidden rows (`userVisible: false`) left out. Legacy `<id>.jsonl`: a
        // metadata line, then `{role, created, content}` messages.
        AdapterKind::Goose if path.file_name().is_some_and(|name| name == "sessions.db") => {
            let rows = sqlite_rows(path, session_id, "content_json", "created_timestamp")?;
            for Row { role, content, at, metadata } in rows {
                let hidden = metadata
                    .and_then(|m| serde_json::from_str::<Value>(&m).ok())
                    .is_some_and(|m| m.get("userVisible") == Some(&Value::Bool(false)));
                let Some(content) = content.and_then(|c| serde_json::from_str::<Value>(&c).ok())
                else {
                    continue;
                };
                if !hidden {
                    turns.add(&json!({"role": role, "content": content}), at);
                }
            }
        }
        AdapterKind::Goose => {
            fold_newest_lines(path, LINES_MAX, |line| {
                let Ok(message) = serde_json::from_slice::<Value>(line) else { return };
                let at = message.get("created").and_then(Value::as_i64).map(seconds_ms);
                turns.add(&message, at);
            })
            .map_err(unreadable)?;
        }
        // `crush.db`: `messages{session_id, role, parts, created_at}`; a text part is
        // `{type:"text", data:{text, hidden?}}`.
        AdapterKind::Crush => {
            for Row { role, content: parts, at, .. } in
                sqlite_rows(path, session_id, "parts", "created_at")?
            {
                let parts: Value =
                    parts.and_then(|p| serde_json::from_str(&p).ok()).unwrap_or_default();
                let texts: Vec<Value> = parts
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter(|part| part.get("type").and_then(Value::as_str) == Some("text"))
                    .filter(|part| part.pointer("/data/hidden") != Some(&Value::Bool(true)))
                    .filter_map(|part| part.pointer("/data/text"))
                    .map(|text| json!({"type": "text", "text": text}))
                    .collect();
                turns.add(&json!({"role": role, "content": texts}), at);
            }
        }
        _ => return Err(TranscriptError::Unsupported),
    }
    Ok(turns.done())
}

/// An Auggie exchange's prompt: `request_message`, else its first text node.
fn auggie_prompt(exchange: &Value) -> Option<String> {
    let text = |value: Option<&Value>| {
        value.and_then(Value::as_str).map(str::trim).filter(|t| !t.is_empty()).map(str::to_owned)
    };
    text(exchange.get("request_message")).or_else(|| {
        exchange
            .get("request_nodes")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter(|node| node.get("type").and_then(Value::as_i64) == Some(0))
            .find_map(|node| text(node.pointer("/text_node/content")))
    })
}

/// At most this many of a chat's newest rows are read from a SQLite store, and a cell larger
/// than `MAX_CELL` is read as NULL (only tool output or a giant paste gets there).
const MAX_ROWS: usize = 2_000;
const MAX_CELL: usize = 128 * 1024;

/// One `messages` row of a SQLite store.
struct Row {
    role: String,
    content: Option<String>,
    /// Created (ms since the epoch).
    at: Option<i64>,
    metadata: Option<String>,
}

/// A chat's rows from a SQLite store's `messages`, oldest first: `content` and `time` name its
/// columns, and `metadata_json` is read where it exists.
fn sqlite_rows(
    path: &Path,
    session_id: &str,
    content: &str,
    time: &str,
) -> Result<Vec<Row>, TranscriptError> {
    let unreadable = |e: rusqlite::Error| TranscriptError::Unreadable(e.to_string());
    let conn = open_read_only(path).map_err(unreadable)?;
    let cols = columns(&conn, "messages").map_err(unreadable)?;
    if !["session_id", "role", content].iter().all(|c| cols.contains(*c)) {
        return Err(TranscriptError::Unreadable(format!("no messages.{content} column")));
    }
    let time = if cols.contains(time) { time } else { "NULL" };
    let metadata = if cols.contains("metadata_json") { "metadata_json" } else { "NULL" };
    let order = if time == "NULL" { "rowid" } else { "2" };
    let sql = format!(
        "SELECT role, {time}, CASE WHEN length({content}) > {MAX_CELL} THEN NULL ELSE {content} END, \
         {metadata} FROM messages WHERE session_id = ?1 ORDER BY {order} DESC, rowid DESC LIMIT {MAX_ROWS}"
    );
    let mut stmt = conn.prepare(&sql).map_err(unreadable)?;
    let mut rows: Vec<_> = stmt
        .query_map([session_id], |row| {
            Ok(Row {
                role: row.get::<_, Option<String>>(0)?.unwrap_or_default(),
                content: row.get(2)?,
                at: match row.get_ref(1)? {
                    ValueRef::Integer(value) => Some(seconds_ms(value)),
                    ValueRef::Text(text) => {
                        std::str::from_utf8(text).ok().and_then(parse_rfc3339_ms)
                    }
                    _ => None,
                },
                metadata: row.get(3)?,
            })
        })
        .map_err(unreadable)?
        .collect::<rusqlite::Result<_>>()
        .map_err(unreadable)?;
    rows.reverse();
    Ok(rows)
}

/// Seconds to milliseconds; a value already in milliseconds is kept.
fn seconds_ms(value: i64) -> i64 {
    if value > 100_000_000_000 { value } else { value.saturating_mul(1000) }
}

/// A whole-file JSON store: too large past `WHOLE_FILE_MAX`, unreadable when it is not JSON
/// (cut short mid-write, say).
fn whole_json(path: &Path) -> Result<Value, TranscriptError> {
    let unreadable = |e: std::io::Error| TranscriptError::Unreadable(e.to_string());
    if std::fs::metadata(path).map_err(unreadable)?.len() > WHOLE_FILE_MAX {
        return Err(TranscriptError::TooLarge);
    }
    read_whole_json(path)
        .map_err(unreadable)?
        .ok_or_else(|| TranscriptError::Unreadable("not JSON".into()))
}

#[derive(Default)]
struct Turns(Vec<Turn>);

impl Turns {
    /// A `{role, content}` message: a person's prompt starts a turn; assistant text answers it.
    fn add(&mut self, message: &Value, at: Option<i64>) {
        let at = at.and_then(|ms| u64::try_from(ms).ok());
        let content = message.get("content").unwrap_or(&Value::Null);
        match message.get("role").and_then(Value::as_str) {
            Some("user") => {
                // Context a harness injects comes as a whole `<tag>…</tag>` block, not as the
                // person's words (which may still start with markup).
                let prompt = message_text(content, &["text", "input_text"])
                    .filter(|prompt| !(prompt.starts_with('<') && prompt.ends_with('>')));
                if let Some(prompt) = prompt {
                    self.0.push(Turn { prompt: capped(prompt), prompt_at: at, ..Turn::default() });
                    // Only the newest turns are kept.
                    if self.0.len() > MAX_TURNS {
                        self.0.remove(0);
                    }
                }
            }
            Some("assistant") => {
                let (Some(turn), Some(text)) =
                    (self.0.last_mut(), message_text(content, &["text", "output_text"]))
                else {
                    return;
                };
                if !turn.answer.is_empty() {
                    turn.answer.push_str("\n\n");
                }
                turn.answer.push_str(&text);
                turn.answer = capped(std::mem::take(&mut turn.answer));
                turn.answer_at = at.or(turn.answer_at);
            }
            _ => {}
        }
    }

    fn done(self) -> Vec<Turn> {
        self.0
    }
}

/// The whole text of a message: a string, or its parts of the `kinds` types (a part with no
/// type counts). None for tool results and empty text.
fn message_text(content: &Value, kinds: &[&str]) -> Option<String> {
    let text = match content {
        Value::String(text) => text.clone(),
        Value::Array(parts) => {
            let is =
                |part: &Value, kind: &str| part.get("type").and_then(Value::as_str) == Some(kind);
            if parts.iter().any(|part| is(part, "tool_result")) {
                return None;
            }
            let texts: Vec<&str> = parts
                .iter()
                .filter(|part| {
                    part.get("type").is_none() || kinds.iter().any(|kind| is(part, kind))
                })
                .filter_map(|part| part.get("text").and_then(Value::as_str))
                .collect();
            texts.join("\n")
        }
        _ => return None,
    };
    let trimmed = text.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_owned())
}

/// `text` cut to `MAX_TEXT` characters.
pub fn capped(text: String) -> String {
    match text.char_indices().nth(MAX_TEXT) {
        Some((at, _)) => {
            let mut cut = text[..at].to_owned();
            cut.push('…');
            cut
        }
        None => text,
    }
}
