//! The respawn supervisor (cx-6so.49): bounded backoff between attempts, a
//! typed end when the attempts run out, and the owner-start sweep.
//!
//! A terminal that loses its host again soon after a respawn is not refused:
//! its next attempt waits [`RESPAWN_BACKOFF`] for the number of attempts it
//! already had in the last [`RESPAWN_WINDOW`] (0 s, 2 s, 10 s, 30 s, 60 s).
//! Meanwhile its tabs read `adopting`, never dead. Once it used every
//! attempt in the window, its receipt is rewritten to the host loss
//! `restart_exhausted`, so the tab says why it stopped and no later owner
//! respawns it. A terminal that ran for the whole window starts again at
//! 0 s, because its attempts aged out.
//!
//! The wait is a delayed work item (`Work::post_delayed`, p02-threads 230),
//! no thread per terminal. Shutdown drops a waiting attempt
//! ([`PendingRespawn`]) and an attempt that runs after shutdown began does
//! nothing; either way the attempt is abandoned, and the receipt stays a
//! respawnable host loss for the next owner's start sweep
//! ([`Mux::respawn_lost_terminals_at_start`]).

use std::collections::VecDeque;

use super::*;

/// The delay before attempt N (0-based) of one terminal in the window. Its
/// length is the number of attempts per window.
const RESPAWN_BACKOFF: [Duration; 5] = [
    Duration::ZERO,
    Duration::from_secs(2),
    Duration::from_secs(10),
    Duration::from_secs(30),
    Duration::from_secs(60),
];
/// Attempts older than this no longer count.
const RESPAWN_WINDOW: Duration = Duration::from_secs(600);
/// Debug builds only: a comma list of milliseconds that replaces
/// [`RESPAWN_BACKOFF`] (its length is the attempt bound), so integration
/// tests run the whole schedule in seconds. Release builds ignore it.
#[cfg(debug_assertions)]
const BACKOFF_ENV: &str = "CMUX_TUI_TEST_RESPAWN_BACKOFF_MS";

/// The crash-loop bound: attempt start times per terminal.
#[derive(Debug)]
pub(crate) struct RespawnGuard {
    schedule: Vec<Duration>,
    attempts: HashMap<String, VecDeque<Instant>>,
}

impl Default for RespawnGuard {
    fn default() -> Self {
        Self { schedule: RESPAWN_BACKOFF.to_vec(), attempts: HashMap::new() }
    }
}

impl RespawnGuard {
    pub(crate) fn from_env() -> Self {
        #[cfg(debug_assertions)]
        if let Ok(value) = std::env::var(BACKOFF_ENV) {
            let schedule = value
                .split(',')
                .filter_map(|ms| ms.trim().parse().ok())
                .map(Duration::from_millis)
                .collect::<Vec<_>>();
            if !schedule.is_empty() {
                return Self { schedule, attempts: HashMap::new() };
            }
        }
        Self::default()
    }

    /// Admit an attempt for `terminal_id` at `now`: the delay before it
    /// starts, or `None` when the terminal used every attempt in the window.
    pub(crate) fn admit(&mut self, terminal_id: &str, now: Instant) -> Option<Duration> {
        // Terminals whose attempts all aged out leave the map.
        self.attempts.retain(|_, attempts| {
            attempts.retain(|at| now.saturating_duration_since(*at) < RESPAWN_WINDOW);
            !attempts.is_empty()
        });
        let attempts = self.attempts.entry(terminal_id.to_string()).or_default();
        let delay = *self.schedule.get(attempts.len())?;
        // The attempt counts from when it starts, so the window measures
        // run time between attempts, not the backoff itself.
        attempts.push_back(now + delay);
        Some(delay)
    }

    /// Forget a closed terminal's attempts.
    pub(crate) fn forget(&mut self, terminal_id: &str) {
        self.attempts.remove(terminal_id);
    }

    /// The attempt bound per window.
    pub(crate) fn limit(&self) -> usize {
        self.schedule.len()
    }
}

/// A respawn attempt waiting out its backoff. Dropped without running (the
/// work item was dropped at shutdown, or ran after shutdown began), it
/// abandons the attempt.
#[cfg(any(unix, windows))]
pub(in crate::mux) struct PendingRespawn {
    pub(in crate::mux) plan: Option<RespawnPlan>,
    pub(in crate::mux) owner: Weak<Mux>,
}

#[cfg(any(unix, windows))]
impl Drop for PendingRespawn {
    fn drop(&mut self) {
        let Some(plan) = self.plan.take() else { return };
        if let Some(mux) = self.owner.upgrade() {
            mux.abandon_terminal_respawn(&plan.terminal_id);
        }
    }
}

impl Mux {
    /// The owner began shutting down: a respawn attempt is abandoned.
    #[cfg(any(unix, windows))]
    pub(super) fn respawn_stopping(&self) -> bool {
        self.shutting_down.load(Ordering::Acquire) || self.session_shutdown.began()
    }

    /// An attempt abandoned before it started (the owner shuts down): clear
    /// the respawning marker; the tab shows the committed host loss, which
    /// the next owner's start sweep respawns.
    #[cfg(any(unix, windows))]
    #[track_caller]
    pub(super) fn abandon_terminal_respawn(&self, terminal_id: &str) {
        self.pending_terminals.lock().unwrap_or_else(PoisonError::into_inner).retain(
            |_, (id, pending)| id != terminal_id || *pending != PendingTerminal::Respawning,
        );
        self.record_terminal_end(terminal_id);
    }

