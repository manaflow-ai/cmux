//! Each terminal agent's last prompt, for the hover card's task line (cx-swovq; Lawrence
//! 2026-10-14: "keep last prompt, memory only"). The hook helper reads it from a turn-start
//! hook before redaction and sends it beside the journal event (`session.journal.append`
//! `live_prompt`); the journal never sees it, nothing persists or logs it, and a daemon
//! restart, a closed terminal or an ended agent session forgets it.

use super::*;

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
        Some(self.agent_prompts.lock().unwrap().insert(terminal.clone(), Arc::from(prompt)))
    }

    /// Puts back what `note_agent_prompt` replaced.
    pub(crate) fn restore_agent_prompt(
        &self,
        terminal: &TerminalPublicId,
        previous: Option<Arc<str>>,
    ) {
        let mut prompts = self.agent_prompts.lock().unwrap();
        match previous {
            Some(previous) => prompts.insert(terminal.clone(), previous),
            None => prompts.remove(terminal),
        };
    }

    /// `terminal`'s last prompt, if its agent sent one since it started.
    pub(crate) fn agent_prompt(&self, terminal: &TerminalPublicId) -> Option<Arc<str>> {
        self.agent_prompts.lock().unwrap().get(terminal).cloned()
    }

    pub(super) fn forget_agent_prompt(&self, terminal: &TerminalPublicId) {
        self.agent_prompts.lock().unwrap().remove(terminal);
    }
}
