//! Each terminal agent's last prompt, for the hover card's task line (cx-swovq; Lawrence
//! 2026-10-14: "keep last prompt, memory only"). The hook helper reads it from a turn-start
//! hook before redaction and sends it beside the journal event (`session.journal.append`
//! `live_prompt`); the journal never sees it, nothing persists or logs it, and a daemon
//! restart, a closed terminal or an ended agent session forgets it.
//!
//! Its last reply rides the same way (`live_reply`, cx-kz6m0; Leo 2026-10-14: the turn-done
//! banner shows the agent's last message): kept from the append until the commit's
//! `notification` event takes it as the banner's `preview` (and, whole, as the phone Feed's
//! `message`, with the turn's whole `prompt` beside it), then gone.
//!
//! Both are kept whole, markdown and line breaks included, up to `LIVE_MESSAGE_CHARS`, for the
//! phone's Feed: a terminal agent's card shows the prompt and answer a GUI chat's does. The
//! hover card (`list-agents` `last_prompt`) and the banner's `preview` still get the folded,
//! 200-character cut. It never reaches the
//! notification ledger, which is durable. The reply belongs to the thread whose append kept
//! it, so another hook's append for the same terminal (a question, an approval) running at the
//! same time neither shows it nor drops it.
//!
//! The last reply also stays with its terminal after the banner took it (`last_replies`,
//! W3-H): `agent.list` and `session.snapshot` show it folded and cut to 200 characters as the
//! agent value's `extra.last_reply`, so `cmux terminal list --agents` names each agent's last
//! answer. Memory only like the rest: a daemon restart or a closed terminal forgets it.
//! `agent.list` for one terminal also shows it whole as `extra.last_reply_text`, with the
//! time the daemon kept it as `extra.last_reply_at_ms` (W5-Q), so `cmux terminal NAME send`
//! answers the reply of its own turn, not the screen's wrapped lines.
//!
//! The last harness session id stays with its terminal too (`last_sessions`, W3-H): an ended
//! session leaves the roster, so `session.snapshot` shows it on the terminal value's
//! `extra.agent_session_id` (and the harness on `extra.agent`), and `cmux agent resume` can
//! bring back an agent that quit. A closed terminal forgets it; a daemon restart takes it back
//! from the journal's agent roster (its hook session fences, W5-R).
//!
//! A question hook's question rides the same way (`live_question`, `agent_hook_question.rs`):
//! its notification takes it, and the terminal keeps it while the agent waits on it, so
//! `list-notifications` and the notification event can show the question and its options
//! (cmux-next-ios answers it from the phone). It never reaches the durable ledger.

use super::*;

/// The agent texts a terminal keeps in memory only.
#[derive(Default)]
pub(crate) struct AgentTexts {
    pub(crate) prompts: HashMap<TerminalPublicId, Arc<str>>,
    replies: HashMap<TerminalPublicId, (std::thread::ThreadId, Arc<str>)>,
    /// Each terminal's last finished turns' messages, kept after their banners took them, and
    /// when each was kept (Unix milliseconds), oldest first. The last one is the terminal's
    /// last reply. Older ones stay (at most `KEPT_REPLIES`) so that when an append fails or
    /// replays, removing only its own reply leaves the one before it, in whatever order
    /// racing appends of one terminal end.
    last_replies: HashMap<TerminalPublicId, Vec<(Arc<str>, u64)>>,
    /// Each terminal's last harness session id and harness, kept after the session ended.
    last_sessions: HashMap<TerminalPublicId, (Arc<str>, Option<Arc<str>>)>,
    /// A question hook's question (`live_question`), kept by the append's thread until its
    /// notification takes it, as a reply is.
    noted_questions: HashMap<TerminalPublicId, (std::thread::ThreadId, Arc<Value>)>,
    /// The question each terminal's agent waits on, with the ledger id of the notification
    /// that asked it: `list-notifications` shows it on that row until the agent moves on.
    questions: HashMap<TerminalPublicId, (String, Arc<Value>)>,
}

impl AgentTexts {
    /// The texts a daemon starts with: each terminal's last harness session id and harness
    /// from the journal's roster (`AgentRoster::hook_sessions`), less the local generation
    /// tokens of session-less adapters (`published_agent_session_id`).
    pub(crate) fn with_sessions(sessions: Vec<(String, String, Option<String>)>) -> Self {
        let last_sessions = sessions
            .into_iter()
            .filter_map(|(terminal, session, harness)| {
                let terminal = TerminalPublicId::parse(&terminal).ok()?;
                let session = published_agent_session_id(&terminal, &session)?;
                Some((terminal, (Arc::from(session.as_str()), harness.as_deref().map(Arc::from))))
            })
            .collect();
        Self { last_sessions, ..Self::default() }
    }

