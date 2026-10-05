//! The inbox (mux/host rules): the Chief conversation's messages in seq
//! order, the wake rule, catch-up from the `agent_mux` read cursor after a
//! (re)connect, and the cursor itself, which moves only past messages that
//! are in the OptChat log, so a restart never loses or repeats one.
//!
//! Deviation: mux/host answers every conversation `agent_mux` joins. OptChat
//! is one chat with one user (section 1), so this Chief reads only its own
//! conversation; mentions in other conversations are not answered.

use cmux_chief::rules::{AGENT_MUX, PAGE, message_text, wakes};
use cmux_conversation::{Change, Message, Op};

use super::{Brain, Source};
use crate::daemon::{DaemonEvent, OpError};

impl Brain {
    pub(super) fn on_daemon(&mut self, event: DaemonEvent) {
        match event {
            DaemonEvent::Up {
                port,
                conversation,
                reconnect,
            } => {
                self.daemon = Some(port);
                self.reconnect = Some(reconnect);
                if self.state.conversation.as_deref() != Some(conversation.id.as_str()) {
                    if let Some(old) = self.state.conversation.take() {
                        // A new conversation (the owner's store was made
                        // again): its seqs start over, so the old counters
                        // would skip its first messages. Start from its own
                        // agent_mux cursor; ops for the old one cannot land.
                        let cursor = conversation
                            .read_cursors
                            .get(AGENT_MUX)
                            .copied()
                            .unwrap_or(0);
                        (self.log)(&format!(
                            "the Chief conversation changed from {old} to {}; reading it from seq {cursor}",
                            conversation.id
                        ));
                        self.handled = cursor;
                        self.state.logged_seq = cursor;
                        self.state
                            .outbox
                            .retain(|e| e.conversation == conversation.id);
                    }
                    self.state.conversation = Some(conversation.id.clone());
                    self.save();
                }
                self.summary = Some(conversation);
                self.post_notices();
                self.flush_outbox();
                self.catch_up();
            }
            DaemonEvent::Changed {
                conversation,
                change,
            } => {
                if self.state.conversation.as_deref() != Some(conversation.as_str()) {
                    return;
                }
                match change {
                    Change::Conversation { conversation } => self.summary = Some(*conversation),
                    Change::ReadCursor { participant, seq } => {
                        if let Some(summary) = self.summary.as_mut() {
                            let cursor = summary.read_cursors.entry(participant).or_insert(0);
                            *cursor = (*cursor).max(seq);
                        }
                    }
                    Change::Message { message } => self.on_message(message),
                    Change::MessageUpdated { .. } => {}
                }
            }
            DaemonEvent::Down => {
                self.daemon = None;
                self.reconnect = None;
            }
            DaemonEvent::Fatal(why) => {
                (self.log)(&why);
                self.fatal = Some(why);
            }
        }
    }

    /// Drops the connection after a transport failure or a lost binding; the
    /// link connects and binds again, and the catch-up replays what was missed.
    pub(super) fn drop_daemon(&mut self) {
        self.daemon = None;
        if let Some(reconnect) = self.reconnect.take() {
            reconnect();
        }
    }

    fn on_message(&mut self, message: Message) {
        if message.author == AGENT_MUX {
            self.mux_messages.insert(message.id.clone());
        }
        if self.daemon.is_none() || message.seq <= self.handled {
            return;
        }
        if message.seq > self.handled + 1 {
            // A gap: something was missed; fetch it in order.
            self.catch_up();
            return;
        }
        self.handle(message);
    }

