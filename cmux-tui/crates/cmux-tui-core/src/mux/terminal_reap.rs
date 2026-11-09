//! Reaping of unplaced terminals (`terminal-reaper-active-v1`).
//!
//! Closing a tab, pane, screen, or workspace detaches a PTY terminal without
//! ending it, because terminals are session-owned. An owner started with
//! `--terminal-reap-grace-seconds` therefore ends a terminal once it has had
//! zero tab placements for the reap grace period. The grace period keeps a
//! daemon restart, a frontend quit and relaunch, and layout undo safe: a
//! placement restored within the period cancels the reap. A terminal that a
//! client holds an attach stream on is not reaped; it is tried again a grace
//! period later. An owner started without the option reaps nothing.
//!
//! The reaper is event-driven. It sleeps until the next deadline or until a
//! topology or terminal-registry change wakes it; it never polls.
//!
//! The grace holds at most [`MAX_TERMINALS_IN_REAP_GRACE`] closed terminals: each keeps its
//! shell and so its PTY (a shell cannot outlive its PTY), and a script that closes several tabs a
//! second held the machine's PTYs until every new tab was refused (feat STATUS 7998). Past the cap
//! the longest-closed ends at once.
//!
//! The grace runs across owner restarts. The registry keeps the wall-clock
//! time the owner first saw each terminal unplaced
//! (`workspace_registry/terminal_unplaced_store.rs`), and a restarted owner
//! counts the grace from it. Counted from each start instead, restarts
//! faster than the grace (a crash loop) reaped nothing, and the closed
//! terminals' hosts held the machine's PTYs until every new terminal failed
//! (feat P0 TERMINAL-HOST LEAK, 2026-10-31). A terminal a restarted owner is
//! still adopting keeps its time. A wall clock set back only delays a reap;
//! one set forward (or a machine asleep across a restart) can end a closed
//! terminal sooner after the restart, never one with a placement: the close
//! re-checks placement atomically.

use std::sync::mpsc::RecvTimeoutError;
use std::thread::JoinHandle;

use super::*;

/// Default reap grace period for a terminal with no placement.
pub const DEFAULT_TERMINAL_REAP_GRACE: Duration = Duration::from_secs(30);

/// The most closed terminals that wait out the reap grace with their PTY at once (feat STATUS
/// 7998). Past it, the reaper ends the longest-closed at once.
pub(crate) const MAX_TERMINALS_IN_REAP_GRACE: usize = 16;
/// Largest accepted reap grace period: one week.
pub const MAX_TERMINAL_REAP_GRACE: Duration = Duration::from_secs(7 * 24 * 60 * 60);

const TERMINAL_REAP_MUTATION_ORIGIN: &str = "cmux-tui-terminal-reap";

/// The most reaps one pass runs at the same time. Each close waits for its
/// host to exit, so a burst of due terminals ends in about the time of the
/// slowest close instead of their sum.
const MAX_PARALLEL_REAPS: usize = 16;

/// Result of one reap attempt.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ReapOutcome {
    /// The terminal was ended.
    Reaped,
    /// A client holds an attach stream on the unplaced terminal.
    Attached,
    /// The terminal gained a placement or is gone.
    Retained,
}

/// Per-terminal reap deadlines, driven by an injected clock.
#[derive(Debug, Default)]
pub(crate) struct ReapSchedule {
    deadlines: HashMap<String, Instant>,
    /// Terminals an attempt left running (`Retained`) or still listed
    /// (`Reaped`): the earliest the next attempt may come, kept while each
    /// stays reapable.
    retry_floors: HashMap<String, Instant>,
    /// Consecutive failed reapable-set scans (retry spacing).
    scan_failures: u32,
    /// The registry holds no unplaced time (the last pass removed or found
    /// none): a pass that sees no unplaced terminal skips the registry.
    unplaced_rows_empty: bool,
}

impl ReapSchedule {
    /// A scan of the reapable set failed: push every due deadline out by a
    /// capped, growing delay. A past-due deadline left in place made the
    /// reaper thread wait zero time and re-scan in a hot loop for as long as
    /// the scan kept failing.
    pub(crate) fn defer_due_after_failed_scan(&mut self, now: Instant) {
        let delay = SCAN_RETRY_INITIAL
            .saturating_mul(1_u32 << self.scan_failures.min(10))
            .min(SCAN_RETRY_MAX);
        self.scan_failures = self.scan_failures.saturating_add(1);
        let until = now + delay;
        for deadline in self.deadlines.values_mut() {
            if *deadline <= now {
                *deadline = until;
            }
        }
    }