    pub(crate) fn forget(&mut self, terminal: &TerminalPublicId) {
        self.prompts.remove(terminal);
        self.replies.remove(terminal);
        self.last_replies.remove(terminal);
        self.last_sessions.remove(terminal);
        self.noted_questions.remove(terminal);
        self.questions.remove(terminal);
    }
}

impl Mux {
    /// Keeps `prompt` (cut to `LIVE_MESSAGE_CHARS`) as `terminal`'s last prompt when the
    /// terminal is live. Returns the prompt it replaced (`Some(None)` for none), so a failed or
    /// replayed append can put it back (`restore_agent_prompt`); `None` when nothing was kept.
    #[must_use]
    pub(crate) fn note_agent_prompt(
        &self,
        terminal: &TerminalPublicId,
        prompt: &str,
    ) -> Option<Option<Arc<str>>> {
        let prompt = crate::agent_hooks::live_message_text(prompt)?;
        self.resource_surface_for_terminal(terminal)?;
        Some(self.agent_prompts.lock().unwrap().prompts.insert(terminal.clone(), Arc::from(prompt)))
    }

    /// Puts back what `note_agent_prompt` replaced.
    pub(crate) fn restore_agent_prompt(
        &self,
        terminal: &TerminalPublicId,
        previous: Option<Arc<str>>,
    ) {
        let prompts = &mut self.agent_prompts.lock().unwrap().prompts;
        match previous {
            Some(previous) => prompts.insert(terminal.clone(), previous),
            None => prompts.remove(terminal),
        };
    }

    /// `terminal`'s last prompt for the hover card (folded, cut to `LIVE_PROMPT_CHARS`), if its
    /// agent sent one since it started.
    pub(crate) fn agent_prompt(&self, terminal: &TerminalPublicId) -> Option<Arc<str>> {
        let whole = self.agent_feed_prompt(terminal)?;
        crate::agent_hooks::live_prompt_text(&whole).map(Arc::from)
    }

    /// `terminal`'s last prompt whole (markdown, up to `LIVE_MESSAGE_CHARS`), for the phone
    /// Feed's quote of the turn a notification ends.
    pub(crate) fn agent_feed_prompt(&self, terminal: &TerminalPublicId) -> Option<Arc<str>> {
        self.agent_prompts
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .prompts
            .get(terminal)
            .cloned()
    }

    pub(super) fn forget_agent_prompt(&self, terminal: &TerminalPublicId) {
        self.agent_prompts.lock().unwrap().prompts.remove(terminal);
    }

    /// Keeps `reply` (cut to `LIVE_MESSAGE_CHARS`) for `terminal`'s next agent notification and
    /// as its last reply. Kept before the commit, so the agent change the commit folds already
    /// carries it. Returns what it kept, so the append drops the notification's copy
    /// (`forget_agent_reply`) and a failed or replayed append drops it as the last reply
    /// (`restore_agent_reply`); `None` when nothing was kept.
    #[must_use]
    pub(crate) fn note_agent_reply(
        &self,
        terminal: &TerminalPublicId,
        reply: &str,
    ) -> Option<NotedReply> {
        let reply = crate::agent_hooks::live_message_text(reply)?;
        self.resource_surface_for_terminal(terminal)?;
        let mut texts = self.agent_prompts.lock().unwrap_or_else(PoisonError::into_inner);
        let owner = std::thread::current().id();
        let reply: Arc<str> = Arc::from(reply);
        let kept = texts.last_replies.entry(terminal.clone()).or_default();
        kept.push((Arc::clone(&reply), now_ms()));
        let over = kept.len().saturating_sub(KEPT_REPLIES);
        kept.drain(..over);
        texts.replies.insert(terminal.clone(), (owner, Arc::clone(&reply)));
        Some(NotedReply { kept: reply })
    }

    /// Drops the reply `noted` kept, after its append failed or replayed (a hook's retry of an
    /// older turn): the terminal's last reply is then the newest other kept one, whichever
    /// appends of the terminal end first.
    pub(crate) fn restore_agent_reply(&self, terminal: &TerminalPublicId, noted: NotedReply) {
        let mut texts = self.agent_prompts.lock().unwrap_or_else(PoisonError::into_inner);
        let Some(kept) = texts.last_replies.get_mut(terminal) else { return };
        kept.retain(|(reply, _)| !Arc::ptr_eq(reply, &noted.kept));
        if kept.is_empty() {
            texts.last_replies.remove(terminal);
        }
    }