    /// Every message after what was handled (or the agent read cursor, if later).
    fn catch_up(&mut self) {
        let Some(conversation) = self.state.conversation.clone() else {
            return;
        };
        let Some(daemon) = self.daemon.as_mut() else {
            return;
        };
        let fetched = (|| {
            let (summary, messages) = daemon.snapshot(&conversation, PAGE)?;
            let cursor = summary.read_cursors.get(AGENT_MUX).copied().unwrap_or(0);
            let from = self.handled.max(cursor);
            let mut pending: Vec<Message> =
                messages.iter().filter(|m| m.seq > from).cloned().collect();
            // Page back until the first missing message is in hand.
            while let Some(first) = pending.first().map(|m| m.seq)
                && first > from + 1
            {
                let older = daemon.history(&conversation, first, PAGE)?;
                if older.is_empty() {
                    break;
                }
                let mut merged: Vec<Message> = older.into_iter().filter(|m| m.seq > from).collect();
                merged.append(&mut pending);
                pending = merged;
            }
            Ok::<_, OpError>((summary, messages, pending, from))
        })();
        match fetched {
            Ok((summary, messages, pending, from)) => {
                for m in messages.iter().chain(pending.iter()) {
                    if m.author == AGENT_MUX {
                        self.mux_messages.insert(m.id.clone());
                    }
                }
                self.summary = Some(summary);
                self.handled = from;
                for message in pending {
                    self.handle(message);
                }
            }
            Err(e) => {
                (self.log)(&format!("catch-up failed: {e}"));
                self.drop_daemon();
            }
        }
    }

    /// Queues a waking message; moves the cursor past a message that needs no
    /// log once nothing before it is still queued.
    fn handle(&mut self, message: Message) {
        if message.seq <= self.handled {
            return;
        }
        self.handled = message.seq;
        let Some(summary) = self.summary.as_ref() else {
            return;
        };
        let text = message_text(&message);
        if !text.trim().is_empty() && wakes(summary, &message, |id| self.mux_messages.contains(id))
        {
            self.queue(text, Source::Message { seq: message.seq });
            return;
        }
        if !self
            .queue
            .iter()
            .any(|q| matches!(q.source, Source::Message { .. }))
        {
            self.state.logged_seq = self.handled;
            self.save();
            self.set_cursor(self.handled);
        }
    }

    pub(super) fn set_cursor(&mut self, seq: u64) {
        let Some(conversation) = self.state.conversation.clone() else {
            return;
        };
        let current = self
            .summary
            .as_ref()
            .and_then(|s| s.read_cursors.get(AGENT_MUX).copied())
            .unwrap_or(0);
        if seq <= current {
            return;
        }
        let Some(daemon) = self.daemon.as_mut() else {
            return;
        };
        let key = format!("cursor:{AGENT_MUX}:{seq}");
        match daemon.op(&conversation, &key, &Op::ReadCursorSet { seq }) {
            Ok(_) => {
                if let Some(summary) = self.summary.as_mut() {
                    summary.read_cursors.insert(AGENT_MUX.into(), seq);
                }
            }
            Err(OpError::Rejected(reason)) if reason.contains("cursor_regression") => {}
            Err(OpError::Rejected(reason)) if reason.contains("actor_mismatch") => {
                // The app replaced the token: bind again now, not at the next reply.
                (self.log)(&format!("read cursor {seq}: binding lost; reconnecting"));
                self.drop_daemon();
            }
            Err(OpError::Rejected(reason)) => {
                (self.log)(&format!("read cursor {seq} refused: {reason}"))
            }
            Err(OpError::Transport(e)) => {
                (self.log)(&format!("read cursor {seq}: {e}"));
                self.drop_daemon();
            }
        }
    }

    pub(super) fn set_typing(&mut self, on: bool) {
        let Some(conversation) = self.state.conversation.clone() else {
            return;
        };
        let Some(daemon) = self.daemon.as_mut() else {
            return;
        };
        match daemon.typing(&conversation, on) {
            Ok(()) => {}
            Err(OpError::Rejected(reason)) if reason.contains("actor_mismatch") => {
                (self.log)(&format!("typing {on}: binding lost; reconnecting"));
                self.drop_daemon();
            }
            Err(OpError::Rejected(reason)) => (self.log)(&format!("typing {on} refused: {reason}")),
            Err(OpError::Transport(e)) => {
                (self.log)(&format!("typing {on}: {e}"));
                self.drop_daemon();
            }
        }
    }
}
