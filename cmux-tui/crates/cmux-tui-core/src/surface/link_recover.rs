//! Recover a terminal whose host link failed (`terminal_state` `failed`):
//! the user's Recover (`restart-tab` on such a tab) ends the host the
//! daemon can no longer reach, so the reconnect loop finds it dead at once.
//! With PTY custody (`rehost.rs`) a replacement host serves the same
//! running shell (an ssh session survives); without it the end is a host
//! loss, and the tab can restart like any ended terminal.

use std::sync::PoisonError;

use super::*;
use crate::terminal_host_runtime::{TerminalHostLiveness, terminal_host_record_liveness};

impl Surface {
    /// End the unreachable host of this terminal if its link failed. True
    /// when a recover started (the tab turns `running` again, or ends).
    pub(crate) fn recover_failed_host_link(&self) -> bool {
        let Some(pty) = self.as_pty() else { return false };
        if self.terminal_host_connection_state() != Some(TerminalHostConnectionState::Failed) {
            return false;
        }
        let discovery = match &*pty.runtime.lock().unwrap_or_else(PoisonError::into_inner) {
            PtyRuntime::Hosted(host) => Some(host.discovery_record()),
            PtyRuntime::ExitedHosted | PtyRuntime::Local { .. } => None,
        };
        let Some((record, record_path)) = discovery else { return false };
        if let Ok(TerminalHostLiveness::Live) = terminal_host_record_liveness(&record_path, &record)
            && let Ok(pid) = i32::try_from(record.host_pid)
            && pid > 0
        {
            eprintln!(
                "cmux-tui: recovering terminal {}: ending its unreachable host {pid}",
                record.terminal_id
            );
            // SAFETY: the live start-nonce lock proves `pid` is this host
            // incarnation, which this daemon owns; the shell is its own
            // session and keeps running on the PTY custody copy.
            unsafe { libc::kill(pid, libc::SIGKILL) };
        }
        pty.recover_requested.store(true, Ordering::Release);
        true
    }
}