    /// Every terminal's last reply, folded and cut to `LIVE_PROMPT_CHARS`, keyed by terminal
    /// id, for `extra.last_reply`. Read before a registry projection lock is taken: this lock
    /// is never held across another `Mux` lock.
    pub(crate) fn agent_last_replies(&self) -> HashMap<String, String> {
        let texts = self.agent_prompts.lock().unwrap_or_else(PoisonError::into_inner);
        texts
            .last_replies
            .iter()
            .filter_map(|(terminal, kept)| {
                let (reply, _) = kept.last()?;
                Some((terminal.to_string(), crate::agent_hooks::live_prompt_text(reply)?))
            })
            .collect()
    }

    /// `terminal`'s last reply whole (markdown, up to `LIVE_MESSAGE_CHARS`) and when it was
    /// kept, for a one-terminal `agent.list` ([`with_last_reply_text`]). Read before a
    /// registry projection lock is taken, as [`Mux::agent_last_replies`] is.
    pub(crate) fn agent_last_reply_text(&self, terminal: &TerminalPublicId) -> Option<LastReply> {
        let texts = self.agent_prompts.lock().unwrap_or_else(PoisonError::into_inner);
        texts
            .last_replies
            .get(terminal)
            .and_then(|kept| kept.last())
            .map(|(reply, at_ms)| LastReply { text: reply.to_string(), at_ms: *at_ms })
    }

    /// The kept replies an `agent.list` adds ([`with_agent_list_replies`]): every terminal's
    /// folded reply and, for a one-terminal list (`terminal`), that terminal's reply whole.
    pub(crate) fn agent_list_replies(
        &self,
        terminal: Option<&TerminalPublicId>,
    ) -> AgentListReplies {
        AgentListReplies {
            folded: self.agent_last_replies(),
            whole: terminal.and_then(|terminal| self.agent_last_reply_text(terminal)),
        }
    }

    /// Keeps `session_id` (and its `harness`) as the last harness session of `terminal`.
    pub(super) fn note_agent_session(
        &self,
        terminal: &TerminalPublicId,
        session_id: &str,
        harness: Option<&str>,
    ) {
        let mut texts = self.agent_prompts.lock().unwrap_or_else(PoisonError::into_inner);
        texts
            .last_sessions
            .insert(terminal.clone(), (Arc::from(session_id), harness.map(Arc::from)));
    }

    /// Every terminal's last harness session id and harness, keyed by terminal id, for the
    /// terminal value's `extra`. Read before a registry projection lock is taken, as
    /// [`Mux::agent_last_replies`] is.
    pub(crate) fn agent_last_sessions(&self) -> HashMap<String, (String, Option<String>)> {
        let texts = self.agent_prompts.lock().unwrap_or_else(PoisonError::into_inner);
        texts
            .last_sessions
            .iter()
            .map(|(terminal, (session, harness))| {
                (terminal.to_string(), (session.to_string(), harness.as_deref().map(str::to_owned)))
            })
            .collect()
    }

    /// The reply this thread's append kept for `terminal`, taken: one banner shows it.
    pub(super) fn take_agent_reply(&self, terminal: &TerminalPublicId) -> Option<Arc<str>> {
        self.remove_own_reply(terminal)
    }

    /// Drops a reply no notification took (the append failed, replayed or posted nothing).
    pub(crate) fn forget_agent_reply(&self, terminal: &TerminalPublicId) {
        self.remove_own_reply(terminal);
    }

    fn remove_own_reply(&self, terminal: &TerminalPublicId) -> Option<Arc<str>> {
        let mut texts = self.agent_prompts.lock().unwrap_or_else(PoisonError::into_inner);
        let owner = std::thread::current().id();
        if texts.replies.get(terminal).is_none_or(|(kept_by, _)| *kept_by != owner) {
            return None;
        }
        texts.replies.remove(terminal).map(|(_, reply)| reply)
    }

    /// Keeps a question hook's question (`live_question`, checked by `kept_question`) for
    /// `terminal`'s next agent notification. Returns whether it kept one.
    pub(crate) fn note_agent_question(&self, terminal: &TerminalPublicId, text: &str) -> bool {
        let Some(question) = crate::agent_hook_question::kept_question(text) else { return false };
        if self.resource_surface_for_terminal(terminal).is_none() {
            return false;
        }
        let mut texts = self.agent_prompts.lock().unwrap_or_else(PoisonError::into_inner);
        let owner = std::thread::current().id();
        texts.noted_questions.insert(terminal.clone(), (owner, Arc::new(question)));
        true
    }

