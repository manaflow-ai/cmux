//! The acpmux port: connect (log identity, reply-key epochs, resend), turn folding, replies and typing.

use cmux_conversation::{Op, Part};

use super::{Connect, Core, Effect, InboxItem, Port, permission_session};
use crate::acp::{AcpmuxEvent, SessionStatus, SessionSummary, TurnFolder, TurnOutput, js_trim};
use crate::rules::turn_key;
use crate::state::OutboxEntry;

impl Core {
    /// Reply keys and the log identity. The log identity is the `at` of the
    /// log's seq 1 event (`log_id`, else a replayed seq 1 event). A reset is
    /// a log whose turn seqs may repeat keys already used:
    /// - same session: `cursor_reset` (acpmux refused the saved cursor) or a
    ///   known identity that differs from host.json's `acpmuxLog` (a host.json
    ///   without one, from before it existed, adopts the identity with no
    ///   reset); the epoch becomes max(identity + 1, else now; the previous
    ///   epoch + 1), so a repeated import of the same bundle still gets a
    ///   new epoch, and no epoch an older core used repeats;
    /// - a session host.json does not know (a lost or replaced host.json)
    ///   with a non-empty log, unless the shell created it on this connect
    ///   (`created`: a new log, whose only event is acpmux's created event):
    ///   earlier epochs are unknown, so the epoch is now.
    ///
    /// Keys are `turn:<session>:<seq>` while no reset happened (the identity
    /// equals host.json's), else `turn:<session>:<epoch>:<seq>`. The replay
    /// of a reset posts no promptless turn; turns of prompts the core no
    /// longer holds never post (`turn_conversation`).
    pub(super) fn acpmux_connected(
        &mut self,
        session_id: String,
        sessions: Vec<SessionSummary>,
        events: &[AcpmuxEvent],
        connect: Connect,
    ) {
        let Connect { cursor_reset, log_id, created } = connect;
        if self.acpmux_up {
            self.disconnected(Port::Acpmux);
        }
        let identity = log_id.or_else(|| {
            events.first().filter(|first| first.valid && first.seq == 1).and_then(|first| first.at)
        });
        let mut reset = false;
        if self.state.mux_session_id.as_deref() != Some(session_id.as_str()) {
            self.state.mux_session_id = Some(session_id.clone());
            self.state.acpmux_seq = 0;
            self.state.acpmux_epoch = None;
            self.state.acpmux_log = None;
            if identity.is_some() && !created {
                reset = true;
                self.state.acpmux_epoch = Some(self.now);
            }
            self.dirty = true;
        } else if cursor_reset
            // A legacy host.json (no acpmuxLog) adopts the identity below
            // without a reset.
            || (identity.is_some()
                && self.state.acpmux_log.is_some()
                && identity != self.state.acpmux_log)
        {
            reset = true;
            self.state.acpmux_seq = 0;
            // identity + 1: an older core used the identity itself as the
            // first epoch (downgrade-safe).
            let candidate = identity.map_or(self.now, |identity| identity.saturating_add(1));
            self.state.acpmux_epoch = Some(match self.state.acpmux_epoch {
                Some(previous) => candidate.max(previous.saturating_add(1)),
                None => candidate,
            });
            self.dirty = true;
        }
        if identity.is_some() && identity != self.state.acpmux_log {
            self.state.acpmux_log = identity;
            self.dirty = true;
        }
        self.mux_session = Some(session_id);
        // The connect's waiting sessions: they keep their permission prompts
        // and answer permissions that waited.
        let waiting: Vec<SessionSummary> =
            sessions.iter().filter(|s| s.status == SessionStatus::Waiting).cloned().collect();
        for session in sessions {
            self.session_status.insert(session.session_id.clone(), session.status);
            self.session_info.insert(session.session_id.clone(), session);
        }
        self.folder = TurnFolder::new(self.state.acpmux_seq);
        self.reset_replay = reset;
        for event in events {
            self.apply_mux_event(event);
        }
        self.reset_replay = false;
        self.acpmux_up = true;
        // A permission prompt whose session is not waiting in this list was
        // answered meanwhile (or the session is gone): dropped, not resent.
        // (The `sessions` reply path keeps its rule: acpmux's event order
        // there is not confirmed.) The prompt of the turn that runs now is
        // kept (its reply still posts) and not resent.
        let running = self.folder.running().and_then(|turn| turn.prompt_id.clone());
        let mut kept_running: Option<String> = None;
        let stale: Vec<String> = self
            .state
            .prompts
            .keys()
            .filter(|id| {
                id.starts_with("perm:")
                    && !permission_session(id)
                        .is_some_and(|session| waiting.iter().any(|s| s.session_id == session))
            })
            .filter(|id| {
                let is_running = running.as_deref() == Some(id.as_str());
                if is_running {
                    kept_running = Some((*id).clone());
                }
                !is_running
            })
            .cloned()
            .collect();
        for prompt_id in stale {
            self.state.prompts.remove(&prompt_id);
            self.prompt_rejections.remove(&prompt_id);
            self.dirty = true;
            self.log(format!("dropping permission prompt {prompt_id}: its session is not waiting"));
        }
        // Prompts acpmux may have dropped with an old connection, in
        // recorded order (absent = 0), then id.
        let mut outstanding: Vec<(u64, String)> = self
            .state
            .prompts
            .iter()
            .map(|(id, prompt)| (prompt.order.unwrap_or(0), id.clone()))
            .collect();
        outstanding.sort();
        for (_, prompt_id) in outstanding {
            if kept_running.as_deref() != Some(prompt_id.as_str()) {
                self.send_prompt(&prompt_id);
            }
        }
        // Permissions that waited for a session list (a failed fetch, or the
        // last connection's loss).
        if !self.pending_permissions.is_empty() {
            // One whose session is no longer waiting was answered meanwhile.
            self.sessions(&waiting);
        }
        self.reconcile_children();
        if self.daemon_up {
            self.inbox.push_back(InboxItem::CatchUpAll);
        }
    }