    /// The terminal used every attempt in the window: rewrite its host-loss
    /// receipt to `restart_exhausted` so the tab names that, and so no later
    /// owner respawns it, and take the dead runtime out of its tabs, so they
    /// show that durable receipt.
    #[cfg(any(unix, windows))]
    #[track_caller]
    pub(super) fn end_terminal_respawn_exhausted(
        &self,
        terminal_id: &str,
        end: &TerminalEnd,
        public_id: &TerminalPublicId,
    ) {
        let limit =
            self.terminal_respawns.guard.lock().unwrap_or_else(PoisonError::into_inner).limit();
        eprintln!(
            "cmux-tui: terminal {terminal_id} lost its host {limit} times in 10 minutes; it stays \
             ended"
        );
        let exhausted = TerminalExit::unknown(format!(
            "{}: {limit} restarts in 10 minutes",
            crate::terminal_end::RESPAWN_EXHAUSTED_DETAIL
        ));
        if let Some(old_runtime) =
            self.replace_lost_receipt(terminal_id, end.exit(), &exhausted, Some(public_id))
            && let Some(owner) = self.exit_settles.owner()
            && let Err(error) = owner.unregister_kitty_image_surface(&old_runtime)
        {
            eprintln!("cmux-tui: terminal {terminal_id} kept its kitty image budget: {error:#}");
        }
        self.record_terminal_end(terminal_id);
    }

    /// Rewrite an exited terminal's receipt from `recorded` to `replacement`
    /// (a no-op when the stored receipt is not `recorded` any more).
    #[cfg(any(unix, windows))]
    #[track_caller]
    pub(super) fn rewrite_lost_receipt(
        &self,
        terminal_id: &str,
        recorded: &TerminalExit,
        replacement: &TerminalExit,
    ) {
        let _ = self.replace_lost_receipt(terminal_id, recorded, replacement, None);
        self.record_terminal_end(terminal_id);
    }

    /// One registry + state section: snapshot the terminal, replace its
    /// receipt, and when it committed and `detach_runtime` names the
    /// terminal, take its runtime out of the tabs (returned for cleanup).
    #[cfg(any(unix, windows))]
    #[track_caller]
    fn replace_lost_receipt(
        &self,
        terminal_id: &str,
        recorded: &TerminalExit,
        replacement: &TerminalExit,
        detach_runtime: Option<&TerminalPublicId>,
    ) -> Option<Arc<Surface>> {
        let mut registry = self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
        let mut state = self.lock_state_pinned(&registry).unwrap_or_else(PoisonError::into_inner);
        let committed =
            terminal_exit_snapshot_in_state(&registry, &state, terminal_id).and_then(|snapshot| {
                registry.settle_terminal_exit(terminal_id, recorded, replacement, snapshot)
            });
        match committed {
            Ok((_, terminal_revision, resource_revision, false)) => {
                state.resource_revision = resource_revision;
                let old_runtime = detach_runtime.and_then(|public_id| {
                    let content = ContentPublicId::Terminal(public_id.clone());
                    let placements = state.placements_of_content(&content).to_vec();
                    let old_runtime = state.remove_catalog_terminal(public_id);
                    for placement in &placements {
                        state.surfaces.remove(placement);
                    }
                    old_runtime
                });
                self.emit_terminal_registry_changed(&registry, terminal_revision);
                drop(state);
                drop(registry);
                self.publish_resource_event();
                old_runtime
            }
            Ok(_) => None,
            Err(error) => {
                eprintln!(
                    "cmux-tui: could not record the end of terminal {terminal_id}: {error:#}"
                );
                None
            }
        }
    }

    /// Owner start: respawn every placed terminal whose committed end is a
    /// respawnable host loss that no respawn of this owner already took (a
    /// respawn a daemon restart or logout cut off, a shell a session
    /// shutdown ended). Runs once, after host adoption.
    #[cfg(any(unix, windows))]
    #[track_caller]
    pub(crate) fn respawn_lost_terminals_at_start(&self) {
        let snapshot = self
            .workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .terminal_snapshot();
        let terminals = match snapshot {
            Ok(snapshot) => snapshot.terminals,
            Err(error) => {
                eprintln!("cmux-tui: could not list terminals to respawn: {error:#}");
                return;
            }
        };
        for terminal in terminals {
            if terminal.lifecycle != TerminalLifecycle::Exited
                || self.terminal_is_respawning(&terminal.terminal_id)
            {
                continue;
            }
            let end = TerminalEnd::from_receipt(terminal.exit.as_ref());
            let respawnable = matches!(end, TerminalEnd::HostLost(_))
                && end
                    .wire_json()
                    .get("reason")
                    .and_then(Value::as_str)
                    .is_some_and(|reason| RESPAWN_REASONS.contains(&reason));
            if respawnable {
                self.schedule_terminal_respawn(
                    &terminal.terminal_id,
                    terminal.incarnation.as_deref(),
                    &end,
                );
            }
        }
    }
}
