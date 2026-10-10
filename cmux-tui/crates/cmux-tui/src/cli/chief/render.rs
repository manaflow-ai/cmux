//! Plain text of conversation messages, and wrapping by display width.

use serde_json::Value;
use unicode_width::UnicodeWidthChar;

use super::adapter::AGENT_MUX;
use super::messages::messages;

/// The text of a message's parts, one paragraph per part.
pub(super) fn message_text(message: &Value) -> String {
    let m = messages();
    if message.get("retracted_at").and_then(Value::as_str).is_some() {
        return m.retracted.into();
    }
    let parts = message.get("parts").and_then(Value::as_array).cloned().unwrap_or_default();
    let field =
        |part: &Value, key: &str| part.get(key).and_then(Value::as_str).unwrap_or("").to_owned();
    let pieces: Vec<String> = parts
        .iter()
        .map(|part| match part.get("type").and_then(Value::as_str) {
            Some("text") => field(part, "text"),
            Some("attachment") => m.attachment.replace("{name}", &field(part, "name")),
            Some("work") => {
                let line = m.work.replace("{status}", &field(part, "status"));
                match part.get("preview").and_then(Value::as_str) {
                    Some(preview) => format!("{line} {preview}"),
                    None => line,
                }
            }
            Some("question") => {
                let prompts: Vec<String> = part
                    .get("items")
                    .and_then(Value::as_array)
                    .map(|items| items.iter().map(|i| field(i, "prompt")).collect())
                    .unwrap_or_default();
                m.question.replace("{prompt}", &prompts.join(" / "))
            }
            _ => String::new(),
        })
        .filter(|piece| !piece.is_empty())
        .collect();
    pieces.join("\n\n")
}

/// Who wrote `message`, as the chat shows it: "You" for this person,
/// "Chief" for the Chief, else the participant's display name.
pub(super) fn author_name(message: &Value, participants: &[Value]) -> String {
    let m = messages();
    let author = message.get("author").and_then(Value::as_str).unwrap_or("");
    if author == AGENT_MUX {
        return m.chief.into();
    }
    if author == "user_local" {
        return m.you.into();
    }
    participants
        .iter()
        .find(|p| p.get("id").and_then(Value::as_str) == Some(author))
        .and_then(|p| p.get("display_name").and_then(Value::as_str))
        .unwrap_or(author)
        .to_owned()
}

/// `HH:MM` of an RFC 3339 time (UTC as stored), or empty.
pub(super) fn clock(message: &Value) -> String {
    let at = message.get("created_at").and_then(Value::as_str).unwrap_or("");
    at.get(11..16).unwrap_or("").to_owned()
}

/// Wraps `text` to `width` display columns: at spaces when it can, hard
/// otherwise; every input line break is kept.
pub(super) fn wrap(text: &str, width: usize) -> Vec<String> {
    let width = width.max(8);
    let mut out = Vec::new();
    for line in text.split('\n') {
        let line = line.trim_end_matches('\r');
        let mut current = String::new();
        let mut used = 0;
        for word in split_keep_spaces(line) {
            let w: usize = word.chars().map(|c| c.width().unwrap_or(0)).sum();
            if used + w <= width {
                current.push_str(word);
                used += w;
                continue;
            }
            if !current.trim().is_empty() {
                out.push(current.trim_end().to_owned());
            }
            current = String::new();
            used = 0;
            let word = if word.trim().is_empty() { "" } else { word };
            for c in word.chars() {
                let cw = c.width().unwrap_or(0);
                if used + cw > width {
                    out.push(std::mem::take(&mut current));
                    used = 0;
                }
                current.push(c);
                used += cw;
            }
        }
        out.push(current.trim_end().to_owned());
    }
    out
}

fn split_keep_spaces(line: &str) -> Vec<&str> {
    let mut pieces = Vec::new();
    let mut start = 0;
    for (index, c) in line.char_indices() {
        if c == ' ' {
            pieces.push(&line[start..index + 1]);
            start = index + 1;
        }
    }
    if start < line.len() {
        pieces.push(&line[start..]);
    }
    pieces
}
