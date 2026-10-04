//! Child agents (sessions tagged mux.parent=mux): work cards, finishes, permissions, reconcile.

use cmux_conversation::{Op, WorkStatus};
use serde_json::Value;

use super::{Core, Effect, PendingPermission};
use crate::acp::{SessionStatus, SessionSummary};
use crate::rules::{
    MUX_SESSION_NAME, PARENT_TAG, child_finished_prompt, child_permission_prompt, excerpt,
    turn_ended, work_part, work_status,
};
use crate::state::{ChildRecord, MAX_CHILDREN, OutboxEntry};

impl Core {
    pub(super) fn is_child(&self, session: &SessionSummary) -> bool {
        session.tags.get(PARENT_TAG).map(String::as_str) == Some(MUX_SESSION_NAME)
            && Some(&session.session_id) != self.mux_session.as_ref()
    }

    pub(super) fn session_changed(&mut self, session: SessionSummary) {
        // A child's finish waits for its events: its later changes wait
        // behind it, in order.
        if self.held_changes.contains_key(&session.session_id)
            || self.pending_children.contains_key(&session.session_id)
        {
            self.held_changes.entry(session.session_id.clone()).or_default().push_back(session);
            return;
        }
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

    /// Replays a child's held changes after its finish, until one starts
    /// another finish.
    pub(super) fn replay_held(&mut self, session_id: &str) {
        let Some(mut held) = self.held_changes.remove(session_id) else { return };
        while let Some(next) = held.pop_front() {
            self.session_changed(next);
            if self.pending_children.contains_key(session_id) {
                if !held.is_empty() {
                    self.held_changes.insert(session_id.to_owned(), held);
                }
                return;
            }
        }
    }

    /// Past `MAX_CHILDREN`: drops the oldest finished children that no
    /// queued op names (order, absent as 0, then id).
    fn prune_children(&mut self) {
        let count = self.state.children.len();
        if count <= MAX_CHILDREN {
            return;
        }
        let queued: std::collections::BTreeSet<&str> =
            self.state.outbox.iter().filter_map(|entry| entry.child.as_deref()).collect();
        let mut prunable: Vec<(u64, String)> = self
            .state
            .children
            .iter()
            .filter(|(id, child)| {
                matches!(child.status, WorkStatus::Done | WorkStatus::Failed)
                    && !queued.contains(id.as_str())
            })
            .map(|(id, child)| (child.order.unwrap_or(0), id.clone()))
            .collect();
        prunable.sort();
        for (_, id) in prunable.into_iter().take(count - MAX_CHILDREN) {
            self.state.children.remove(&id);
            self.log(format!("pruned child {id} (more than {MAX_CHILDREN} children)"));
        }
    }

    /// The child's record, registered (with a work card in the conversation
    /// the Chief is answering) when new.
    pub(super) fn child(&mut self, session: &SessionSummary) -> ChildRecord {
        if let Some(child) = self.state.children.get(&session.session_id) {
            return child.clone();
        }
        let running = self.folder.running().and_then(|t| t.prompt_id.clone());
        let conversation = self.conversation_for(running.as_deref()).unwrap_or_default();
        // A child first seen ready or idle gets a done card (closed: failed,
        // waiting: waiting).
        let status = work_status(session.status);
        let order = self.state.children.values().filter_map(|c| c.order).max().unwrap_or(0) + 1;
        let child = ChildRecord {
            conversation: conversation.clone(),
            name: session.name.clone(),
            status,
            message_id: None,
            edits: 0,
            order: Some(order),
        };
        self.state.children.insert(session.session_id.clone(), child.clone());
        self.prune_children();
        if !conversation.is_empty() {
            let key = format!("work:{}", session.session_id);
            self.state.outbox.push(OutboxEntry {
                conversation,
                idempotency_key: key.clone(),
                rate_retried: false,
                not_before: None,
                op: Op::MessageSend {
                    client_msg_id: key,
                    parts: vec![work_part(&session.name, status, session.last_prompt.as_deref())],
                    reply_to: None,
                },
                child: Some(session.session_id.clone()),
            });
        }
        self.dirty = true;
        self.log(format!("child {} started ({})", session.name, session.session_id));
        child
    }

    pub(super) fn edit_work(
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

    pub(super) fn child_finished(&mut self, session: SessionSummary) {
        if self.acpmux_up {
            let after = self.child_turn_floor.get(&session.session_id).copied().unwrap_or(0);
            self.emit(Effect::FetchChildEvents { session_id: session.session_id.clone(), after });
            self.pending_children.insert(session.session_id.clone(), session);
        } else {
            self.finish_child(&session, "");
        }
    }

    pub(super) fn finish_child(&mut self, session: &SessionSummary, reply: &str) {
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
        self.record_prompt(prompt_id.clone(), conversation, text, None);
        self.dirty = true;
        self.log(format!("child {} finished; telling the mux", session.name));
        self.send_prompt(&prompt_id);
    }

    pub(super) fn child_conversation(&self, session_id: &str) -> String {
        self.state
            .children
            .get(session_id)
            .map(|c| c.conversation.clone())
            .filter(|c| !c.is_empty())
            .or_else(|| self.default_conversation())
            .unwrap_or_default()
    }

    pub(super) fn permission(&mut self, session_id: String, permission_id: String, request: Value) {
        let known = self.session_info.get(&session_id).cloned();
        let tagged = known
            .as_ref()
            .is_some_and(|s| s.tags.get(PARENT_TAG).is_some_and(|tag| !tag.is_empty()));
        if !tagged && self.acpmux_up {
            // Not known as a child yet: look it up in a fresh session list.
            self.pending_permissions.push(PendingPermission { session_id, permission_id, request });
            self.emit(Effect::FetchSessions);
            return;
        }
        self.on_permission(known.as_ref(), &session_id, &permission_id, &request);
    }

    /// The fetched list answers the pending permissions only; it does not
    /// replace the session info that `session_changed` keeps.
    pub(super) fn sessions(&mut self, sessions: &[SessionSummary]) {
        for pending in std::mem::take(&mut self.pending_permissions) {
            let session = sessions.iter().find(|s| s.session_id == pending.session_id);
            self.on_permission(
                session,
                &pending.session_id,
                &pending.permission_id,
                &pending.request,
            );
        }
    }

    pub(super) fn on_permission(
        &mut self,
        session: Option<&SessionSummary>,
        session_id: &str,
        permission_id: &str,
        request: &Value,
    ) {
        let Some(session) = session.filter(|s| self.is_child(s)).cloned() else { return };
        let known = self.state.children.contains_key(session_id);
        // A child first seen waiting already got a waiting card: no second,
        // identical edit.
        if known || self.child(&session).status != WorkStatus::Waiting {
            self.edit_work(
                session_id,
                &session.name,
                WorkStatus::Waiting,
                session.preview.as_deref(),
            );
        }
        let prompt_id = format!("perm:{session_id}:{permission_id}");
        let conversation = self.child_conversation(session_id);
        let text = child_permission_prompt(&session, request);
        self.record_prompt(prompt_id.clone(), conversation, text, None);
        self.dirty = true;
        self.flush_outbox();
        self.send_prompt(&prompt_id);
    }

    /// After a reconnect: children whose turn ended (or whose session is
    /// gone) while the host was away, in id order.
    pub(super) fn reconcile_children(&mut self) {
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
                    // A turn (or a permission wait) that ended while the host was away.
                    if matches!(child.status, WorkStatus::Running | WorkStatus::Waiting)
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

/// The session of a `perm:<session>:<permission>` prompt id: the permission
/// id is after the last ':'.
pub fn permission_session(prompt_id: &str) -> Option<&str> {
    let rest = prompt_id.strip_prefix("perm:")?;
    rest.rfind(':').map(|last| &rest[..last])
}