    pub(super) fn apply_mux_event(&mut self, event: &AcpmuxEvent) {
        if !event.valid {
            self.log(format!(
                "dropping acpmux event {}: seq and at must be non-negative integers",
                event.kind
            ));
            return;
        }
        // A new log's first event names it (acpmuxLog), so a later connect
        // can compare.
        if event.seq == 1
            && let Some(at) = event.at
            && self.state.acpmux_log.is_none()
        {
            self.state.acpmux_log = Some(at);
            self.dirty = true;
        }
        for output in self.folder.apply(event) {
            match output {
                TurnOutput::Accepted { prompt_id, .. } => {
                    self.prompt_rejections.remove(&prompt_id);
                    self.accept(&prompt_id);
                }
                TurnOutput::Started { turn, .. } => {
                    if let Some(conversation) = self.turn_conversation(turn.prompt_id.as_deref()) {
                        self.set_typing(&conversation, true);
                    }
                }
                TurnOutput::Ended { turn, seq, error } => {
                    let conversation = self.turn_conversation(turn.prompt_id.as_deref());
                    let mut text = js_trim(&turn.text).to_owned();
                    if text.is_empty()
                        && let Some(error) = error
                    {
                        text = format!("(turn failed: {error})");
                    }
                    if conversation.is_none() && turn.prompt_id.is_none() && self.reset_replay {
                        self.log(format!(
                            "turn {} replayed after a reset has no prompt; reply not posted",
                            turn.turn_seq
                        ));
                    }
                    if conversation.is_none()
                        && let Some(prompt_id) = &turn.prompt_id
                    {
                        self.log(format!(
                            "turn {} answers prompt {prompt_id}, which is answered or lost; reply not posted",
                            turn.turn_seq
                        ));
                    }
                    if let Some(conversation) = &conversation
                        && !text.is_empty()
                    {
                        let key = turn_key(
                            self.mux_session.as_deref().unwrap_or(""),
                            turn.turn_seq,
                            self.state.acpmux_epoch,
                        );
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
                        self.prompt_rejections.remove(prompt_id);
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

    /// The default conversation; an empty one is none.
    pub(super) fn default_conversation(&self) -> Option<String> {
        self.state.default_conversation.clone().filter(|c| !c.is_empty())
    }

    /// Where a turn's typing and reply go: its prompt's conversation, the
    /// default one for a turn without a prompt (none while replaying a reset
    /// log), and none for a prompt the core no longer holds (answered, or
    /// lost): a replayed old turn posts nothing.
    pub(super) fn turn_conversation(&self, prompt_id: Option<&str>) -> Option<String> {
        let Some(prompt_id) = prompt_id.filter(|id| !id.is_empty()) else {
            return if self.reset_replay { None } else { self.default_conversation() };
        };
        // An answered prompt's turn was posted already (a reset replay meets
        // it again).
        if self.state.is_answered(prompt_id) {
            return None;
        }
        let entry = self.state.prompts.get(prompt_id)?;
        Some(entry.conversation.clone())
            .filter(|c| !c.is_empty())
            .or_else(|| self.default_conversation())
    }

    pub(super) fn conversation_for(&self, prompt_id: Option<&str>) -> Option<String> {
        prompt_id
            .filter(|id| !id.is_empty())
            .and_then(|id| self.state.prompts.get(id))
            .map(|p| p.conversation.clone())
            .filter(|c| !c.is_empty())
            .or_else(|| self.default_conversation())
    }

    pub(super) fn set_typing(&mut self, conversation: &str, on: bool) {
        self.typing_in = on.then(|| conversation.to_owned());
        if self.daemon_up {
            self.emit(Effect::Typing { conversation: conversation.to_owned(), on });
        }
    }
}
