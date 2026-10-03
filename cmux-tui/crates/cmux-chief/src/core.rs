//! The sans-I/O brain host (plans/cmux-next/chief-mac.md section 3):
//! `Core::step(input, now_ms) -> effects`. Port of `mux/host/src/host.ts`.
//! The host shell does every read, write and timer the effects name and
//! reports results back as inputs. When a step changed the durable state,
//! its first effect is `persist`: the shell writes it before it runs the
//! other effects (write-ahead), so a crash only replays keyed effects that
//! an owner dedupes.

use std::collections::{BTreeMap, VecDeque};

use cmux_conversation::{Change, Message, Op, Part, Summary, WorkStatus};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::acp::{AcpmuxEvent, SessionStatus, SessionSummary, TurnFolder, TurnOutput, last_reply};
use crate::rules::{
    AGENT_GAP_RETRY_MS, AGENT_GAP_TIMER_SLACK_MS, AGENT_MUX, MUX_SESSION_NAME, PAGE, PARENT_TAG,
    child_finished_prompt, child_permission_prompt, excerpt, inbox_prompt, turn_ended, turn_key,
    wakes, work_part, work_status,
};
use crate::state::{ChildRecord, HostState, OutboxEntry, OutstandingPrompt};

/// The timer key of the one-shot outbox retry.
pub const OUTBOX_TIMER: &str = "outbox";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Port {
    Daemon,
    Acpmux,
}

/// What the shell reports to the core.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Input {
    /// The daemon port is up: the default conversation exists (created with
    /// `DEFAULT_CONVERSATION_KEY`) and writes are stamped `agent_mux`.
    DaemonConnected {
        conversation: Summary,
    },
    ConversationsListed {
        conversations: Vec<Summary>,
    },
    Snapshot {
        conversation: Summary,
        messages: Vec<Message>,
    },
    History {
        conversation: String,
        messages: Vec<Message>,
    },
    ConversationChanged {
        conversation: String,
        change: Change,
    },
    /// The owner answered a `conversation_op`: `reason` is set on a reject.
    OpResult {
        idempotency_key: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        change: Option<Change>,
    },
    /// The acpmux port is up: the Chief's session exists and `events` is the
    /// attach replay after `state.acpmux_seq`.
    AcpmuxConnected {
        session_id: String,
        sessions: Vec<SessionSummary>,
        events: Vec<AcpmuxEvent>,
    },
    AcpmuxEvent {
        event: AcpmuxEvent,
    },
    SessionChanged {
        session: SessionSummary,
    },
    PermissionPending {
        session_id: String,
        permission_id: String,
        request: Value,
    },
    Sessions {
        sessions: Vec<SessionSummary>,
    },
    ChildEvents {
        session_id: String,
        events: Vec<AcpmuxEvent>,
    },
    /// A `prompt` request returned (accepted or failed; a failed one is sent
    /// again on the next acpmux connect).
    PromptSettled {
        prompt_id: String,
    },
    Timer {
        key: String,
    },
    Disconnected {
        port: Port,
    },
}

/// What the core asks the shell to do, in order.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Effect {
    /// Write the durable state (always the first effect of its step).
    Persist {
        state: Box<HostState>,
    },
    ConversationOp {
        conversation: String,
        idempotency_key: String,
        op: Op,
    },
    Typing {
        conversation: String,
        on: bool,
    },
    Prompt {
        prompt_id: String,
        text: String,
    },
    ListConversations,
    FetchSnapshot {
        conversation: String,
        tail: u32,
    },
    FetchHistory {
        conversation: String,
        before_seq: u64,
        limit: u32,
    },
    FetchSessions,
    FetchChildEvents {
        session_id: String,
        after: u64,
    },
    Reconnect {
        port: Port,
    },
    ArmTimer {
        key: String,
        at: u64,
    },
    /// Both ports are up and the first catch-up ran.
    Ready,
    Log {
        line: String,
    },
}

#[derive(Debug, Clone, PartialEq)]
enum InboxItem {
    Live(Box<Message>),
    CatchUpAll,
    CatchUp(String),
    Ready,
}