    /// Reconcile with the current set of reapable terminals, each with how
    /// long it has already been unplaced (across owner restarts). A terminal
    /// that becomes reapable gets `now + grace - unplaced_for`; a terminal
    /// that is no longer reapable (placed again or closed) loses its
    /// deadline.
    pub(crate) fn observe_unplaced(
        &mut self,
        now: Instant,
        grace: Duration,
        reapable: &HashMap<String, Duration>,
    ) {
        self.scan_failures = 0;
        self.deadlines.retain(|terminal_id, _| reapable.contains_key(terminal_id));
        self.retry_floors.retain(|terminal_id, _| reapable.contains_key(terminal_id));
        for (terminal_id, unplaced_for) in reapable {
            let floor = self.retry_floors.get(terminal_id).copied();
            self.deadlines.entry(terminal_id.clone()).or_insert_with(|| {
                let deadline = deadline_after(now, grace.saturating_sub(*unplaced_for));
                floor.map_or(deadline, |floor| deadline.max(floor))
            });
        }
    }

    /// [`ReapSchedule::observe_unplaced`] for terminals unplaced just now.
    #[cfg(test)]
    pub(crate) fn observe(&mut self, now: Instant, grace: Duration, reapable: &HashSet<String>) {
        let reapable = reapable.iter().map(|id| (id.clone(), Duration::ZERO)).collect();
        self.observe_unplaced(now, grace, &reapable);
    }

    /// Terminals whose deadline is at or before `now`, in a stable order.
    pub(crate) fn due(&self, now: Instant) -> Vec<String> {
        let mut due: Vec<String> = self
            .deadlines
            .iter()
            .filter(|(_, deadline)| **deadline <= now)
            .map(|(terminal_id, _)| terminal_id.clone())
            .collect();
        due.sort_unstable();
        due
    }

    pub(crate) fn postpone(&mut self, terminal_id: &str, until: Instant) {
        if let Some(deadline) = self.deadlines.get_mut(terminal_id) {
            *deadline = until;
        }
    }

    pub(crate) fn forget(&mut self, terminal_id: &str) {
        self.deadlines.remove(terminal_id);
    }

    /// A reap of a due terminal was attempted at `now`; `outcome` is `None`
    /// when the attempt failed.
    pub(crate) fn tried(
        &mut self,
        terminal_id: &str,
        outcome: Option<ReapOutcome>,
        now: Instant,
        grace: Duration,
    ) {
        let retry = deadline_after(now, grace.max(MIN_RETRY));
        match outcome {
            // The deadline goes, so a terminal placed again and closed
            // again gets a fresh grace from its new unplaced time. The floor
            // stays: a terminal the attempt left reapable is otherwise
            // re-added at its durable unplaced time, already past the grace,
            // due at once, and the reaper thread waited zero and ran pass
            // after pass (feat #33173: a headless owner at 150% CPU).
            Some(ReapOutcome::Reaped | ReapOutcome::Retained) => {
                self.forget(terminal_id);
                self.retry_floors.insert(terminal_id.to_string(), retry);
            }
            // An attached client keeps the terminal for another full grace
            // period; its detach does not emit a topology event.
            Some(ReapOutcome::Attached) | None => self.postpone(terminal_id, retry),
        }
    }

    pub(crate) fn next_deadline(&self) -> Option<Instant> {
        self.deadlines.values().min().copied()
    }

    #[cfg(test)]
    pub(crate) fn deadline(&self, terminal_id: &str) -> Option<Instant> {
        self.deadlines.get(terminal_id).copied()
    }
}

/// The closed terminals past [`MAX_TERMINALS_IN_REAP_GRACE`], longest closed first: each holds a PTY
/// for its grace, and a burst of closes must not hold the machine's PTYs (feat STATUS 7998).
fn over_grace_cap(reapable: &HashMap<String, Duration>) -> Vec<String> {
    let Some(over) =
        reapable.len().checked_sub(MAX_TERMINALS_IN_REAP_GRACE).filter(|over| *over > 0)
    else {
        return Vec::new();
    };
    let mut oldest: Vec<(&Duration, &String)> =
        reapable.iter().map(|(terminal_id, unplaced_for)| (unplaced_for, terminal_id)).collect();
    oldest.sort_by(|a, b| b.0.cmp(a.0).then_with(|| a.1.cmp(b.1)));
    oldest.into_iter().take(over).map(|(_, terminal_id)| terminal_id.clone()).collect()
}

fn deadline_after(now: Instant, grace: Duration) -> Instant {
    now.checked_add(grace).unwrap_or_else(|| now + MAX_TERMINAL_REAP_GRACE)
}

