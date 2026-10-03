//! The daemon port: connect, conversation changes, disconnects.

use cmux_conversation::{Change, Summary};

use super::{Core, InboxItem, Port, Task};
use crate::rules::AGENT_MUX;

impl Core {
    pub(super) fn daemon_connected(&mut self, conversation: Summary) {
        if self.daemon_up {
            self.disconnected(Port::Daemon);
        }
        self.summaries.clear();
        if self.state.default_conversation.as_deref() != Some(conversation.id.as_str()) {
            self.state.default_conversation = Some(conversation.id.clone());
            self.dirty = true;
        }
        self.remember(conversation);
        self.daemon_up = true;
        self.flush_outbox();
        if self.acpmux_up {
            self.inbox.push_back(InboxItem::CatchUpAll);
        }
    }

    pub(super) fn remember(&mut self, summary: Summary) {
        let cursor = summary.read_cursors.get(AGENT_MUX).copied().unwrap_or(0);
        self.handled.entry(summary.id.clone()).or_insert(cursor);
        if let Some(last) = &summary.last_message {
            self.authors.insert(last.id.clone(), last.author.clone());
        }
        self.summaries.insert(summary.id.clone(), summary);
    }

    pub(super) fn changed(&mut self, conversation: &str, change: Change) {
        match change {
            Change::Conversation { conversation } => self.remember(*conversation),
            Change::ReadCursor { participant, seq } => {
                if let Some(summary) = self.summaries.get_mut(conversation) {
                    let cursor = summary.read_cursors.entry(participant).or_insert(0);
                    *cursor = (*cursor).max(seq);
                }
            }
            Change::Message { message } => {
                self.authors.insert(message.id.clone(), message.author.clone());
                if self.daemon_up && self.acpmux_up {
                    self.inbox.push_back(InboxItem::Live(Box::new(message)));
                }
            }
            Change::MessageUpdated { .. } => {}
        }
    }

    pub(super) fn disconnected(&mut self, port: Port) {
        match port {
            Port::Daemon => {
                self.daemon_up = false;
                self.outbox_inflight = None;
                self.inbox.clear();
                // Every daemon read fails with the connection; a prompt-only
                // handling task goes on.
                if !matches!(self.task, Task::Handling(_)) {
                    self.task = Task::Idle;
                }
            }
            Port::Acpmux => {
                self.acpmux_up = false;
                self.inbox.retain(InboxItem::is_continuation);
                // Pending permissions stay: the session list of the next
                // acpmux connect answers them.
                if let Some(conversation) = self.typing_in.clone() {
                    self.set_typing(&conversation, false);
                }
                // The waiting prompt settles: the inbox moves on and the
                // prompt stays outstanding, resent on the next connect.
                let waiting = match &self.task {
                    Task::Handling(handling) => handling.waiting.as_ref().map(|(id, _)| id.clone()),
                    _ => None,
                };
                if let Some(prompt_id) = waiting {
                    self.accept(&prompt_id);
                }
                // A child whose events fetch dies with the connection
                // finishes with no reply text.
                let children = std::mem::take(&mut self.pending_children);
                let any = !children.is_empty();
                for (session_id, session) in children {
                    self.finish_child(&session, "");
                    self.replay_held(&session_id);
                }
                if any {
                    self.flush_outbox();
                }
            }
        }
    }
}
