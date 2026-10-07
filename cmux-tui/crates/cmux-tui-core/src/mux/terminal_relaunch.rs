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
        let mut registry = self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
        if let Err(error) = registry.record_terminal_relaunch(terminal_id, &record) {
            eprintln!("cmux-tui: terminal {terminal_id} relaunch record failed: {error:#}");
        }
    }
}
