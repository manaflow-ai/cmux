//! Each terminal agent's last prompt, for the hover card's task line (cx-swovq; Lawrence
//! 2026-10-14: "keep last prompt, memory only"). The hook helper reads it from a turn-start
//! hook before redaction and sends it beside the journal event (`session.journal.append`
//! `live_prompt`); the journal never sees it, nothing persists or logs it, and a daemon
//! restart, a closed terminal or an ended agent session forgets it.
//!
//! Its last reply rides the same way (`live_reply`, cx-kz6m0; Leo 2026-10-14: the turn-done
//! banner shows the agent's last message): kept from the append until the commit's
//! `notification` event takes it as the banner's `preview`, then gone. It never reaches the
//! notification ledger, which is durable. The reply belongs to the thread whose append kept
//! it, so another hook's append for the same terminal (a question, an approval) running at the
//! same time neither shows it nor drops it.

use super::*;

/// The agent texts a terminal keeps in memory only.
#[derive(Default)]
pub(crate) struct AgentTexts {
    pub(crate) prompts: HashMap<TerminalPublicId, Arc<str>>,
    replies: HashMap<TerminalPublicId, (std::thread::ThreadId, Arc<str>)>,
}

impl AgentTexts {
    pub(crate) fn forget(&mut self, terminal: &TerminalPublicId) {
        self.prompts.remove(terminal);
        self.replies.remove(terminal);
    }
}

impl Mux {
    /// Keeps `prompt` (cut to `LIVE_PROMPT_CHARS`) as `terminal`'s last prompt when the
    /// terminal is live. Returns the prompt it replaced (`Some(None)` for none), so a failed or
    /// replayed append can put it back (`restore_agent_prompt`); `None` when nothing was kept.
    #[must_use]
    pub(crate) fn note_agent_prompt(
        &self,
        terminal: &TerminalPublicId,
        prompt: &str,
    ) -> Option<Option<Arc<str>>> {
        let prompt = crate::agent_hooks::live_prompt_text(prompt)?;
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

    /// `terminal`'s last prompt, if its agent sent one since it started.
    pub(crate) fn agent_prompt(&self, terminal: &TerminalPublicId) -> Option<Arc<str>> {
        self.agent_prompts.lock().unwrap().prompts.get(terminal).cloned()
    }

    pub(super) fn forget_agent_prompt(&self, terminal: &TerminalPublicId) {
        self.agent_prompts.lock().unwrap().prompts.remove(terminal);
    }

    /// Keeps `reply` (cut to `LIVE_PROMPT_CHARS`) for `terminal`'s next agent notification.
    /// Returns whether it kept one, so the append can drop it again (`forget_agent_reply`).
    pub(crate) fn note_agent_reply(&self, terminal: &TerminalPublicId, reply: &str) -> bool {
        let Some(reply) = crate::agent_hooks::live_prompt_text(reply) else { return false };
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
}