/// Validate a reap grace period supplied by a command line or a caller.
pub fn validate_terminal_reap_grace(grace: Duration) -> anyhow::Result<Duration> {
    anyhow::ensure!(
        grace <= MAX_TERMINAL_REAP_GRACE,
        "terminal reap grace must be at most {} seconds",
        MAX_TERMINAL_REAP_GRACE.as_secs()
    );
    Ok(grace)
}

impl Mux {
    /// The grace period an unplaced terminal survives before it is reaped.
    pub fn terminal_reap_grace(&self) -> Duration {
        Duration::from_millis(self.terminal_reap_grace_ms.load(Ordering::Acquire))
    }

    /// Change the reap grace period. Zero reaps an unplaced terminal at once.
    /// Pending deadlines keep their original grace period.
    pub fn set_terminal_reap_grace(&self, grace: Duration) -> anyhow::Result<()> {
        let grace = validate_terminal_reap_grace(grace)?;
        let millis = u64::try_from(grace.as_millis()).unwrap_or(u64::MAX);
        self.terminal_reap_grace_ms.store(millis, Ordering::Release);
        self.wake_terminal_reaper();
        Ok(())
    }

    fn wake_terminal_reaper(&self) {
        if let Some(events) =
            self.terminal_reaper_events.lock().unwrap_or_else(PoisonError::into_inner).as_ref()
        {
            events.wake();
        }
    }

    /// Host ids of every live hosted terminal that has no tab placement
    /// (reapable), and of the other hosted terminals this owner serves
    /// (placed), whose unplaced times are cleared.
    pub(crate) fn reapable_and_retained_terminals(
        &self,
    ) -> anyhow::Result<(HashSet<String>, HashSet<String>)> {
        let state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        let placed_runtimes: HashSet<SurfaceId> =
            state.surfaces.values().filter_map(|view| view.terminal_runtime_id()).collect();
        let mut unplaced = HashSet::new();
        let mut placed = HashSet::new();
        for (public_id, runtime) in &state.terminal_catalog {
            let Some(identity) = self.resource_terminal_host_identity(runtime) else {
                continue;
            };
            let content_id = ContentPublicId::Terminal(public_id.clone());
            if runtime.terminal_runtime_id().is_some_and(|id| placed_runtimes.contains(&id))
                || !state.placements_of_content(&content_id).is_empty()
            {
                placed.insert(identity.terminal_id);
            } else {
                unplaced.insert(identity.terminal_id);
            }
        }
        Ok((unplaced, placed))
    }

    /// The reapable terminals, each with how long it has been unplaced,
    /// counted from the durable time the owner (this one or an earlier one)
    /// first saw it so (`terminal_unplaced_store.rs`).
    /// A pass that sees no unplaced terminal while the registry holds no
    /// unplaced time (`unplaced_rows_empty`) does not touch the registry.
    pub(super) fn reapable_terminals_unplaced_for(
        &self,
        unplaced_rows_empty: &mut bool,
    ) -> anyhow::Result<HashMap<String, Duration>> {
        let (unplaced, retained) = self.reapable_and_retained_terminals()?;
        if unplaced.is_empty() && *unplaced_rows_empty {
            return Ok(HashMap::new());
        }
        let wall_ms = now_ms();
        let synced = self
            .workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .sync_terminal_unplaced(&unplaced, &retained, wall_ms)?;
        *unplaced_rows_empty = !synced.rows_left;
        Ok(synced
            .since_ms
            .into_iter()
            .map(|(terminal_id, since_ms)| {
                (terminal_id, Duration::from_millis(wall_ms.saturating_sub(since_ms)))
            })
            .collect())
    }

    /// End one unplaced terminal. The placement check is repeated atomically
    /// with the close, so a terminal that gained a view since the caller
    /// looked is retained.
    pub(crate) fn reap_unplaced_terminal(&self, terminal_id: &str) -> anyhow::Result<ReapOutcome> {
        let runtime_view = {
            let state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
            state.terminal_catalog.values().find_map(|runtime| {
                self.resource_terminal_host_identity(runtime)
                    .is_some_and(|identity| identity.terminal_id == terminal_id)
                    .then_some(runtime.id)
            })
        };
        let Some(runtime_view) = runtime_view else { return Ok(ReapOutcome::Retained) };
        if self.control_clients.attach_observation(&[runtime_view]).0 {
            return Ok(ReapOutcome::Attached);
        }
        match self.close_terminal_guarded(
            terminal_id,
            None,
            None,
            None,
            &WorkspaceMutation::local(TERMINAL_REAP_MUTATION_ORIGIN),
            TerminalCloseGuard::Unplaced,
        ) {
            Ok(_) => Ok(ReapOutcome::Reaped),
            Err(error) if error.downcast_ref::<TerminalCloseGuardFailed>().is_some() => {
                Ok(ReapOutcome::Retained)
            }
            Err(error) => Err(error),
        }
    }

