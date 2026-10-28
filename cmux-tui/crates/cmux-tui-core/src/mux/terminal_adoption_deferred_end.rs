//! The end of a restored terminal whose host is gone, after the owner's
//! first answer. After a reboot (or with every cmux process killed) each
//! restored terminal's host is dead or its record is missing. Committing
//! each end before the first answer, one registry commit each, held a
//! cold start of 600 terminals 10.5 s on a capture Mac (cp/restore-investigate
//! bench). A dead host's record adopts as a work item like a live one (its
//! try finds the host dead and ends it, `terminal_adoption_retry.rs`); a
//! running terminal with no record is marked adopting with the others in one
//! commit and ends here, as such an adoption: held until the owner says
//! ready, a few at a time ([`super::ADOPTION_REPLAYS`]), first when a request
//! waits on it. Its tab reads adopting until then, never dead (R41), and its
//! respawn follows (`terminal_respawn.rs`).

use super::super::mux_work::Retry;
use super::super::*;
use super::{AdoptionEnd, HeldAdoption};
use cmux_threads::work::{Lane, Priority};

/// Why a terminal with no host record ends.
const OPERATION: &str = "terminal-record-missing";
const REASON: &str = "missing-host-record";

impl Mux {
    /// Ends every terminal of `missing` (no host record, none the holder
    /// runs). A running (or adopting) one with an incarnation is marked
    /// adopting, all in one registry commit, and ends on a work item after
    /// the first answer; any other (a launch the crash cut off, which a
    /// creation's reconciliation may wait on) ends now, as before.
    #[cfg(any(unix, windows))]
    #[track_caller]
    pub(super) fn end_missing_hosts_later(
        self: &Arc<Self>,
        missing: Vec<RegistryTerminal>,
        options: &SurfaceOptions,
    ) -> anyhow::Result<()> {
        let (later, now): (Vec<_>, Vec<_>) = missing.into_iter().partition(|terminal| {
            matches!(terminal.lifecycle, TerminalLifecycle::Running | TerminalLifecycle::Adopting)
                && terminal.incarnation.is_some()
        });
        for terminal in now {
            self.mark_terminal_ended(&terminal.terminal_id, OPERATION, REASON, options)?;
        }
        let adopting = later
            .into_iter()
            .filter_map(|terminal| {
                let incarnation = terminal.incarnation.clone()?;
                Some((terminal, incarnation))
            })
            .collect::<Vec<_>>();
        let marked = {
            let mut registry =
                self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
            let (marked, revision) = commit_terminals_adopting(&mut registry, &adopting)?;
            if let Some(revision) = revision {
                self.emit_terminal_registry_changed(&registry, revision);
            }
            marked
        };
        for ((terminal, _), marked) in adopting.into_iter().zip(marked) {
            // A row that could not be marked, or has no tab to show it
            // pending, ends now.
            if marked.is_err()
                || !self.set_pending_terminal(&terminal.terminal_id, PendingTerminal::Adopting)
            {
                self.mark_terminal_ended(&terminal.terminal_id, OPERATION, REASON, options)?;
                continue;
            }
            self.end_missing_host_later(terminal.terminal_id, options);
        }
        Ok(())
    }

    /// Ends `terminal_id` on a retried work item held until the owner says
    /// ready, under the adoption permits, first when a request waits on it.
    #[cfg(any(unix, windows))]
    fn end_missing_host_later(self: &Arc<Self>, terminal_id: String, options: &SurfaceOptions) {
        if !self
            .terminal_adoptions
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(terminal_id.clone())
        {
            return;
        }
        let end = AdoptionEnd { mux: Arc::downgrade(self), terminal_id: terminal_id.clone() };
        let options = options.clone();
        let key: Arc<str> = Arc::from(terminal_id.as_str());
        // Test hook (fault injection, debug builds): the end starts this much
        // later, as an adoption does (`schedule_terminal_adoption_after`), so
        // a test can act while the terminal adopts.
        #[cfg(debug_assertions)]
        let first_delay = std::env::var("CMUX_TUI_TEST_ADOPTION_DELAY_MS")
            .ok()
            .and_then(|ms| ms.parse::<u64>().ok())
            .map_or(Duration::ZERO, Duration::from_millis);
        #[cfg(not(debug_assertions))]
        let first_delay = Duration::ZERO;
        let start: HeldAdoption = Box::new(move |mux: &Mux| {
            let mut delay = Duration::from_millis(100);
            // Refused: shutdown began; the dropped item ends the adoption,
            // and the next owner's start finds the row adopting with no
            // record and ends it the same way.
            let _ = mux.post_mux_retry_limited(
                first_delay,
                Priority::UserVisible,
                Lane::System,
                (&mux.terminal_replays, Some(key)),
                move |mux| {
                    end_hold_for_test();
                    // Outside the lane's limits, as the dead-host end
                    // (terminal_adoption_retry.rs).
                    let ended = cmux_threads::work::will_block(|| {
                        mux.mark_terminal_ended(&end.terminal_id, OPERATION, REASON, &options)
                    });
                    match ended {
                        Ok(()) => Retry::Done,
                        Err(error) => {
                            eprintln!(
                                "cmux-tui: could not record the end of terminal {}: {error:#}",
                                end.terminal_id
                            );
                            delay = (delay * 2).min(Duration::from_secs(5));
                            Retry::After(delay)
                        }
                    }
                },
            );
        });
        self.hold_startup_adoption(terminal_id, start);
    }
}

/// Test hooks (debug builds), on each end try, outside `will_block`:
/// - `CMUX_TUI_TEST_END_HOLD_MS`: the try holds its lane slot this much
///   longer, as an end's commit and its record cleanup do under load.
/// - `CMUX_TUI_TEST_END_GATE` (a file path) with `CMUX_TUI_TEST_END_GATE_AFTER`
///   (K): every end after the first K holds its slot until that file exists,
///   so a test chooses when the queue moves and attaches while it is full.
pub(super) fn end_hold_for_test() {
    #[cfg(debug_assertions)]
    {
        use std::sync::atomic::{AtomicUsize, Ordering};
        static ENDS: AtomicUsize = AtomicUsize::new(0);
        if let Some(hold) =
            std::env::var("CMUX_TUI_TEST_END_HOLD_MS").ok().and_then(|ms| ms.parse::<u64>().ok())
        {
            crate::request_path::sleep(Duration::from_millis(hold));
        }
        let gate = std::env::var_os("CMUX_TUI_TEST_END_GATE").map(std::path::PathBuf::from);
        let after = std::env::var("CMUX_TUI_TEST_END_GATE_AFTER")
            .ok()
            .and_then(|count| count.parse::<usize>().ok())
            .unwrap_or(0);
        if let Some(gate) = gate
            && ENDS.fetch_add(1, Ordering::AcqRel) >= after
        {
            // A test gate: bounded so a test that fails never strands the owner.
            let deadline = Instant::now() + Duration::from_secs(60);
            while !gate.exists() && Instant::now() < deadline {
                crate::request_path::sleep(Duration::from_millis(10));
            }
        }
    }
}