    /// The question this thread's append kept for `terminal`, taken by its notification
    /// (`ledger_id`), which shows it from now on.
    pub(super) fn take_agent_question(
        &self,
        terminal: &TerminalPublicId,
        ledger_id: &str,
    ) -> Option<Arc<Value>> {
        let mut texts = self.agent_prompts.lock().unwrap_or_else(PoisonError::into_inner);
        let owner = std::thread::current().id();
        if texts.noted_questions.get(terminal).is_none_or(|(kept_by, _)| *kept_by != owner) {
            return None;
        }
        let (_, mut question) = texts.noted_questions.remove(terminal)?;
        // The same question's second hook (PermissionRequest) names no tool use: it keeps
        // the first hook's, so the phone still matches an answer to it.
        if let Some((_, previous)) = texts.questions.get(terminal) {
            let mut carried = (*question).clone();
            crate::agent_hook_question::carry_tool_use_id(&mut carried, Some(previous));
            question = Arc::new(carried);
        }
        texts.questions.insert(terminal.clone(), (ledger_id.to_owned(), Arc::clone(&question)));
        Some(question)
    }

    /// Drops a question no notification took (the append failed, replayed or posted nothing).
    pub(crate) fn forget_noted_agent_question(&self, terminal: &TerminalPublicId) {
        let mut texts = self.agent_prompts.lock().unwrap_or_else(PoisonError::into_inner);
        let owner = std::thread::current().id();
        if texts.noted_questions.get(terminal).is_some_and(|(kept_by, _)| *kept_by == owner) {
            texts.noted_questions.remove(terminal);
        }
    }

    /// The agent left its question (working again, idle, done): it no longer waits on it.
    pub(super) fn forget_agent_question(&self, terminal: &TerminalPublicId) {
        self.agent_prompts
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .questions
            .remove(terminal);
    }

    /// The question the notification `ledger_id` of `terminal` asked, while its agent still
    /// waits on it.
    pub(crate) fn pending_agent_question(
        &self,
        terminal: &TerminalPublicId,
        ledger_id: &str,
    ) -> Option<Arc<Value>> {
        let texts = self.agent_prompts.lock().unwrap_or_else(PoisonError::into_inner);
        texts
            .questions
            .get(terminal)
            .filter(|(asked_by, _)| asked_by == ledger_id)
            .map(|(_, question)| Arc::clone(question))
    }
}

/// Adds `extra.last_reply` to a public agent value (`agent.list`, `session.snapshot`) whose
/// terminal has a kept reply in `replies` ([`Mux::agent_last_replies`]). Values without one
/// stay as they are, so older readers see no change.
pub(crate) fn with_last_reply(mut agent: Value, replies: &HashMap<String, String>) -> Value {
    let reply = agent.get("terminal_id").and_then(Value::as_str).and_then(|id| replies.get(id));
    if let (Some(reply), Some(extra)) =
        (reply, agent.get_mut("extra").and_then(Value::as_object_mut))
    {
        extra.insert("last_reply".into(), Value::String(reply.clone()));
    }
    agent
}

/// A reply [`Mux::note_agent_reply`] kept as a terminal's last reply, for
/// [`Mux::restore_agent_reply`] (it is found by pointer, so an equal text of another turn is
/// not taken for it).
pub(crate) struct NotedReply {
    kept: Arc<str>,
}

/// How many kept replies a terminal holds: its last reply and the ones before it, for appends
/// that are still running when a newer one keeps its reply. Hook appends of one terminal run
/// one or two at a time.
const KEPT_REPLIES: usize = 4;

/// A terminal's last reply whole and when the daemon kept it ([`Mux::agent_last_reply_text`]).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct LastReply {
    pub(crate) text: String,
    /// Unix milliseconds.
    pub(crate) at_ms: u64,
}

/// Adds `extra.last_reply_text` (the reply whole) and `extra.last_reply_at_ms` (a decimal
/// string, like `updated_at_ms`) to a public agent value of `reply`'s terminal. A one-terminal
/// `agent.list` shows them; session-wide lists keep the folded `extra.last_reply` only.
pub(crate) fn with_last_reply_text(mut agent: Value, reply: Option<&LastReply>) -> Value {
    let Some(reply) = reply else { return agent };
    let Some(object) = agent.as_object_mut() else { return agent };
    let extra = object.entry("extra").or_insert_with(|| Value::Object(Map::new()));
    if let Some(extra) = extra.as_object_mut() {
        extra.insert("last_reply_text".into(), Value::String(reply.text.clone()));
        extra.insert("last_reply_at_ms".into(), Value::String(reply.at_ms.to_string()));
    }
    agent
}