    /// One reaper step at `now`: reconcile `schedule` with the current
    /// reapable set and end every terminal whose deadline passed, and the
    /// longest-closed past [`MAX_TERMINALS_IN_REAP_GRACE`]. Several due
    /// terminals are ended in parallel, so a burst of closed tabs is reaped
    /// within the grace period plus the slowest single reap instead of their
    /// sum. Returns the host ids it ended.
    pub(crate) fn reap_unplaced_terminals(
        &self,
        schedule: &mut ReapSchedule,
        now: Instant,
    ) -> Vec<String> {
        // A daemon that is shutting down hands its terminals to the next
        // owner; it must not end one on the way out.
        if self.shutting_down.load(Ordering::Acquire) {
            return Vec::new();
        }
        let grace = self.terminal_reap_grace();
        let over_cap = match self.reapable_terminals_unplaced_for(&mut schedule.unplaced_rows_empty)
        {
            Ok(reapable) => {
                schedule.observe_unplaced(now, grace, &reapable);
                over_grace_cap(&reapable)
            }
            Err(error) => {
                self.report_internal_diagnostic(format!("terminal reap scan failed: {error}"));
                schedule.defer_due_after_failed_scan(now);
                return Vec::new();
            }
        };
        let mut due = schedule.due(now);
        for terminal_id in over_cap {
            if !due.contains(&terminal_id) {
                due.push(terminal_id);
            }
        }
        let outcomes = self.reap_in_parallel(&due);
        let mut reaped = Vec::new();
        for (terminal_id, outcome) in due.into_iter().zip(outcomes) {
            let outcome = outcome
                .inspect_err(|error| {
                    self.report_internal_diagnostic(format!(
                        "reap of unplaced terminal {terminal_id} failed: {error}"
                    ));
                })
                .ok();
            schedule.tried(&terminal_id, outcome, now, grace);
            if outcome == Some(ReapOutcome::Reaped) {
                reaped.push(terminal_id);
            }
        }
        reaped
    }

    /// [`Self::reap_unplaced_terminal`] for each of `due`, at most
    /// [`MAX_PARALLEL_REAPS`] at once, in the order of `due`.
    fn reap_in_parallel(&self, due: &[String]) -> Vec<anyhow::Result<ReapOutcome>> {
        if due.len() <= 1 {
            return due
                .iter()
                .map(|terminal_id| self.reap_unplaced_terminal(terminal_id))
                .collect();
        }
        let mut outcomes = Vec::with_capacity(due.len());
        for chunk in due.chunks(MAX_PARALLEL_REAPS) {
            std::thread::scope(|scope| {
                let jobs: Vec<_> = chunk
                    .iter()
                    .map(|terminal_id| {
                        std::thread::Builder::new()
                            .name("mux-terminal-reap-job".into())
                            .spawn_scoped(scope, move || self.reap_unplaced_terminal(terminal_id))
                            .map_err(|error| (terminal_id, error))
                    })
                    .collect();
                for job in jobs {
                    outcomes.push(match job {
                        Ok(handle) => handle
                            .join()
                            .unwrap_or_else(|_| Err(anyhow::anyhow!("reap job panicked"))),
                        // No thread for this one: reap it on this thread.
                        Err((terminal_id, _)) => self.reap_unplaced_terminal(terminal_id),
                    });
                }
            });
        }
        outcomes
    }
}

/// Retry delay for an attached or failed reap when the grace period is zero.
const MIN_RETRY: Duration = Duration::from_secs(1);
/// Retry spacing after a failed reapable-set scan.
const SCAN_RETRY_INITIAL: Duration = Duration::from_secs(1);
const SCAN_RETRY_MAX: Duration = Duration::from_secs(60);

/// Owner-side reaper thread. `stop` wakes and joins it; dropping the handle
/// wakes it without joining.
pub struct TerminalReaper {
    stop: Arc<AtomicBool>,
    /// The receiver the thread currently waits on; it changes when an
    /// overflowed subscription is replaced.
    events: Arc<Mutex<MuxEventReceiver>>,
    thread: Option<JoinHandle<()>>,
}

impl TerminalReaper {
    pub fn stop(mut self) {
        self.signal_stop();
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }

    fn signal_stop(&self) {
        self.stop.store(true, Ordering::Release);
        self.events.lock().unwrap_or_else(PoisonError::into_inner).close();
    }
}

impl Drop for TerminalReaper {
    fn drop(&mut self) {
        self.signal_stop();
    }
}

/// Start the unplaced-terminal reaper for an owner with the mux's current
/// grace period. It runs until stopped or the mux is gone.
pub fn start_terminal_reaper(mux: &Arc<Mux>) -> std::io::Result<TerminalReaper> {
    let stop = Arc::new(AtomicBool::new(false));
    let events = Arc::new(Mutex::new(mux.subscribe_terminal_reaper()));
    let weak = Arc::downgrade(mux);
    let thread_stop = stop.clone();
    let shared_events = events.clone();
    let mut thread_events = events.lock().unwrap_or_else(PoisonError::into_inner).clone();
    let thread = std::thread::Builder::new().name("mux-terminal-reap".into()).spawn(move || {
        let mut schedule = ReapSchedule::default();
        loop {
            if thread_stop.load(Ordering::Acquire) {
                break;
            }
            let Some(mux) = weak.upgrade() else { break };
            mux.reap_unplaced_terminals(&mut schedule, Instant::now());
            // Never hold the mux across the wait: the thread must not keep
            // the mux alive after its other owners are gone.
            drop(mux);
            let wait =
                schedule.next_deadline().map(|at| at.saturating_duration_since(Instant::now()));
            let event = match wait {
                Some(wait) => thread_events.recv_timeout(wait),
                None => thread_events.recv().map_err(|_| RecvTimeoutError::Disconnected),
            };
            match event {
                Ok(_) | Err(RecvTimeoutError::Timeout) => {
                    // Coalesce a burst of topology events into one scan. A
                    // disconnect surfaces at the next wait.
                    while thread_events.try_recv().is_ok() {}
                }
                Err(RecvTimeoutError::Disconnected) => {
                    if thread_stop.load(Ordering::Acquire) {
                        break;
                    }
                    // The mailbox overflowed: resubscribe, then rescan. The
                    // loop checks `stop` again before it next waits.
                    let Some(mux) = weak.upgrade() else { break };
                    thread_events = mux.subscribe_terminal_reaper();
                    *shared_events.lock().unwrap_or_else(PoisonError::into_inner) =
                        thread_events.clone();
                }
            }
        }
        // Stopped: `identify` no longer advertises a running reaper.
        if let Some(mux) = weak.upgrade() {
            mux.end_terminal_reaper();
        }
    });
    let thread = match thread {
        Ok(thread) => thread,
        Err(error) => {
            mux.end_terminal_reaper();
            return Err(error);
        }
    };
    Ok(TerminalReaper { stop, events, thread: Some(thread) })
}

impl Mux {
    /// Whether this owner's unplaced-terminal reaper runs
    /// (`terminal-reaper-active-v1`).
    pub fn terminal_reaper_running(&self) -> bool {
        self.terminal_reaper_events.lock().unwrap_or_else(PoisonError::into_inner).is_some()
    }

    /// Announce that this owner starts the unplaced-terminal reaper once its
    /// socket is bound. The socket answers `identify` from the moment it is
    /// bound, so a client that identifies before the reaper thread runs must
    /// already see `terminal-reaper-active-v1`. The announcement ends when
    /// the reaper stops or its start fails.
    pub fn announce_terminal_reaper(&self) {
        self.terminal_reaper_announced.store(true, Ordering::Release);
    }

    /// Whether `identify` lists `terminal-reaper-active-v1`: the reaper runs,
    /// or this owner announced that it starts it.
    pub fn terminal_reaper_advertised(&self) -> bool {
        self.terminal_reaper_announced.load(Ordering::Acquire) || self.terminal_reaper_running()
    }

    /// The reaper stopped or did not start: `identify` no longer lists it.
    fn end_terminal_reaper(&self) {
        self.terminal_reaper_announced.store(false, Ordering::Release);
        self.terminal_reaper_events.lock().unwrap_or_else(PoisonError::into_inner).take();
    }

    /// Subscribe the reaper to the events that can change the reapable set,
    /// and keep a handle so a grace change can wake it.
    fn subscribe_terminal_reaper(&self) -> MuxEventReceiver {
        let events = self.subscribers.subscribe_terminal_topology();
        *self.terminal_reaper_events.lock().unwrap_or_else(PoisonError::into_inner) =
            Some(events.clone());
        events
    }
}

#[cfg(test)]
mod tests;
