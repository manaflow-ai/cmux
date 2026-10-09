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
//!
//! E22: a brain that names the messages each reply answers (`answers`)
//! decides it instead. Pipe mode keeps only the replies that answer its
//! own message, waits past a turn whose reply answers others, and (unless
//! `--no-wait-agents`) waits while the reply says that subagents the
//! message started still work (`answers_pending`), until the turn of the
//! last report ends. Replies without `answers` (an older brain) follow the
//! inference above.

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
    /// The id of the message sent (E22): set, replies that name what they
    /// answer count only when they answer it.
    id: Option<String>,
    /// Wait for the subagents the message started (`--no-wait-agents`
    /// clears it).
    wait_agents: bool,
    /// A reply answered the message.
    answered: bool,
    /// The last reply that answered it says its subagents still work.
    open: bool,
    /// This turn's reply answered other messages only.
    foreign: bool,
}

impl TurnWatch {
    pub(super) fn new(seq: u64) -> Self {
        Self { seq, ..Self::default() }
    }

    /// Watches for the replies that answer message `id` (E22).
    pub(super) fn answering(mut self, id: &str, wait_agents: bool) -> Self {
        self.id = Some(id.to_owned());
        self.wait_agents = wait_agents;
        self
    }

    /// The turn that answered the message ended: done, unless subagents it
    /// started still work (their reports start more turns).
    fn answered_turn_ended(&mut self) {
        self.working = false;
        self.ended = false;
        self.done = !self.open;
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
                if *on {
                    self.foreign = false;
                    self.working |= self.read;
                } else if self.working && self.answered {
                    self.answered_turn_ended();
                } else if self.working && self.foreign {
                    // That turn answered other messages: ours waits for
                    // the next one.
                    self.working = false;
                    self.foreign = false;
                } else if self.working {
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
                } else if self.answered {
                    self.answered_turn_ended();
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
        let ids = |key: &str| -> Vec<&str> {
            message
                .get(key)
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .collect()
        };
        let answers = ids("answers");
        if let Some(id) = self.id.as_deref()
            && !answers.is_empty()
        {
            if !answers.contains(&id) {
                // A reply to other messages: not ours, and its turn does
                // not end the wait (a late one undoes the typing-off).
                self.foreign = true;
                if self.ended {
                    self.ended = false;
                    self.working = false;
                }
                return None;
            }
            self.replies.push(message.clone());
            self.answered = true;
            self.open = self.wait_agents && ids("answers_pending").contains(&id);
            if !self.typing {
                // Posted after its turn's typing-off (the owner's rate
                // limit held it): that turn has ended.
                self.answered_turn_ended();
            }
            return Some(message.clone());
        }
        self.replies.push(message.clone());
        if self.ended {
            self.done = true;
        }
        Some(message.clone())
    }
}