/// The kept replies of one `agent.list` request ([`Mux::agent_list_replies`]).
pub(crate) struct AgentListReplies {
    folded: HashMap<String, String>,
    whole: Option<LastReply>,
}

/// Adds the kept replies to a public agent value of `agent.list`: `extra.last_reply`
/// ([`with_last_reply`]) and, for a one-terminal list, the reply whole
/// ([`with_last_reply_text`]).
pub(crate) fn with_agent_list_replies(agent: Value, replies: &AgentListReplies) -> Value {
    with_last_reply_text(with_last_reply(agent, &replies.folded), replies.whole.as_ref())
}

/// Adds the terminal's kept harness session id ([`Mux::agent_last_sessions`]) to a public agent
/// value (`agent.list`, `session.snapshot`) that names none: a screen-detection report after a
/// daemon restart replaces the hook's record without it (W5-R, bench round 4 A6). A value with
/// its own id keeps it.
pub(crate) fn with_kept_session(
    mut agent: Value,
    sessions: &HashMap<String, (String, Option<String>)>,
) -> Value {
    let kept = agent.get("terminal_id").and_then(Value::as_str).and_then(|id| sessions.get(id));
    if let (Some((session, _)), Some(extra)) =
        (kept, agent.get_mut("extra").and_then(Value::as_object_mut))
        && extra.get("agent_session_id").is_none_or(|value| value.as_str().is_none())
    {
        extra.insert("agent_session_id".into(), Value::String(session.clone()));
    }
    agent
}

/// Adds `extra.agent_session_id` (and `extra.agent`, the harness) to a public terminal value
/// whose terminal has a kept harness session in `sessions` ([`Mux::agent_last_sessions`]).
pub(crate) fn with_agent_session(
    mut terminal: Value,
    sessions: &HashMap<String, (String, Option<String>)>,
) -> Value {
    let Some((session, harness)) =
        terminal.get("id").and_then(Value::as_str).and_then(|id| sessions.get(id))
    else {
        return terminal;
    };
    let Some(object) = terminal.as_object_mut() else { return terminal };
    let extra = object.entry("extra").or_insert_with(|| Value::Object(Map::new()));
    if let Some(extra) = extra.as_object_mut() {
        extra.insert("agent_session_id".into(), Value::String(session.clone()));
        if let Some(harness) = harness {
            extra.insert("agent".into(), Value::String(harness.clone()));
        }
    }
    terminal
}

#[cfg(test)]
mod w3h_last_reply_tests {
    use super::*;
    use crate::workspace_registry::WorkspaceRegistry;
    use crate::{Mux, SurfaceOptions};

    /// W3-H: the last reply stays after its banner dropped it, folded and cut for
    /// `extra.last_reply`, and only the agent value of its terminal carries it.
    #[test]
    fn w3h_last_reply_outlives_the_banner_and_rides_on_the_agent_value() {
        let root = std::env::temp_dir()
            .join(format!("cmux-last-reply-{}", crate::workspace_registry::new_uuid_v4()));
        let registry = WorkspaceRegistry::open(&root, "last-reply").unwrap();
        let mux = Mux::from_workspace_registry(
            "last-reply".to_owned(),
            SurfaceOptions::default(),
            registry,
            ProviderWorkspaceState::default(),
            true,
        )
        .unwrap();
        let surface = mux.new_workspace(None, None).unwrap();
        let terminal = surface.terminal_public_id().cloned().unwrap();
        assert!(mux.agent_last_replies().is_empty());

        assert!(mux.note_agent_reply(&terminal, "Done.\n\n  ALPHA_OK").is_some());
        // The append ends: whatever the banner did not take is dropped.
        mux.forget_agent_reply(&terminal);
        let replies = mux.agent_last_replies();
        assert_eq!(replies.get(terminal.as_str()).map(String::as_str), Some("Done. ALPHA_OK"));

        let long = "word ".repeat(200);
        assert!(mux.note_agent_reply(&terminal, &long).is_some());
        let kept = mux.agent_last_replies().remove(terminal.as_str()).unwrap();
        assert!(kept.chars().count() <= crate::agent_hooks::LIVE_PROMPT_CHARS, "{kept}");

        let agent =
            serde_json::json!({"terminal_id": terminal.as_str(), "extra": {"agent": "claude"}});
        let shown = with_last_reply(agent, &mux.agent_last_replies());
        assert_eq!(shown["extra"]["last_reply"], kept);
        let other = serde_json::json!({"terminal_id": "term_other", "extra": {}});
        assert!(with_last_reply(other, &replies)["extra"].get("last_reply").is_none());
        let _ = std::fs::remove_dir_all(root);
    }
}