#[derive(Debug, Clone, Default, PartialEq)]
enum Task {
    #[default]
    Idle,
    Listing,
    Snapshot(String),
    History {
        conversation: String,
        from: u64,
        pending: Vec<Message>,
    },
    Handling {
        conversation: String,
        queue: VecDeque<Message>,
        waiting: Option<(String, u64)>,
    },
}

/// The brain host's core. `state` is durable; the rest is rebuilt on connect.
#[derive(Debug, Clone, Default)]
pub struct Core {
    pub state: HostState,
    now: u64,
    dirty: bool,
    effects: Vec<Effect>,
    daemon_up: bool,
    acpmux_up: bool,
    mux_session: Option<String>,
    summaries: BTreeMap<String, Summary>,
    handled: BTreeMap<String, u64>,
    authors: BTreeMap<String, String>,
    folder: TurnFolder,
    typing_in: Option<String>,
    session_status: BTreeMap<String, SessionStatus>,
    session_info: BTreeMap<String, SessionSummary>,
    child_turn_floor: BTreeMap<String, u64>,
    pending_children: BTreeMap<String, SessionSummary>,
    pending_permissions: Vec<(String, String, Value)>,
    inbox: VecDeque<InboxItem>,
    task: Task,
    outbox_inflight: Option<String>,
}

impl Core {
    pub fn new(state: HostState) -> Self {
        Self { state, ..Self::default() }
    }

    pub fn step(&mut self, input: Input, now_ms: u64) -> Vec<Effect> {
        self.now = now_ms;
        match input {
            Input::DaemonConnected { conversation } => self.daemon_connected(conversation),
            Input::ConversationsListed { conversations } => self.listed(conversations),
            Input::Snapshot { conversation, messages } => self.snapshot(conversation, messages),
            Input::History { conversation, messages } => self.history(&conversation, messages),
            Input::ConversationChanged { conversation, change } => {
                self.changed(&conversation, change);
            }
            Input::OpResult { idempotency_key, reason, change } => {
                self.op_result(&idempotency_key, reason.as_deref(), change);
            }
            Input::AcpmuxConnected { session_id, sessions, events } => {
                self.acpmux_connected(session_id, sessions, &events);
            }
            Input::AcpmuxEvent { event } => {
                if event.session_id.is_some() && event.session_id == self.mux_session {
                    self.apply_mux_event(&event);
                }
            }
            Input::SessionChanged { session } => self.session_changed(session),
            Input::PermissionPending { session_id, permission_id, request } => {
                self.permission(session_id, permission_id, request);
            }
            Input::Sessions { sessions } => self.sessions(sessions),
            Input::ChildEvents { session_id, events } => {
                if let Some(session) = self.pending_children.remove(&session_id) {
                    self.finish_child(&session, &last_reply(&events));
                    self.flush_outbox();
                }
            }
            Input::PromptSettled { prompt_id } => self.accept(&prompt_id),
            Input::Timer { key } => {
                if key == OUTBOX_TIMER {
                    self.flush_outbox();
                }
            }
            Input::Disconnected { port } => self.disconnected(port),
        }
        self.drive();
        let mut effects = std::mem::take(&mut self.effects);
        if std::mem::take(&mut self.dirty) {
            effects.insert(0, Effect::Persist { state: Box::new(self.state.clone()) });
        }
        effects
    }

    fn emit(&mut self, effect: Effect) {
        self.effects.push(effect);
    }

    fn log(&mut self, line: String) {
        self.emit(Effect::Log { line });
    }

    // MARK: daemon

