//! The journal gap a terminal-host reconnect records (nx-scale step 1).
//!
//! Bytes a host wrote while no daemon tap existed are not in the journal.
//! The hosted reader records a `terminal.output.gap` (reason
//! `host_reconnect`) in the terminal lane after it installed the host's
//! replacement snapshot and before it reads new output, then marks the
//! terminal for the coalesced checkpoint (mux/journal_retention.rs).
//! Capturing a session checkpoint inline here made a wave of N reconnects
//! O(N^2).

use std::sync::Arc;
use std::sync::PoisonError;
use std::sync::atomic::Ordering;

use super::PtyTerminalRuntime;
use crate::Mux;
use crate::journal_ingress::{JournalIngressEvent, JournalIngressTrySendError};
use crate::resource::TerminalPublicId;

impl PtyTerminalRuntime {
    /// Enqueue the gap like terminal output: a non-blocking send under the
    /// capture gate (so a shutdown's final barrier follows it, or it is not
    /// sent), and a wait for queue space with the gate released.
    pub(super) fn journal_host_reconnect_gap(&self, mux: &Arc<Mux>) {
        if !mux.terminal_journal_enabled() || !self.journal_capture_supported {
            return;
        }
        let Some(terminal_id) = self.terminal_public_id.clone() else { return };
        let occurred_at_ms = crate::workspace_registry::unix_epoch_ms().unwrap_or(0);
        loop {
            let space_epoch = {
                let _gate =
                    self.journal_capture_gate.lock().unwrap_or_else(PoisonError::into_inner);
                if !self.journal_capture_open.load(Ordering::Acquire) {
                    return;
                }
                let gap = JournalIngressEvent::TerminalOutputGap {
                    terminal_id: terminal_id.clone(),
                    generation: self.journal_generation.clone(),
                    occurred_at_ms,
                    reason: "host_reconnect",
                };
                match mux.try_journal_terminal_event(gap) {
                    Ok(()) => break,
                    Err(JournalIngressTrySendError::Full { space_epoch, .. }) => space_epoch,
                    Err(JournalIngressTrySendError::Failed { .. }) => return,
                }
            };
            if mux.wait_for_terminal_journal_space(space_epoch).is_err() {
                return;
            }
        }
        mux.note_terminal_host_reconnect(TerminalPublicId::clone(&terminal_id));
    }
}
