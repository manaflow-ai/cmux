//! The journal marker a terminal-host reconnect or respawn records (nx-scale
//! step 1).
//!
//! Output never enters the session journal (output_store.rs). The
//! `terminal.output.gap` record stays as a small structural marker: reason
//! `host_reconnect` after the hosted reader installed the host's replacement
//! snapshot (bytes the host wrote while no daemon tap existed never reached
//! the daemon's viewers), reason `host_respawn` at the start of a respawned
//! terminal's new generation (cx-6so.49 L2). A reconnect also marks the
//! terminal for the coalesced checkpoint (mux/journal_retention.rs);
//! capturing a session checkpoint inline here made a wave of N reconnects
//! O(N^2).

use std::sync::Arc;

use super::PtyTerminalRuntime;
use crate::Mux;
use crate::resource::TerminalPublicId;

impl PtyTerminalRuntime {
    pub(super) fn journal_host_reconnect_gap(&self, mux: &Arc<Mux>) {
        if self.journal_output_gap(mux, "host_reconnect")
            && let Some(terminal_id) = self.terminal_public_id.clone()
        {
            mux.note_terminal_host_reconnect(TerminalPublicId::clone(&terminal_id));
        }
    }

    /// The `screen_cleared` marker after clear-history on a local terminal
    /// (a hosted one records `host_reconnect` from its resync): a restore or
    /// respawn starts after the clear.
    pub(super) fn journal_clear_gap(&self, mux: &Arc<Mux>) {
        self.journal_output_gap(mux, "screen_cleared");
    }

    /// Queue the marker on the terminal lane (after this terminal's earlier
    /// resizes). False when this terminal is not journaled.
    fn journal_output_gap(&self, mux: &Arc<Mux>, reason: &'static str) -> bool {
        if !mux.terminal_journal_enabled() || !self.journal_capture_supported {
            return false;
        }
        let Some(terminal_id) = self.terminal_public_id.clone() else { return false };
        mux.journal_terminal_output_gap(terminal_id, self.journal_generation.clone(), reason);
        true
    }
}

impl super::Surface {
    /// Record the `host_respawn` marker at the start of a respawned
    /// terminal's generation (cx-6so.49).
    pub(crate) fn journal_respawn_gap(&self, mux: &Arc<Mux>) {
        if let Some(pty) = self.as_pty() {
            pty.journal_output_gap(mux, "host_respawn");
        }
    }
}
