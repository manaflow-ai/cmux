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

// Red commit: the reaper API with stub bodies, so the tests compile and fail
// on behavior. The fix commit replaces the stubs and removes this attribute.
#![allow(dead_code)]

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

    /// Red stub: sees no terminal.
    pub(crate) fn reapable_and_retained_terminals(
        &self,
    ) -> anyhow::Result<(HashSet<String>, HashSet<String>)> {
        Ok((HashSet::new(), HashSet::new()))
    }

    /// Red stub: ends nothing.
    pub(crate) fn reap_unplaced_terminal(&self, _terminal_id: &str) -> anyhow::Result<ReapOutcome> {
        Ok(ReapOutcome::Retained)
    }

    /// Red stub: ends nothing.
    pub(crate) fn reap_unplaced_terminals(
        &self,
        _schedule: &mut ReapSchedule,
        _now: Instant,
    ) -> Vec<String> {
        Vec::new()
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
            mux.terminal_reaper_events.lock().unwrap_or_else(PoisonError::into_inner).take();
        }
    });
    let thread = match thread {
        Ok(thread) => thread,
        Err(error) => {
            mux.terminal_reaper_events.lock().unwrap_or_else(PoisonError::into_inner).take();
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
