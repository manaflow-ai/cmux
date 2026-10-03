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
    /// Internal terminal id -> Unix milliseconds at which to detach.
    deadlines: BTreeMap<String, u64>,
    worker_running: bool,
}

impl ExitSettleTimer {
    pub(super) fn bind(&self, mux: Weak<Mux>) {
        let _ = self.mux.set(mux);
    }

    fn take_due(&self, now_ms: u64) -> Vec<String> {
        let mut state = self.state.lock().unwrap();
        let due = state
            .deadlines
            .iter()
            .filter(|(_, until_ms)| **until_ms <= now_ms)
            .map(|(terminal_id, _)| terminal_id.clone())
            .collect::<Vec<_>>();
        for terminal_id in &due {
            state.deadlines.remove(terminal_id);
        }
        due
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
                match state.deadlines.values().min().copied() {
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
            if state.deadlines.values().min().copied() == Some(next) {
                let _ = self.changed.wait_timeout(state, Duration::from_millis(next - now_ms));
            }
        }
    }
}

impl Mux {
    /// Detach `terminal_id`'s tabs at `until_ms` unless a shutdown started
    /// meanwhile; the detach re-classifies the durable receipt.
    pub(super) fn schedule_exit_settle(&self, terminal_id: &str, until_ms: u64) {
        let timer = &self.exit_settles;
        let mut state = timer.state.lock().unwrap();
        let deadline = state.deadlines.entry(terminal_id.to_string()).or_insert(until_ms);
        *deadline = (*deadline).min(until_ms);
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
    /// logged and left to the next owner's startup reconciliation; the tab
    /// stays dead meanwhile (the safe side of invariant 3).
    pub(super) fn run_due_exit_settles(&self) {
        let _running = self.exit_settles.running.lock().unwrap();
        let now_ms = self.session_shutdown.now_ms();
        for terminal_id in self.exit_settles.take_due(now_ms) {
            if let Err(error) = self.detach_exited_terminal_topology(&terminal_id) {
                eprintln!("cmux-tui: could not settle exited terminal {terminal_id}: {error:#}");
            }
        }
    }
}
