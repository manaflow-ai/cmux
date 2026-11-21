//! Part of the continuation of a turn whose agent process died (`auto_resume.rs`): the messages
//! steered into that turn that the agent never read go into the continuation, quoted.
//!
//! Claude Code holds a steer until the turn's next tool step and writes it to its conversation
//! only then (`claude_stdio/steer_batch.rs`); an agent that died before that step took the steer
//! with it, and the resumed conversation has no trace of it. The person saw it go in, and the
//! continuation only said "continue": the message was lost. A daemon restart's continuation
//! quotes every steer of the cut turn already (`restart_resume.rs`); this is the agent-exit side.
//!
//! A steer counts as read once the log says so (`steer_read`), and as gone once it was withdrawn
//! (`steer_withdrawn`) or went back to the queue (`steer_returned`): none of those is quoted. Read
//! newest first, back to the cut turn's start only, so a long chat costs only its last turn.

use super::Hub;
use crate::store::EventRecord;
use serde_json::Value;

/// Longest quote of one steer, in characters.
const MAX_QUOTE_CHARS: usize = 4_000;
/// Most steers one continuation quotes (the newest are kept).
const MAX_STEERS: usize = 64;

/// The record kinds the scan reads; every other line is passed without parsing.
const KINDS: [&[u8]; 5] =
    [b"user_message", b"turn_started", b"steer_read", b"steer_withdrawn", b"steer_returned"];

impl Hub {
    /// The texts of the steers into `turn_id` its agent never read, oldest first.
    pub(super) fn unread_steers(&self, session_id: &str, turn_id: &str) -> Vec<String> {
        let mut settled = std::collections::HashSet::<String>::new();
        let mut unread: Vec<String> = Vec::new();
        let _ = self.store.scan_back(
            session_id,
            0,
            u64::MAX,
            &|_, kind| !KINDS.contains(&kind),
            &mut |e: EventRecord| {
                let field = |k: &str| e.msg.get(k).and_then(Value::as_str);
                let prompt_id = field("promptId").map(str::to_owned);
                match e.kind.as_str() {
                    "turn_started" => return field("turnId") != Some(turn_id),
                    "steer_read" | "steer_withdrawn" | "steer_returned" => {
                        settled.extend(prompt_id);
                    }
                    "user_message"
                        if e.msg.get("steer").and_then(Value::as_bool) == Some(true)
                            && field("turnId") == Some(turn_id)
                            && prompt_id.as_deref().is_some_and(|id| !settled.contains(id))
                            && unread.len() < MAX_STEERS =>
                    {
                        let images =
                            e.msg.get("images").and_then(Value::as_array).map_or(0, Vec::len);
                        let text = field("text").filter(|t| !t.trim().is_empty());
                        let quoted = match text {
                            Some(t) => Some(t.chars().take(MAX_QUOTE_CHARS).collect()),
                            None => (images > 0).then(|| format!("({images} image(s))")),
                        };
                        unread.extend(quoted);
                    }
                    _ => {}
                }
                true
            },
        );
        unread.reverse();
        unread
    }
}

/// `text` with the unread steers quoted after it.
pub(super) fn with_unread(mut text: String, steers: &[String]) -> String {
    if steers.is_empty() {
        return text;
    }
    text.push_str(
        "\n\nThese messages were sent into that turn, and you may not have read them before it \
         was cut off. Act on any you have not acted on:",
    );
    for steer in steers {
        text.push_str(&format!("\n<message>\n{steer}\n</message>"));
    }
    text
}

#[cfg(test)]
#[path = "unread_steers_tests.rs"]
mod tests;
