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
    /// A question hook's question (`live_question`), kept by the append's thread until its
    /// notification takes it, as a reply is.
    noted_questions: HashMap<TerminalPublicId, (std::thread::ThreadId, Arc<Value>)>,
    /// The question each terminal's agent waits on, with the ledger id of the notification
    /// that asked it: `list-notifications` shows it on that row until the agent moves on.
    questions: HashMap<TerminalPublicId, (String, Arc<Value>)>,
}

impl AgentTexts {
    pub(crate) fn forget(&mut self, terminal: &TerminalPublicId) {
        self.prompts.remove(terminal);
        self.replies.remove(terminal);
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

    /// Keeps `reply` (cut to `LIVE_MESSAGE_CHARS`) for `terminal`'s next agent notification.
    /// Returns whether it kept one, so the append can drop it again (`forget_agent_reply`).
    pub(crate) fn note_agent_reply(&self, terminal: &TerminalPublicId, reply: &str) -> bool {
        let Some(reply) = crate::agent_hooks::live_message_text(reply) else { return false };
        if self.resource_surface_for_terminal(terminal).is_none() {
            return false;
        }
        let mut texts = self.agent_prompts.lock().unwrap_or_else(PoisonError::into_inner);
        let owner = std::thread::current().id();
        texts.replies.insert(terminal.clone(), (owner, Arc::from(reply)));
        true
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
