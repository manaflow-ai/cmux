//! Writes the per-terminal relaunch record
//! (`workspace_registry::relaunch_store`) when a terminal launches.

use super::*;
use crate::workspace_registry::relaunch_store::RelaunchRecord;

impl Mux {
    /// Record how terminal `terminal_id` was launched with `opts`. A failure
    /// only costs the reopened tab its directory, so it is logged, not raised.
    pub(super) fn record_terminal_relaunch(&self, terminal_id: &str, opts: &SurfaceOptions) {
        let record = RelaunchRecord::from_launch(
            opts.cwd.as_deref(),
            opts.command.as_deref(),
            &crate::platform::default_shell(),
            &opts.extra_env,
        );
        if record.kind == crate::workspace_registry::relaunch_store::RelaunchKind::Command
            && let Some(argv) = opts.command.as_deref()
        {
            self.terminal_respawns.remember_argv(terminal_id, argv);
        }
        let mut registry = self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
        if let Err(error) = registry.record_terminal_relaunch(terminal_id, &record) {
            eprintln!("cmux-tui: terminal {terminal_id} relaunch record failed: {error:#}");
        }
    }

    /// Keep the agent session terminal `terminal_id` runs in its relaunch
    /// record (an L2 respawn offers to resume it), from its agent hooks: a
    /// session id the hook named with its harness, forgotten when the
    /// session ends. Best effort, like the rest of the record.
    pub(super) fn note_relaunch_agent(
        &self,
        terminal_id: &TerminalPublicId,
        harness: Option<String>,
        session_id: Option<&str>,
        ended: bool,
    ) {
        let agent = match (ended, harness.as_deref(), session_id) {
            (true, _, _) => None,
            (false, Some(harness), Some(session_id)) => Some((harness, session_id)),
            (false, _, _) => return,
        };
        let mut registry = self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
        if let Err(error) = registry.record_terminal_relaunch_agent(terminal_id.as_str(), agent) {
            eprintln!("cmux-tui: terminal {terminal_id} relaunch agent failed: {error:#}");
        }
    }
}
