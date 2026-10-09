//! When the Chief's answer to one message is complete (pipe mode).
//!
//! The brain moves its read cursor past a message when it starts the turn
//! that answers it, says it is typing, posts the reply, and stops typing at
//! the turn's end (in that order, on one connection). So the turn that
//! answers message `seq` is the one whose typing starts after the Chief's
//! cursor reached `seq`; its typing-off ends it. A turn the Chief was
//! already running when the message arrived either stops for it (that
//! turn's typing-off comes before the cursor moves) and does not count, or
//! takes it in (the brain steers it into the turn: the cursor passes it
//! while the Chief types), and then that turn's end answers it. A reply the
//! owner's rate limit holds past the typing-off still ends the turn.

use serde_json::Value;

use super::adapter::{AGENT_MUX, UiEvent};

#[derive(Clone, Debug, Default, PartialEq)]
pub(super) struct TurnWatch {
    /// The seq of the message sent.
    pub seq: u64,
    /// The Chief's cursor reached `seq`.
    pub read: bool,
    /// The Chief started typing after `read`.
    pub working: bool,
    pub done: bool,
    /// The turn's typing went off before any reply was posted: the reply
    /// may still come (the brain posts it when the owner's agent rate
    /// limit allows), and ends the turn when it does.
    pub ended: bool,
    /// The Chief is typing now (a turn runs).
    typing: bool,
    /// The Chief's messages after `seq`, in order.
    pub replies: Vec<Value>,
}

impl TurnWatch {
    pub(super) fn new(seq: u64) -> Self {
        Self { seq, ..Self::default() }
    }

    /// Feeds one event; returns the reply message it added, if any.
    pub(super) fn on(&mut self, event: &UiEvent) -> Option<Value> {
        if self.done {
            return None;
        }
        match event {
            UiEvent::Cursor { participant, seq } if participant == AGENT_MUX => {
                if *seq >= self.seq {
                    self.read = true;
                    // Read while a turn runs: the brain steered the message
                    // into that turn, whose reply answers it.
                    self.working |= self.typing;
                }
                None
            }
            UiEvent::Typing { participant, on } if participant == AGENT_MUX => {
                self.typing = *on;
                if *on && self.read {
                    self.working = true;
                } else if !*on && self.working {
                    self.ended = true;
                    self.done = !self.replies.is_empty();
                }
                None
            }
            UiEvent::Snapshot { summary, messages, typing } => {
                self.typing = typing.iter().any(|p| p == AGENT_MUX);
                // A reopened stream after a gap: the state it missed.
                let cursor = summary.pointer("/read_cursors/agent_mux").and_then(Value::as_u64);
                if cursor.is_some_and(|c| c >= self.seq) {
                    self.read = true;
                }
                for message in messages {
                    self.keep_reply(message);
                }
                if self.read && typing.iter().any(|p| p == AGENT_MUX) {
                    self.working = true;
                } else if self.read && !self.replies.is_empty() {
                    // Read, answered, and no longer typing: the turn ended
                    // while the stream was down.
                    self.done = true;
                }
                None
            }
            UiEvent::Message(message) => self.keep_reply(message),
            _ => None,
        }
    }

    /// Keeps `message` when it is a new Chief message after `seq`.
    fn keep_reply(&mut self, message: &Value) -> Option<Value> {
        let author = message.get("author").and_then(Value::as_str);
        let seq = message.get("seq").and_then(Value::as_u64).unwrap_or(0);
        let known = self.replies.iter().any(|m| m.get("seq") == message.get("seq"));
        if author != Some(AGENT_MUX) || seq <= self.seq || known {
            return None;
        }
        self.replies.push(message.clone());
        if self.ended {
            self.done = true;
        }
        Some(message.clone())
    }
}
