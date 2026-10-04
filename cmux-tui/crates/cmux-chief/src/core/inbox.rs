//! The inbox: live messages, catch-up from the read cursor with history paging, the wake rule and prompts.

use cmux_conversation::{Message, Op, Summary};
use std::collections::VecDeque;

use super::{MAX_AUTHORS, Core, Effect, Handling, InboxItem, Paging, Task};
use crate::rules::{AGENT_MUX, PAGE, inbox_prompt, wakes};
use crate::state::OutstandingPrompt;

impl Core {
    /// Starts inbox work, one item at a time, while the ports it needs are up.
    pub(super) fn drive(&mut self) {
        while self.task == Task::Idle {
            let Some(item) = self.inbox.front() else { return };
            if !self.daemon_up || (!item.is_continuation() && !self.acpmux_up) {
                return;
            }
            let Some(item) = self.inbox.pop_front() else { return };
            match item {
                InboxItem::Live(message) => self.live(*message),
                InboxItem::CatchUpAll => {
                    self.emit(Effect::ListConversations);
                    self.task = Task::Listing;
                }
                InboxItem::CatchUp(conversation) => self.catch_up(conversation),
                InboxItem::Ready => self.emit(Effect::Ready),
            }
        }
    }

    pub(super) fn catch_up(&mut self, conversation: String) {
        self.emit(Effect::FetchSnapshot { conversation: conversation.clone(), tail: PAGE });
        self.task = Task::Snapshot(conversation);
    }

    /// A live message: handled in seq order, or the conversation is caught
    /// up when the core missed some.
    pub(super) fn live(&mut self, message: Message) {
        match self.summaries.get(&message.conversation) {
            Some(summary) => {
                let summary = summary.clone();
                self.live_with(summary, message);
            }
            None => {
                let conversation = message.conversation.clone();
                self.emit(Effect::FetchSnapshot { conversation, tail: 1 });
                self.task = Task::Summary(Box::new(message));
            }
        }
    }

    pub(super) fn live_with(&mut self, summary: Summary, message: Message) {
        if !summary.participants.iter().any(|p| p.id == AGENT_MUX) {
            return;
        }
        let handled = self.handled.get(&summary.id).copied().unwrap_or(0);
        if message.seq <= handled {
            return;
        }
        if message.seq > handled + 1 {
            return self.catch_up(summary.id);
        }
        self.task = Task::Handling(Box::new(Handling {
            summary,
            queue: VecDeque::from([message]),
            waiting: None,
        }));
        self.process();
    }

    pub(super) fn listed(&mut self, conversations: Vec<Summary>) {
        if self.task != Task::Listing {
            return;
        }
        let mut front = Vec::new();
        for summary in conversations {
            if summary.participants.iter().any(|p| p.id == AGENT_MUX) {
                front.push(InboxItem::CatchUp(summary.id.clone()));
            }
            self.remember(summary);
        }
        front.push(InboxItem::Ready);
        for item in front.into_iter().rev() {
            self.inbox.push_front(item);
        }
        self.task = Task::Idle;
    }

    pub(super) fn snapshot(&mut self, summary: Summary, messages: Vec<Message>) {
        match std::mem::take(&mut self.task) {
            Task::Summary(message) if message.conversation == summary.id => {
                self.remember(summary.clone());
                self.live_with(summary, *message);
            }
            Task::Snapshot(conversation) if conversation == summary.id => {
                let cursor = summary.read_cursors.get(AGENT_MUX).copied().unwrap_or(0);
                let from = self.handled.get(&conversation).copied().unwrap_or(0).max(cursor);
                self.summaries.insert(conversation.clone(), summary.clone());
                self.handled.insert(conversation, from);
                for message in &messages {
                    self.authors.remember(&message.id, &message.author, MAX_AUTHORS);
                }
                let pending = messages.into_iter().filter(|m| m.seq > from).collect();
                self.page(summary, from, pending);
            }
            other => self.task = other,
        }
    }

    pub(super) fn history(&mut self, conversation: &str, older: Vec<Message>) {
        match std::mem::take(&mut self.task) {
            Task::History(paging) if paging.summary.id == conversation => {
                let Paging { summary, from, pending } = *paging;
                if older.is_empty() {
                    return self.handle_all(summary, pending);
                }
                let mut merged: Vec<Message> = older.into_iter().filter(|m| m.seq > from).collect();
                merged.extend(pending);
                self.page(summary, from, merged);
            }
            other => self.task = other,
        }
    }

