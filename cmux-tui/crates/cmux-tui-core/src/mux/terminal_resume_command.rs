//! A terminal's resume command (`set-terminal-resume-command`,
//! `terminal-resume-command-v1`): stored with the terminal
//! (`terminal_resume_command_store`), shown on its tabs as `resume_command`,
//! and run in its new shell when the terminal restarts
//! (`terminal_respawn/prefill.rs`).

use super::*;

impl Mux {
    /// Set (`Some`) or clear (`None`) the resume command of hosted terminal
    /// `terminal_id` (the stable host id), then push the tree so every tab of
    /// the terminal shows it. Returns the stored command.
    pub fn set_terminal_resume_command(
        &self,
        terminal_id: &str,
        command: Option<&str>,
    ) -> anyhow::Result<Option<String>> {
        let stored = {
            let mut registry =
                self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
            let stored = registry.set_terminal_resume_command(terminal_id, command)?;
            self.reload_presentation(&registry)?;
            stored
        };
        self.emit(MuxEvent::TreeChanged);
        Ok(stored)
    }

    /// The resume command of terminal `public_id` (`term_...`), if set.
    pub(crate) fn terminal_resume_command(&self, public_id: &str) -> Option<String> {
        self.presentation_snapshot().resume_commands.get(public_id).cloned()
    }
}
