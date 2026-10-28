//! The end of a restored terminal whose host is gone, after the owner's
//! first answer. After a reboot (or with every cmux process killed) each
//! restored terminal's host is dead or its record is missing. Committing
//! each end before the first answer, one registry commit each, held a
//! cold start of 600 terminals 10.5 s on a capture Mac (cp/restore-investigate
//! bench). A dead host's record adopts as a work item like a live one (its
//! try finds the host dead and ends it, `terminal_adoption_retry.rs`); a
//! terminal with no record ends here, as such an adoption: held until the
//! owner says ready, a few at a time ([`super::ADOPTION_REPLAYS`]), first
//! when a request waits on it. Its tab reads adopting until then, never
//! dead (R41), and its respawn follows (`terminal_respawn.rs`).

use super::super::mux_work::Retry;
use super::super::*;
use super::{AdoptionEnd, HeldAdoption};
use cmux_threads::work::{Lane, Priority};

impl Mux {
    /// Ends `terminal` (no host record: `missing-host-record`) on a work
    /// item after the owner's first answer, unless the holder re-attaches
    /// it now (that stays inline: the holder releases what the start pass
    /// did not claim).
    #[cfg(any(unix, windows))]
    #[track_caller]
    pub(super) fn adopt_from_holder_or_end_later(
        self: &Arc<Self>,
        terminal: &RegistryTerminal,
        options: &SurfaceOptions,
    ) -> anyhow::Result<()> {
        if self.adopt_from_holder_or_none(terminal, options) {
            return Ok(());
        }
        let terminal_id = terminal.terminal_id.clone();
        if !self
            .terminal_adoptions
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(terminal_id.clone())
        {
            return Ok(());
        }
        // The tab is pending, not dead, until the end commits (R41). A row
        // with no public id has no tab to show it: it ends now.
        if !self.set_pending_terminal(&terminal_id, PendingTerminal::Adopting) {
            self.terminal_adoptions
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .remove(&terminal_id);
            return self.mark_terminal_ended(
                &terminal_id,
                "terminal-record-missing",
                "missing-host-record",
                options,
            );
        }
        let end = AdoptionEnd { mux: Arc::downgrade(self), terminal_id: terminal_id.clone() };
        let options = options.clone();
        let key: Arc<str> = Arc::from(terminal_id.as_str());
        let start: HeldAdoption = Box::new(move |mux: &Mux| {
            let mut delay = Duration::from_millis(100);
            // Refused: shutdown began; the dropped item ends the adoption,
            // and the next owner's start finds the row as this one did.
            let _ = mux.post_mux_retry_limited(
                Duration::ZERO,
                Priority::UserVisible,
                Lane::System,
                (&mux.terminal_replays, Some(key)),
                move |mux| match mux.mark_terminal_ended(
                    &end.terminal_id,
                    "terminal-record-missing",
                    "missing-host-record",
                    &options,
                ) {
                    Ok(()) => Retry::Done,
                    Err(error) => {
                        eprintln!(
                            "cmux-tui: could not record the end of terminal {}: {error:#}",
                            end.terminal_id
                        );
                        delay = (delay * 2).min(Duration::from_secs(5));
                        Retry::After(delay)
                    }
                },
            );
        });
        self.hold_startup_adoption(terminal_id, start);
        Ok(())
    }
}