    /// A refused read: its task is dropped and the inbox goes on (a refused
    /// list still ends in ready).
    pub(super) fn fetch_refused(&mut self, conversation: Option<&str>, reason: &str) {
        let matches = match (&self.task, conversation) {
            (Task::Listing, None) => true,
            (Task::Snapshot(expected), Some(conversation)) => expected == conversation,
            (Task::Summary(message), Some(conversation)) => message.conversation == conversation,
            (Task::History(paging), Some(conversation)) => paging.summary.id == conversation,
            _ => false,
        };
        if !matches {
            return;
        }
        let what = match conversation {
            Some(conversation) => format!("reading {conversation}"),
            None => "the conversation list".to_owned(),
        };
        self.log(format!("the owner refused {what}: {reason}; skipped"));
        self.task = Task::Idle;
        if conversation.is_none() {
            self.inbox.push_front(InboxItem::Ready);
        }
    }

    /// Pages back until the first missing message is in hand, then handles.
    pub(super) fn page(&mut self, summary: Summary, from: u64, pending: Vec<Message>) {
        if let Some(first) = pending.first()
            && first.seq > from + 1
        {
            self.emit(Effect::FetchHistory {
                conversation: summary.id.clone(),
                before_seq: first.seq,
                limit: PAGE,
            });
            self.task = Task::History(Box::new(Paging { summary, from, pending }));
            return;
        }
        self.handle_all(summary, pending);
    }

    pub(super) fn handle_all(&mut self, summary: Summary, pending: Vec<Message>) {
        self.task =
            Task::Handling(Box::new(Handling { summary, queue: pending.into(), waiting: None }));
        self.process();
    }

    /// Handles queued messages in order; stops while a prompt waits for acpmux.
    pub(super) fn process(&mut self) {
        loop {
            let Task::Handling(handling) = &mut self.task else { return };
            if handling.waiting.is_some() {
                return;
            }
            let Some(message) = handling.queue.pop_front() else {
                self.task = Task::Idle;
                return;
            };
            self.authors.remember(&message.id, &message.author, MAX_AUTHORS);
            let Task::Handling(handling) = &self.task else { return };
            let conversation = handling.summary.id.clone();
            if message.seq <= self.handled.get(&conversation).copied().unwrap_or(0) {
                continue;
            }
            let authors = &self.authors;
            let wake = !self.state.is_answered(&message.id)
                && wakes(&handling.summary, &message, |id| {
                    authors.get(id).is_some_and(|a| a == AGENT_MUX)
                });
            if wake {
                let text = inbox_prompt(&handling.summary, &message);
                self.record_prompt(message.id.clone(), conversation, text, Some(message.seq));
                self.dirty = true;
                if let Task::Handling(handling) = &mut self.task {
                    handling.waiting = Some((message.id.clone(), message.seq));
                }
                // Without a session the prompt stays outstanding (sent on the
                // next acpmux connect).
                if !self.send_prompt(&message.id) {
                    self.accept(&message.id);
                }
                return;
            }
            self.finish_message(message.seq);
        }
    }

    /// The running handling task's message is handled: agent_mux's read
    /// cursor moves past it (when the daemon is up).
    pub(super) fn finish_message(&mut self, seq: u64) {
        let Task::Handling(handling) = &self.task else { return };
        let conversation = handling.summary.id.clone();
        let cursor = handling.summary.read_cursors.get(AGENT_MUX).copied().unwrap_or(0);
        self.handled.insert(conversation.clone(), seq);
        if !self.daemon_up || seq <= cursor {
            return;
        }
        self.emit(Effect::ConversationOp {
            conversation,
            idempotency_key: format!("cursor:{AGENT_MUX}:{seq}"),
            op: Op::ReadCursorSet { seq },
        });
    }

    /// Records an outstanding prompt with the next order (one more than any
    /// outstanding one).
    pub(super) fn record_prompt(
        &mut self,
        prompt_id: String,
        conversation: String,
        text: String,
        seq: Option<u64>,
    ) {
        // An outstanding prompt recorded again keeps its place.
        let kept = self.state.prompts.get(&prompt_id).and_then(|p| p.order);
        let last = self.state.prompts.values().map(|p| p.order.unwrap_or(0)).max().unwrap_or(0);
        let order = Some(kept.unwrap_or(last + 1));
        self.state.prompts.insert(prompt_id, OutstandingPrompt { conversation, text, seq, order });
    }

    /// Emits the prompt for an outstanding entry; false without a session.
    pub(super) fn send_prompt(&mut self, prompt_id: &str) -> bool {
        let Some(entry) = self.state.prompts.get(prompt_id) else { return false };
        if !self.acpmux_up || self.mux_session.is_none() {
            return false;
        }
        let text = entry.text.clone();
        self.emit(Effect::Prompt { prompt_id: prompt_id.to_owned(), text });
        true
    }

    /// acpmux holds the prompt (or answered its request): the inbox moves on.
    pub(super) fn accept(&mut self, prompt_id: &str) {
        let Task::Handling(handling) = &mut self.task else { return };
        let seq = match &handling.waiting {
            Some((id, seq)) if id == prompt_id => *seq,
            _ => return,
        };
        handling.waiting = None;
        self.finish_message(seq);
        self.process();
    }
}
