//! Deferred detaches of signal exits (`session-shutdown`, logout race).
//!
//! A live process end by signal commits its exit receipt without detaching
//! the terminal's tabs while a shutdown start could still make it a host
//! loss ([`crate::session_shutdown::SettledEnd::Pending`]). This timer holds
//! one deadline per such terminal and, once it passed, runs the reconciling
//! detach ([`Mux::detach_exited_terminal_topology`]), which classifies the
//! receipt again. A deadline is a one-shot condition-variable wait, never a
//! polling loop. The worker exits when no deadline is left, when the owner
//! starts shutting down, or when the owner is gone; the next owner
//! re-classifies an unsettled receipt at startup against the recorded
//! shutdown window, with the same result.

use std::collections::BTreeMap;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Condvar, Mutex, OnceLock, Weak};
use std::time::Duration;

use super::Mux;

/// How often a failed deferred detach is retried before it is left to the
/// next owner's startup reconciliation.
const SETTLE_ATTEMPTS: u32 = 8;
/// The first retry delay; it doubles up to [`SETTLE_RETRY_MAX_MS`].
const SETTLE_RETRY_MS: u64 = 25;
const SETTLE_RETRY_MAX_MS: u64 = 5_000;

#[derive(Default)]
pub(super) struct ExitSettleTimer {
    state: Mutex<ExitSettleState>,
    changed: Condvar,
    /// Serializes taking and running due detaches, so a caller of
    /// [`Mux::run_due_exit_settles`] returns after every due detach ran.
    /// Never held by `schedule`, which callers reach with the registry lock.
    running: Mutex<()>,
    /// The owner, bound once right after it is built.
    mux: OnceLock<Weak<Mux>>,
}

#[derive(Default)]
struct ExitSettleState {
    /// Internal terminal id -> when to detach.
    deadlines: BTreeMap<String, Deadline>,
    worker_running: bool,
}

#[derive(Clone, Copy)]
struct Deadline {
    /// Unix milliseconds.
    until_ms: u64,
    /// Failed detach attempts so far.
    failures: u32,
}

impl ExitSettleTimer {
    pub(super) fn bind(&self, mux: Weak<Mux>) {
        let _ = self.mux.set(mux);
    }

    fn take_due(&self, now_ms: u64) -> Vec<(String, u32)> {
        let mut state = self.state.lock().unwrap();
        let due = state
            .deadlines
            .iter()
            .filter(|(_, deadline)| deadline.until_ms <= now_ms)
            .map(|(terminal_id, deadline)| (terminal_id.clone(), deadline.failures))
            .collect::<Vec<_>>();
        for (terminal_id, _) in &due {
            state.deadlines.remove(terminal_id);
        }
        due
    }

    fn earliest(state: &ExitSettleState) -> Option<u64> {
        state.deadlines.values().map(|deadline| deadline.until_ms).min()
    }

    fn stop_worker(&self) {
        let mut state = self.state.lock().unwrap();
        state.deadlines.clear();
        state.worker_running = false;
    }

    fn run_worker(self: Arc<Self>, mux: Weak<Mux>) {
        loop {
            let next = {
                let mut state = self.state.lock().unwrap();
                match Self::earliest(&state) {
                    Some(next) => next,
                    None => {
                        state.worker_running = false;
                        return;
                    }
                }
            };
            let Some(owner) = mux.upgrade() else {
                self.stop_worker();
                return;
            };
            if owner.shutting_down.load(Ordering::Acquire) {
                drop(owner);
                self.stop_worker();
                return;
            }
            let now_ms = owner.session_shutdown.now_ms();
            if next <= now_ms {
                owner.run_due_exit_settles();
                continue;
            }
            // Hold no owner reference while waiting.
            drop(owner);
            let state = self.state.lock().unwrap();
            // An earlier deadline scheduled meanwhile restarts the loop.
            if Self::earliest(&state) == Some(next) {
                let _ = self.changed.wait_timeout(state, Duration::from_millis(next - now_ms));
            }
        }
    }
}

impl Mux {
    /// Detach `terminal_id`'s tabs at `until_ms` unless a shutdown started
    /// meanwhile; the detach re-classifies the durable receipt.
    pub(super) fn schedule_exit_settle(&self, terminal_id: &str, until_ms: u64) {
        self.schedule_exit_settle_attempt(terminal_id, Deadline { until_ms, failures: 0 });
    }

    fn schedule_exit_settle_attempt(&self, terminal_id: &str, scheduled: Deadline) {
        let timer = &self.exit_settles;
        let mut state = timer.state.lock().unwrap();
        let deadline = state.deadlines.entry(terminal_id.to_string()).or_insert(scheduled);
        deadline.until_ms = deadline.until_ms.min(scheduled.until_ms);
        deadline.failures = deadline.failures.max(scheduled.failures);
        timer.changed.notify_all();
        if state.worker_running {
            return;
        }
        let Some(mux) = timer.mux.get().cloned() else {
            // An owner that is not bound yet (construction) settles at the
            // next start, which re-classifies every exited terminal.
            return;
        };
        state.worker_running = true;
        drop(state);
        let worker = Arc::clone(timer);
        if let Err(error) = std::thread::Builder::new()
            .name("terminal-exit-settle".to_string())
            .spawn(move || worker.run_worker(mux))
        {
            timer.state.lock().unwrap().worker_running = false;
            eprintln!("cmux-tui: could not start the terminal exit settle worker: {error:#}");
        }
    }

    /// Run every deferred detach whose deadline passed. A failed detach is
    /// retried with a doubling delay; after [`SETTLE_ATTEMPTS`] failures it
    /// is left to the next owner's startup reconciliation. The tab stays
    /// dead meanwhile (the safe side of invariant 3). Nothing runs once the
    /// owner shuts down; the next owner settles the receipts.
    pub(super) fn run_due_exit_settles(&self) {
        let _running = self.exit_settles.running.lock().unwrap();
        let now_ms = self.session_shutdown.now_ms();
        for (terminal_id, failures) in self.exit_settles.take_due(now_ms) {
            if self.shutting_down.load(Ordering::Acquire) {
                return;
            }
            let Err(error) = self.detach_exited_terminal_topology(&terminal_id) else {
                continue;
            };
            let failures = failures + 1;
            eprintln!(
                "cmux-tui: could not settle exited terminal {terminal_id} \
                 (attempt {failures} of {SETTLE_ATTEMPTS}): {error:#}"
            );
            if failures < SETTLE_ATTEMPTS {
                let delay_ms = (SETTLE_RETRY_MS << (failures - 1).min(16)).min(SETTLE_RETRY_MAX_MS);
                self.schedule_exit_settle_attempt(
                    &terminal_id,
                    Deadline { until_ms: now_ms.saturating_add(delay_ms), failures },
                );
            }
        }
    }
}
