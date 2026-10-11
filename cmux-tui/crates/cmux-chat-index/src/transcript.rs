//! A chat's past turns, read on demand from the harness's own store (never cached): each
//! person prompt and the assistant text that answered it, for a client to show a chat that has
//! no ACP resume above a fresh session (cx-5esm). Tool calls, tool results and context a
//! harness injects in `<tags>` are left out.

use std::path::Path;

use serde_json::Value;

use crate::entry::AdapterKind;
use crate::lines::{contains, fold_lines, read_whole_json};
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

/// Whether `kind` has a transcript reader.
pub fn supported(kind: AdapterKind) -> bool {
    matches!(kind, AdapterKind::Droid | AdapterKind::Continue | AdapterKind::Amp)
}

/// The turns of the `kind` chat stored at `path` (its `ChatEntry::source_path`).
pub fn read_turns(kind: AdapterKind, path: &Path) -> Result<Vec<Turn>, TranscriptError> {
    let unreadable = |e: std::io::Error| TranscriptError::Unreadable(e.to_string());
    let mut turns = Turns::default();
    match kind {
        // JSONL: `{type:"message", timestamp, message:{role, content}}` per line.
        AdapterKind::Droid => {
            fold_lines(path, 0, |line| {
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
            let session =
                read_whole_json(path).map_err(unreadable)?.ok_or(TranscriptError::TooLarge)?;
            for item in session.get("history").and_then(Value::as_array).into_iter().flatten() {
                turns.add(item.get("message").unwrap_or(&Value::Null), None);
            }
        }
        // One JSON thread: `messages[]{role, content}`.
        AdapterKind::Amp => {
            let thread =
                read_whole_json(path).map_err(unreadable)?.ok_or(TranscriptError::TooLarge)?;
            for message in thread.get("messages").and_then(Value::as_array).into_iter().flatten() {
                turns.add(message, None);
            }
        }
        _ => return Err(TranscriptError::Unsupported),
    }
    Ok(turns.done())
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
                // Context a harness injects comes as `<tags>`, not as the person's words.
                let prompt = message_text(content, &["text", "input_text"])
                    .filter(|prompt| !prompt.starts_with('<'));
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
fn capped(text: String) -> String {
    match text.char_indices().nth(MAX_TEXT) {
        Some((at, _)) => {
            let mut cut = text[..at].to_owned();
            cut.push('…');
            cut
        }
        None => text,
    }
}