    fn daemon_connected(&mut self, conversation: Summary) {
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

    fn remember(&mut self, summary: Summary) {
        let cursor = summary.read_cursors.get(AGENT_MUX).copied().unwrap_or(0);
        self.handled.entry(summary.id.clone()).or_insert(cursor);
        if let Some(last) = &summary.last_message {
            self.authors.insert(last.id.clone(), last.author.clone());
        }
        self.summaries.insert(summary.id.clone(), summary);
    }

    fn changed(&mut self, conversation: &str, change: Change) {
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

    fn disconnected(&mut self, port: Port) {
        self.inbox.clear();
        self.task = Task::Idle;
        match port {
            Port::Daemon => {
                self.daemon_up = false;
                self.outbox_inflight = None;
            }
            Port::Acpmux => {
                self.acpmux_up = false;
                self.pending_children.clear();
                if let Some(conversation) = self.typing_in.clone() {
                    self.set_typing(&conversation, false);
                }
            }
        }
    }

    // MARK: inbox

    /// Starts inbox work, one item at a time, while both ports are up.
    fn drive(&mut self) {
        while self.task == Task::Idle && self.daemon_up && self.acpmux_up {
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

    fn catch_up(&mut self, conversation: String) {
        self.emit(Effect::FetchSnapshot { conversation: conversation.clone(), tail: PAGE });
        self.task = Task::Snapshot(conversation);
    }

    /// A live message: handled in seq order, or the conversation is caught up
    /// when the core missed some (or does not know the conversation).
    fn live(&mut self, message: Message) {
        let Some(summary) = self.summaries.get_mut(&message.conversation) else {
            return self.catch_up(message.conversation.clone());
        };
        if !summary.participants.iter().any(|p| p.id == AGENT_MUX) {
            return;
        }
        let handled = self.handled.get(&message.conversation).copied().unwrap_or(0);
        if message.seq <= handled {
            return;
        }
        if message.seq > handled + 1 {
            return self.catch_up(message.conversation.clone());
        }
        summary.last_seq = summary.last_seq.max(message.seq);
        let conversation = message.conversation.clone();
        self.task =
            Task::Handling { conversation, queue: VecDeque::from([message]), waiting: None };
        self.process();
    }

    fn listed(&mut self, conversations: Vec<Summary>) {
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

    fn snapshot(&mut self, summary: Summary, messages: Vec<Message>) {
        if self.task != Task::Snapshot(summary.id.clone()) {
            return;
        }
        let conversation = summary.id.clone();
        let cursor = summary.read_cursors.get(AGENT_MUX).copied().unwrap_or(0);
        let from = self.handled.get(&conversation).copied().unwrap_or(0).max(cursor);
        self.summaries.insert(conversation.clone(), summary);
        self.handled.insert(conversation.clone(), from);
        for message in &messages {
            self.authors.insert(message.id.clone(), message.author.clone());
        }
        let pending = messages.into_iter().filter(|m| m.seq > from).collect();
        self.page(conversation, from, pending);
    }

    fn history(&mut self, conversation: &str, older: Vec<Message>) {
        let Task::History { conversation: expected, from, pending } =
            std::mem::take(&mut self.task)
        else {
            return;
        };
        if expected != conversation {
            self.task = Task::History { conversation: expected, from, pending };
            return;
        }
        if older.is_empty() {
            return self.handle_all(expected, pending);
        }
        let mut merged: Vec<Message> = older.into_iter().filter(|m| m.seq > from).collect();
        merged.extend(pending);
        self.page(expected, from, merged);
    }

    /// Pages back until the first missing message is in hand, then handles.
    fn page(&mut self, conversation: String, from: u64, pending: Vec<Message>) {
        if let Some(first) = pending.first()
            && first.seq > from + 1
        {
            self.emit(Effect::FetchHistory {
                conversation: conversation.clone(),
                before_seq: first.seq,
                limit: PAGE,
            });
            self.task = Task::History { conversation, from, pending };
            return;
        }
        self.handle_all(conversation, pending);
    }

    fn handle_all(&mut self, conversation: String, pending: Vec<Message>) {
        self.task = Task::Handling { conversation, queue: pending.into(), waiting: None };
        self.process();
    }

    /// Handles queued messages in order; stops while a prompt waits for acpmux.
    fn process(&mut self) {
        loop {
            let Task::Handling { conversation, queue, waiting } = &mut self.task else { return };
            if waiting.is_some() {
                return;
            }
            let Some(message) = queue.pop_front() else {
                self.task = Task::Idle;
                return;
            };
            let conversation = conversation.clone();
            self.authors.insert(message.id.clone(), message.author.clone());
            if message.seq <= self.handled.get(&conversation).copied().unwrap_or(0) {
                continue;
            }
            let Some(summary) = self.summaries.get(&conversation) else { continue };
            let authors = &self.authors;
            let wake = !self.state.is_answered(&message.id)
                && wakes(summary, &message, |id| authors.get(id).is_some_and(|a| a == AGENT_MUX));
            if wake {
                let text = inbox_prompt(summary, &message);
                self.state.prompts.insert(
                    message.id.clone(),
                    OutstandingPrompt { conversation, text, seq: Some(message.seq) },
                );
                self.dirty = true;
                if let Task::Handling { waiting, .. } = &mut self.task {
                    *waiting = Some((message.id.clone(), message.seq));
                }
                if !self.send_prompt(&message.id) {
                    // No session to prompt: the prompt stays outstanding and is
                    // sent on the next acpmux connect.
                    self.accept(&message.id);
                }
                return;
            }
            self.finish_message(&message.conversation, message.seq);
        }
    }

    fn finish_message(&mut self, conversation: &str, seq: u64) {
        self.handled.insert(conversation.to_owned(), seq);
        let Some(summary) = self.summaries.get(conversation) else { return };
        if seq <= summary.read_cursors.get(AGENT_MUX).copied().unwrap_or(0) {
            return;
        }
        self.emit(Effect::ConversationOp {
            conversation: conversation.to_owned(),
            idempotency_key: format!("cursor:{AGENT_MUX}:{seq}"),
            op: Op::ReadCursorSet { seq },
        });
    }

    /// Emits the prompt for an outstanding entry; false without a session.
    fn send_prompt(&mut self, prompt_id: &str) -> bool {
        let Some(entry) = self.state.prompts.get(prompt_id) else { return false };
        if !self.acpmux_up || self.mux_session.is_none() {
            return false;
        }
        let text = entry.text.clone();
        self.emit(Effect::Prompt { prompt_id: prompt_id.to_owned(), text });
        true
    }

    /// acpmux holds the prompt (or answered its request): the inbox moves on.
    fn accept(&mut self, prompt_id: &str) {
        let Task::Handling { conversation, waiting, .. } = &mut self.task else { return };
        if waiting.as_ref().is_none_or(|(id, _)| id != prompt_id) {
            return;
        }
        let (_, seq) = waiting.take().expect("checked above");
        let conversation = conversation.clone();
        self.finish_message(&conversation, seq);
        self.process();
    }

    // MARK: acpmux

    fn acpmux_connected(
        &mut self,
        session_id: String,
        sessions: Vec<SessionSummary>,
        events: &[AcpmuxEvent],
    ) {
        if self.state.mux_session_id.as_deref() != Some(session_id.as_str()) {
            self.state.mux_session_id = Some(session_id.clone());
            self.state.acpmux_seq = 0;
            self.dirty = true;
        }
        self.mux_session = Some(session_id);
        for session in sessions {
            self.session_status.insert(session.session_id.clone(), session.status);
            self.session_info.insert(session.session_id.clone(), session);
        }
        self.folder = TurnFolder::new(self.state.acpmux_seq);
        for event in events {
            self.apply_mux_event(event);
        }
        self.acpmux_up = true;
        let outstanding: Vec<String> = self.state.prompts.keys().cloned().collect();
        for prompt_id in outstanding {
            self.send_prompt(&prompt_id);
        }
        self.reconcile_children();
        if self.daemon_up {
            self.inbox.push_back(InboxItem::CatchUpAll);
        }
    }

    fn apply_mux_event(&mut self, event: &AcpmuxEvent) {
        for output in self.folder.apply(event) {
            match output {
                TurnOutput::Accepted { prompt_id, .. } => self.accept(&prompt_id),
                TurnOutput::Started { turn, .. } => {
                    if let Some(conversation) = self.conversation_for(turn.prompt_id.as_deref()) {
                        self.set_typing(&conversation, true);
                    }
                }
                TurnOutput::Ended { turn, seq, error } => {
                    let conversation = self.conversation_for(turn.prompt_id.as_deref());
                    let mut text = turn.text.trim().to_owned();
                    if text.is_empty()
                        && let Some(error) = error
                    {
                        text = format!("(turn failed: {error})");
                    }
                    if let Some(conversation) = &conversation
                        && !text.is_empty()
                    {
                        let key =
                            turn_key(self.mux_session.as_deref().unwrap_or(""), turn.turn_seq);
                        self.state.outbox.push(OutboxEntry {
                            conversation: conversation.clone(),
                            idempotency_key: key.clone(),
                            rate_retried: false,
                            not_before: None,
                            op: Op::MessageSend {
                                client_msg_id: key,
                                parts: vec![Part::Text { text, runs: None }],
                                reply_to: None,
                            },
                            child: None,
                        });
                    }
                    if let Some(prompt_id) = &turn.prompt_id {
                        self.state.mark_answered(prompt_id);
                    }
                    self.state.acpmux_seq = self.state.acpmux_seq.max(seq);
                    self.dirty = true;
                    self.flush_outbox();
                    if let Some(conversation) = conversation {
                        self.set_typing(&conversation, false);
                    }
                }
            }
        }
    }

    fn conversation_for(&self, prompt_id: Option<&str>) -> Option<String> {
        prompt_id
            .and_then(|id| self.state.prompts.get(id))
            .map(|p| p.conversation.clone())
            .filter(|c| !c.is_empty())
            .or_else(|| self.state.default_conversation.clone())
    }

    fn set_typing(&mut self, conversation: &str, on: bool) {
        self.typing_in = on.then(|| conversation.to_owned());
        if self.daemon_up {
            self.emit(Effect::Typing { conversation: conversation.to_owned(), on });
        }
    }

    // MARK: outbox

    /// Sends the outbox head; the next entry waits for its result.
    fn flush_outbox(&mut self) {
        while self.daemon_up && self.outbox_inflight.is_none() {
            let Some(entry) = self.state.outbox.first() else { return };
            if entry.not_before.is_some_and(|at| self.now < at) {
                return; // its one-shot timer flushes it
            }
            let op = match (&entry.child, &entry.op) {
                (Some(child), Op::MessageEdit { parts, .. }) => self
                    .state
                    .children
                    .get(child)
                    .and_then(|c| c.message_id.clone())
                    .map(|message_id| Op::MessageEdit { message_id, parts: parts.clone() }),
                _ => Some(entry.op.clone()),
            };
            let Some(op) = op else {
                // An edit of a card whose send was never confirmed: nothing to edit.
                self.state.outbox.remove(0);
                self.dirty = true;
                continue;
            };
            let (conversation, key) = (entry.conversation.clone(), entry.idempotency_key.clone());
            self.outbox_inflight = Some(key.clone());
            self.emit(Effect::ConversationOp { conversation, idempotency_key: key, op });
        }
    }

    fn op_result(&mut self, key: &str, reason: Option<&str>, change: Option<Change>) {
        if self.outbox_inflight.as_deref() != Some(key) {
            // A read cursor op: the owner's change event updates the summary.
            if let Some(reason) = reason
                && !reason.contains("cursor_regression")
            {
                self.log(format!("op {key} rejected: {reason}"));
            }
            return;
        }
        self.outbox_inflight = None;
        let Some(head) = self.state.outbox.first_mut() else { return };
        match reason {
            None => {
                if let (Some(child), Op::MessageSend { .. }, Some(Change::Message { message })) =
                    (&head.child, &head.op, &change)
                    && let Some(record) = self.state.children.get_mut(child)
                {
                    record.message_id = Some(message.id.clone());
                }
            }
            Some(reason) if reason.contains("actor_mismatch") => {
                // The binding was lost: reconnect, which binds again; keep the entry.
                self.log(format!("op {key}: binding lost; reconnecting to bind again"));
                self.emit(Effect::Reconnect { port: Port::Daemon });
                return;
            }
            Some(reason) if reason.contains("agent_rate") && !head.rate_retried => {
                head.rate_retried = true;
                let at = self.now + AGENT_GAP_RETRY_MS;
                head.not_before = Some(at);
                self.dirty = true;
                self.log(format!("op {key} inside the agent gap; retrying once after it"));
                self.emit(Effect::ArmTimer {
                    key: OUTBOX_TIMER.to_owned(),
                    at: at + AGENT_GAP_TIMER_SLACK_MS,
                });
                return;
            }
            Some(reason) => self.log(format!("dropping rejected op {key}: {reason}")),
        }
        self.state.outbox.remove(0);
        self.dirty = true;
        self.flush_outbox();
    }

    // MARK: children (sessions tagged mux.parent=mux)

    fn is_child(&self, session: &SessionSummary) -> bool {
        session.tags.get(PARENT_TAG).map(String::as_str) == Some(MUX_SESSION_NAME)
            && Some(&session.session_id) != self.mux_session.as_ref()
    }

    fn session_changed(&mut self, session: SessionSummary) {
        let before = self.session_status.insert(session.session_id.clone(), session.status);
        self.session_info.insert(session.session_id.clone(), session.clone());
        if !self.is_child(&session) {
            return;
        }
        let child_status = self.child(&session).status;
        if turn_ended(before, session.status) {
            self.child_finished(session);
        } else if session.status == SessionStatus::Running && child_status != WorkStatus::Running {
            self.edit_work(
                &session.session_id,
                &session.name,
                WorkStatus::Running,
                session.preview.as_deref(),
            );
        } else if matches!(session.status, SessionStatus::Closed | SessionStatus::Disconnected)
            && child_status == WorkStatus::Running
        {
            self.edit_work(
                &session.session_id,
                &session.name,
                WorkStatus::Failed,
                session.preview.as_deref(),
            );
        }
        self.flush_outbox();
    }

    /// The child's record, registered (with a work card) when new.
    fn child(&mut self, session: &SessionSummary) -> ChildRecord {
        if let Some(child) = self.state.children.get(&session.session_id) {
            return child.clone();
        }
        let running = self.folder.running().and_then(|t| t.prompt_id.clone());
        let conversation = self.conversation_for(running.as_deref()).unwrap_or_default();
        let child = ChildRecord {
            conversation: conversation.clone(),
            name: session.name.clone(),
            status: WorkStatus::Running,
            message_id: None,
            edits: 0,
        };
        self.state.children.insert(session.session_id.clone(), child.clone());
        if !conversation.is_empty() {
            let key = format!("work:{}", session.session_id);
            self.state.outbox.push(OutboxEntry {
                conversation,
                idempotency_key: key.clone(),
                rate_retried: false,
                not_before: None,
                op: Op::MessageSend {
                    client_msg_id: key,
                    parts: vec![work_part(
                        &session.name,
                        WorkStatus::Running,
                        session.last_prompt.as_deref(),
                    )],
                    reply_to: None,
                },
                child: Some(session.session_id.clone()),
            });
        }
        self.dirty = true;
        self.log(format!("child {} started ({})", session.name, session.session_id));
        child
    }

    fn edit_work(
        &mut self,
        session_id: &str,
        name: &str,
        status: WorkStatus,
        preview: Option<&str>,
    ) {
        let Some(child) = self.state.children.get_mut(session_id) else { return };
        child.status = status;
        child.edits += 1;
        if !child.conversation.is_empty() {
            let entry = OutboxEntry {
                conversation: child.conversation.clone(),
                idempotency_key: format!("work:{session_id}:{}", child.edits),
                rate_retried: false,
                not_before: None,
                op: Op::MessageEdit {
                    message_id: String::new(),
                    parts: vec![work_part(name, status, preview)],
                },
                child: Some(session_id.to_owned()),
            };
            self.state.outbox.push(entry);
        }
        self.dirty = true;
    }

    fn child_finished(&mut self, session: SessionSummary) {
        if self.acpmux_up {
            let after = self.child_turn_floor.get(&session.session_id).copied().unwrap_or(0);
            self.emit(Effect::FetchChildEvents { session_id: session.session_id.clone(), after });
            self.pending_children.insert(session.session_id.clone(), session);
        } else {
            self.finish_child(&session, "");
        }
    }

    fn finish_child(&mut self, session: &SessionSummary, reply: &str) {
        self.child_turn_floor.insert(session.session_id.clone(), session.last_seq.unwrap_or(0));
        let short = excerpt(reply, 200);
        let preview = if short.is_empty() { session.preview.clone() } else { Some(short) };
        self.edit_work(
            &session.session_id,
            &session.name,
            work_status(session.status),
            preview.as_deref(),
        );
        let conversation = self.child_conversation(&session.session_id);
        let prompt_id = format!(
            "child:{}:{}",
            session.session_id,
            session.turn_count.unwrap_or(session.state_seq)
        );
        let text = child_finished_prompt(session, reply);
        self.state
            .prompts
            .insert(prompt_id.clone(), OutstandingPrompt { conversation, text, seq: None });
        self.dirty = true;
        self.log(format!("child {} finished; telling the mux", session.name));
        self.send_prompt(&prompt_id);
    }

    fn child_conversation(&self, session_id: &str) -> String {
        self.state
            .children
            .get(session_id)
            .map(|c| c.conversation.clone())
            .filter(|c| !c.is_empty())
            .or_else(|| self.state.default_conversation.clone())
            .unwrap_or_default()
    }

    fn permission(&mut self, session_id: String, permission_id: String, request: Value) {
        let known =
            self.session_info.get(&session_id).is_some_and(|s| s.tags.contains_key(PARENT_TAG));
        if !known && self.acpmux_up {
            self.pending_permissions.push((session_id, permission_id, request));
            self.emit(Effect::FetchSessions);
            return;
        }
        self.on_permission(&session_id, &permission_id, &request);
    }

    fn sessions(&mut self, sessions: Vec<SessionSummary>) {
        for session in sessions {
            self.session_info.insert(session.session_id.clone(), session);
        }
        for (session_id, permission_id, request) in std::mem::take(&mut self.pending_permissions) {
            self.on_permission(&session_id, &permission_id, &request);
        }
    }

    fn on_permission(&mut self, session_id: &str, permission_id: &str, request: &Value) {
        let Some(session) = self.session_info.get(session_id).cloned() else { return };
        if !self.is_child(&session) {
            return;
        }
        self.child(&session);
        self.edit_work(session_id, &session.name, WorkStatus::Waiting, session.preview.as_deref());
        let prompt_id = format!("perm:{session_id}:{permission_id}");
        let conversation = self.child_conversation(session_id);
        let text = child_permission_prompt(&session, request);
        self.state
            .prompts
            .insert(prompt_id.clone(), OutstandingPrompt { conversation, text, seq: None });
        self.dirty = true;
        self.flush_outbox();
        self.send_prompt(&prompt_id);
    }

    /// After a reconnect: children whose turn ended while the host was away.
    fn reconcile_children(&mut self) {
        let children: Vec<(String, ChildRecord)> =
            self.state.children.iter().map(|(id, c)| (id.clone(), c.clone())).collect();
        for (session_id, child) in children {
            match self.session_info.get(&session_id).cloned() {
                None => {
                    if matches!(child.status, WorkStatus::Running | WorkStatus::Waiting) {
                        self.edit_work(&session_id, &child.name, WorkStatus::Failed, None);
                    }
                }
                Some(session) => {
                    if child.status == WorkStatus::Running
                        && matches!(session.status, SessionStatus::Ready | SessionStatus::Idle)
                    {
                        self.child_finished(session);
                    }
                }
            }
        }
        self.flush_outbox();
    }
}
