//! The owner's side of replacing a dead terminal host on its still-running
//! shell (cx-6so.49 L1.2): whether the terminal may get a replacement host,
//! and the launch options it uses. The replacement itself runs on the
//! terminal's reader thread (`surface/rehost.rs`).

use std::sync::PoisonError;

use super::*;

impl Mux {
    /// A replacement host may serve `identity` only while this owner runs
    /// normally and the registry still names that incarnation live: never
    /// during shutdown, after an exit was committed, or after a close
    /// tombstoned the terminal.
    pub(crate) fn terminal_accepts_host_replacement(
        &self,
        identity: &TerminalHostIdentity,
    ) -> bool {
        if self.shutting_down.load(Ordering::Acquire) {
            return false;
        }
        let registry = self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
        let Ok(Some(terminal)) = registry.terminal_record(&identity.terminal_id) else {
            return false;
        };
        terminal.incarnation.as_deref() == Some(identity.incarnation.as_str())
            && !matches!(
                terminal.lifecycle,
                TerminalLifecycle::Exited | TerminalLifecycle::Tombstoned
            )
    }

    /// The terminal type a replacement host reports (it spawns no child, so
    /// only its record and terminfo-dependent replies use it).
    pub(crate) fn host_replacement_term(&self) -> String {
        self.surface_options.lock().unwrap_or_else(PoisonError::into_inner).term.clone()
    }
}
