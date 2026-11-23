//! The agent's answer to one prompt, read back from this machine's acpmux
//! (`diff.comments.list`'s thread replies): the prompt's `turn_result` names
//! the turn (`promptId`, `turnSeq`, `status`), and the agent's text is the
//! `agent_message_chunk` records between that turn's start and its result.
//! One acpmux session runs one turn at a time, so no other turn's text lies
//! between them. Two paged reads, each bounded: the results newest first,
//! back to the send's time, then the chunks of that one turn.

use std::time::Duration;

use serde_json::{Value, json};

use super::AcpmuxLink;
use super::agent_message_acpmux::info_params;

/// How long each acpmux call may take.
const CALL_TIMEOUT: Duration = Duration::from_secs(3);
/// Records per page.
const PAGE: u64 = 200;
/// The most result pages read looking for one prompt's turn.
const MAX_RESULT_PAGES: usize = 10;
/// The most chunk pages one reply reads.
const MAX_CHUNK_PAGES: usize = 20;
/// A turn_result older than the send by more than this ends the search.
const CLOCK_SLACK_MS: u64 = 60_000;
/// The longest reply text kept, in bytes.
pub(crate) const MAX_REPLY_BYTES: usize = 32 * 1024;

/// Where one prompt's turn stands in acpmux.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum TurnReply {
    /// No turn has ended for the prompt yet (queued or running).
    Pending,
    /// The turn ended: acpmux's `status` (`completed`, `failed`, `cancelled`)
    /// and the agent's text, cut to [`MAX_REPLY_BYTES`].
    Ended { status: String, text: String },
    /// acpmux is not running here, does not know the session, or did not answer.
    Unreadable,
}

impl crate::mux::Mux {
    /// The answer of acpmux session `session` to the prompt `prompt_id`,
    /// sent at `sent_ms` (Unix ms).
    pub(crate) fn acp_turn_reply(&self, session: &str, prompt_id: &str, sent_ms: u64) -> TurnReply {
        let Some(socket) = self.control_clients.agent_sessions.socket() else {
            return TurnReply::Unreadable;
        };
        let Ok(link) = AcpmuxLink::connect(&socket, |_| {}) else { return TurnReply::Unreadable };
        let reply = read_reply(
            |params| link.call("_acpmux/events", params, CALL_TIMEOUT).ok(),
            |session| link.call("_acpmux/info", info_params(session), CALL_TIMEOUT).ok(),
            session,
            prompt_id,
            sent_ms,
        );
        link.close();
        reply
    }
}

/// [`crate::mux::Mux::acp_turn_reply`] over any `events` and `info` calls,
/// for tests.
pub(crate) fn read_reply(
    events: impl Fn(Value) -> Option<Value>,
    info: impl Fn(&str) -> Option<Value>,
    session: &str,
    prompt_id: &str,
    sent_ms: u64,
) -> TurnReply {
    if info(session).and_then(|i| i.get("sessionId").cloned()) != Some(json!(session)) {
        return TurnReply::Unreadable;
    }
    let Some(result) = find_result(&events, session, prompt_id, sent_ms) else {
        return TurnReply::Unreadable;
    };
    let Some(result) = result else { return TurnReply::Pending };
    let status = result.pointer("/msg/status").and_then(Value::as_str).unwrap_or("completed");
    let start = result.pointer("/msg/turnSeq").and_then(Value::as_u64).unwrap_or(0);
    let end = result.get("seq").and_then(Value::as_u64).unwrap_or(0);
    let text = if start == 0 || end <= start {
        String::new()
    } else {
        match chunk_text(&events, session, start, end) {
            Some(text) => text,
            None => return TurnReply::Unreadable,
        }
    };
    TurnReply::Ended { status: status.to_owned(), text }
}

/// The `turn_result` record of `prompt_id`: `Some(None)` when none ended
/// since the send, `None` when acpmux did not answer.
fn find_result(
    events: &impl Fn(Value) -> Option<Value>,
    session: &str,
    prompt_id: &str,
    sent_ms: u64,
) -> Option<Option<Value>> {
    let mut before: Option<u64> = None;
    for _ in 0..MAX_RESULT_PAGES {
        let mut params = json!({"sessionId": session, "kinds": ["turn_result"], "limit": PAGE});
        if let Some(seq) = before {
            params["beforeSeq"] = json!(seq);
        }
        let page = events(params)?;
        let records = page.get("events").and_then(Value::as_array).cloned().unwrap_or_default();
        // A page is oldest first; read it newest first.
        for record in records.iter().rev() {
            if record.pointer("/msg/promptId").and_then(Value::as_str) == Some(prompt_id) {
                return Some(Some(record.clone()));
            }
            let at = record.get("at").and_then(Value::as_u64).unwrap_or(u64::MAX);
            if at.saturating_add(CLOCK_SLACK_MS) < sent_ms {
                return Some(None);
            }
        }
        let first = records.first().and_then(|r| r.get("seq")).and_then(Value::as_u64);
        match first {
            Some(seq) if seq > 1 && records.len() as u64 >= PAGE => before = Some(seq),
            _ => return Some(None),
        }
    }
    Some(None)
}

/// The agent's text in records after `start` and before `end`, cut to
/// [`MAX_REPLY_BYTES`]; `None` when acpmux did not answer.
fn chunk_text(
    events: &impl Fn(Value) -> Option<Value>,
    session: &str,
    start: u64,
    end: u64,
) -> Option<String> {
    let mut text = String::new();
    let mut after = start;
    for _ in 0..MAX_CHUNK_PAGES {
        let params = json!({"sessionId": session, "kinds": ["agent_message_chunk"],
                            "afterSeq": after, "limit": PAGE});
        let page = events(params)?;
        let records = page.get("events").and_then(Value::as_array).cloned().unwrap_or_default();
        for record in &records {
            let seq = record.get("seq").and_then(Value::as_u64).unwrap_or(u64::MAX);
            if seq >= end {
                return Some(text);
            }
            if let Some(part) =
                record.pointer("/msg/params/update/content/text").and_then(Value::as_str)
            {
                push_clipped(&mut text, part);
            }
            after = seq;
        }
        if records.len() as u64 != PAGE || text.len() >= MAX_REPLY_BYTES {
            return Some(text);
        }
    }
    Some(text)
}

/// Appends `part`, never past [`MAX_REPLY_BYTES`] nor inside a character.
fn push_clipped(text: &mut String, part: &str) {
    let room = MAX_REPLY_BYTES.saturating_sub(text.len());
    let mut cut = part.len().min(room);
    while !part.is_char_boundary(cut) {
        cut -= 1;
    }
    text.push_str(part.get(..cut).unwrap_or_default());
}

#[cfg(test)]
#[path = "turn_reply_acpmux_tests.rs"]
mod tests;
