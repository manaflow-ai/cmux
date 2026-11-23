//! A comment thread's reply: the answer of the agent's turn for the prompt a
//! comment was sent as, read from acpmux's log of the chat.
//!
//! The diff view, the browser pane and terminal selections all keep their
//! comments in the session host's comment store (`git_ops/diff_comments.rs`).
//! A send with `keep` leaves each comment there with a `thread` naming the
//! acpmux chat and prompt id it went out as; `diff.comments.list` then asks
//! acpmux how that prompt's turn ended and stores the answer on the comment,
//! so every surface shows the reply in the thread it was asked from.

use serde_json::Value;

/// The record kinds a reply read asks acpmux for.
pub(crate) const REPLY_KINDS: &[&str] = &["turn_started", "agent_message_chunk", "turn_result"];

/// The longest reply a thread keeps, in bytes; a longer one is cut at a
/// character boundary and marked.
pub(crate) const MAX_REPLY_BYTES: usize = 32 * 1024;

/// How the turn of one prompt stands in a chat's log.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum TurnReply {
    /// No ended turn for the prompt yet: queued, running, or older than the
    /// records read.
    Pending,
    /// The turn ended; the agent's text in it.
    Answered(String),
    /// The turn failed; its error, and whatever the agent said before.
    Failed(String),
}

/// The reply to `prompt_id` in `events` (oldest first, as `_acpmux/events`
/// pages them): the agent text of the turn whose `turn_result` names the
/// prompt, back to the turn's start.
pub(crate) fn turn_reply(events: &[Value], prompt_id: &str) -> TurnReply {
    let Some(end) = events.iter().rposition(|event| {
        kind(event) == "turn_result" && msg_str(event, "promptId") == Some(prompt_id)
    }) else {
        return TurnReply::Pending;
    };
    let start = events[..end]
        .iter()
        .rposition(|event| matches!(kind(event), "turn_started" | "turn_result"))
        .map_or(0, |index| index + 1);
    let mut text = String::new();
    for event in &events[start..end] {
        if kind(event) != "agent_message_chunk" {
            continue;
        }
        if let Some(chunk) =
            event.get("msg").and_then(|msg| msg.pointer("/params/update/content/text"))
        {
            text.push_str(chunk.as_str().unwrap_or_default());
        }
    }
    let text = clip(text.trim());
    let result = &events[end];
    if msg_str(result, "status") == Some("failed") {
        let error = msg_str(result, "errorText").unwrap_or("the agent's turn failed");
        let text = if text.is_empty() { error.to_owned() } else { format!("{text}\n\n{error}") };
        return TurnReply::Failed(clip(&text));
    }
    TurnReply::Answered(text)
}

fn kind(event: &Value) -> &str {
    event.get("kind").and_then(Value::as_str).unwrap_or_default()
}

fn msg_str<'a>(event: &'a Value, key: &str) -> Option<&'a str> {
    event.get("msg").and_then(|msg| msg.get(key)).and_then(Value::as_str)
}

fn clip(text: &str) -> String {
    if text.len() <= MAX_REPLY_BYTES {
        return text.to_owned();
    }
    let mut cut = MAX_REPLY_BYTES;
    while !text.is_char_boundary(cut) {
        cut -= 1;
    }
    format!("{}…", &text[..cut])
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn chunk(text: &str) -> Value {
        json!({"kind": "agent_message_chunk", "msg": {"params": {"update": {"content": {"text": text}}}}})
    }

    #[test]
    fn the_reply_is_the_text_of_the_prompts_own_turn() {
        let events = vec![
            json!({"kind": "turn_started", "msg": {"promptId": "a"}}),
            chunk("not this"),
            json!({"kind": "turn_result", "msg": {"promptId": "a"}}),
            json!({"kind": "turn_started", "msg": {"promptId": "b"}}),
            chunk("fixed "),
            chunk("the selector"),
            json!({"kind": "turn_result", "msg": {"promptId": "b"}}),
        ];
        assert_eq!(turn_reply(&events, "b"), TurnReply::Answered("fixed the selector".into()));
        assert_eq!(turn_reply(&events, "a"), TurnReply::Answered("not this".into()));
        assert_eq!(turn_reply(&events, "c"), TurnReply::Pending);
    }

    #[test]
    fn a_running_turn_is_pending_and_a_failed_one_says_why() {
        let running =
            vec![json!({"kind": "turn_started", "msg": {"promptId": "p"}}), chunk("working")];
        assert_eq!(turn_reply(&running, "p"), TurnReply::Pending);
        let failed = vec![
            json!({"kind": "turn_started", "msg": {"promptId": "p"}}),
            json!({"kind": "turn_result", "msg": {"promptId": "p", "status": "failed", "errorText": "rate limited"}}),
        ];
        assert_eq!(turn_reply(&failed, "p"), TurnReply::Failed("rate limited".into()));
    }

    #[test]
    fn a_long_reply_is_cut_on_a_character_boundary() {
        let long = "é".repeat(MAX_REPLY_BYTES);
        let events = vec![chunk(&long), json!({"kind": "turn_result", "msg": {"promptId": "p"}})];
        let TurnReply::Answered(text) = turn_reply(&events, "p") else { panic!() };
        assert!(text.len() <= MAX_REPLY_BYTES + '…'.len_utf8());
        assert!(text.ends_with('…'));
    }
}
