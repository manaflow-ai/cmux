//! The output store's writer thread: it sleeps until a terminal prints or asks for a measurement,
//! then runs the turn that is due: the measurement of the terminals whose history grew
//! (`memory_budget.rs`), the snapshot and tail pass (`snapshot.rs`), or both.

use std::sync::{Arc, Condvar, Mutex, PoisonError, Weak};
use std::time::{Duration, Instant};

use super::snapshot::write_pass;
use super::{OutputStore, PersistencePolicy};
use crate::Mux;

#[derive(Default)]
pub(super) struct WriterState {
    /// When the pending changes are due; `None` while nothing changed.
    pub(super) due: Option<Instant>,
    /// A terminal's history grew by a step: its measurement (and a budget
    /// pass when the total is over the trigger) is due now
    /// (`memory_budget.rs`), apart from `due`.
    memory_due: bool,
    /// When the parked snapshots' trim (`parked_trim.rs`) last ran with a pass; `None`: not yet.
    last_trim: Option<Instant>,
    stop: bool,
}

/// The background writer: one thread, woken by the first output after a
/// write and by stop.
#[derive(Default)]
pub(super) struct Writer {
    pub(super) state: Arc<(Mutex<WriterState>, Condvar)>,
    thread: Mutex<Option<std::thread::JoinHandle<()>>>,
}

impl Writer {
    pub(super) fn start(&self, mux: Weak<Mux>) -> anyhow::Result<()> {
        // The store's prune at start trims the parked snapshots: the day of the next trim starts now.
        self.state.0.lock().unwrap_or_else(PoisonError::into_inner).last_trim =
            Some(Instant::now());
        let state = self.state.clone();
        let thread = std::thread::Builder::new()
            .name("mux-output-store-writer".into())
            .spawn(move || run(&mux, &state))?;
        *self.thread.lock().unwrap_or_else(PoisonError::into_inner) = Some(thread);
        Ok(())
    }

    /// A terminal printed after the writer last looked at it: a pass is due
    /// `interval` from now, unless one is due sooner.
    pub(super) fn mark_dirty(&self, interval: Duration) {
        let (lock, changed) = &*self.state;
        let mut state = lock.lock().unwrap_or_else(PoisonError::into_inner);
        let due = Instant::now() + interval;
        if state.due.is_none_or(|current| due < current) {
            state.due = Some(due);
            changed.notify_all();
        }
    }

    /// A terminal's history grew by a step: measure it at once. Requests
    /// coalesce until the writer wakes, so a flood asks for one pass at a
    /// time.
    pub(super) fn request_memory_pass(&self) {
        let (lock, changed) = &*self.state;
        let mut state = lock.lock().unwrap_or_else(PoisonError::into_inner);
        if !state.memory_due {
            state.memory_due = true;
            changed.notify_all();
        }
    }

    pub(super) fn stop(&self) {
        {
            let (lock, changed) = &*self.state;
            lock.lock().unwrap_or_else(PoisonError::into_inner).stop = true;
            changed.notify_all();
        }
        if let Some(thread) = self.thread.lock().unwrap_or_else(PoisonError::into_inner).take() {
            // The writer can hold the last Mux handle, so the Mux may drop
            // (and stop the writer) on the writer thread itself.
            if thread.thread().id() != std::thread::current().id() {
                let _ = thread.join();
            }
        }
    }
}

fn run(mux: &Weak<Mux>, state: &(Mutex<WriterState>, Condvar)) {
    let (lock, changed) = state;
    loop {
        let turn = {
            let mut guard = lock.lock().unwrap_or_else(PoisonError::into_inner);
            loop {
                if guard.stop {
                    return;
                }
                if let Some(turn) = take_turn(&mut guard, Instant::now()) {
                    break turn;
                }
                match guard.due {
                    // An idle session wakes once a day, for the parked snapshots' trim.
                    None => {
                        let wait = guard.last_trim.map_or(super::parked_trim::PASS_EVERY, |last| {
                            (last + super::parked_trim::PASS_EVERY)
                                .saturating_duration_since(Instant::now())
                        });
                        let (next, waited) = changed
                            .wait_timeout(guard, wait)
                            .unwrap_or_else(PoisonError::into_inner);
                        guard = next;
                        if waited.timed_out() {
                            guard.due = Some(Instant::now());
                        }
                    }
                    Some(due) => {
                        let now = Instant::now();
                        if now >= due {
                            // Due between the look above and this one: the next turn takes it.
                            continue;
                        }
                        guard = changed
                            .wait_timeout(guard, due - now)
                            .unwrap_or_else(PoisonError::into_inner)
                            .0;
                    }
                }
            }
        };
        let Some(mux) = mux.upgrade() else { return };
        for pass in turn.passes() {
            match pass {
                Pass::Memory => memory_pass(&mux, &mux.output_store),
                Pass::Write { trim } => {
                    if trim {
                        let pending = &mux.output_store.prune_pending;
                        pending.store(true, std::sync::atomic::Ordering::Release);
                    }
                    write_pass(&mux, &mux.output_store);
                }
            }
        }
    }
}

/// What one turn of the writer runs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Turn {
    /// Measure the terminals whose history grew, then the budget pass when the total is over its trigger.
    memory: bool,
    /// The snapshot and tail pass.
    write: bool,
    /// With the write pass: the parked snapshots' trim.
    trim: bool,
}

/// One pass of a turn.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Pass {
    /// `memory_pass`.
    Memory,
    /// `write_pass`; `trim`: the parked snapshots' trim runs with it.
    Write { trim: bool },
}

impl Turn {
    /// The passes of this turn, in the order `run` runs them. The measurement is first: it is
    /// short, and a write pass can wait for the disk.
    fn passes(self) -> impl Iterator<Item = Pass> {
        let write = self.write.then_some(Pass::Write { trim: self.trim });
        [self.memory.then_some(Pass::Memory), write].into_iter().flatten()
    }
}

/// The turn to run at `now`, taken out of `state`; `None`: wait. A due write pass and a request for a
/// measurement go into the same turn, so a stream of requests never starves snapshots, and a write pass never
/// takes a request away. The write pass runs the budget only once per interval (`OutputStore::enforce_due`),
/// and a terminal whose request is open does not ask again (`LogState::measure_due`). So a request dropped
/// here was served only by a later request of another terminal that was taken with no write pass due
/// (`memory_budget::measure_due` takes every flagged terminal), or by that interval.
fn take_turn(state: &mut WriterState, now: Instant) -> Option<Turn> {
    let memory = std::mem::take(&mut state.memory_due);
    if state.due.is_some_and(|due| now >= due) {
        state.due = None;
        return Some(Turn { memory, write: true, trim: take_trim(state) });
    }
    memory.then_some(Turn { memory: true, write: false, trim: false })
}

/// Whether this pass runs the parked snapshots' trim: once a day, however busy the session is. The store's prune
/// at start runs it too, so the first day starts then.
fn take_trim(state: &mut WriterState) -> bool {
    let now = Instant::now();
    match state.last_trim {
        // The store's prune at start ran the first one: the day starts at the first pass.
        None => {
            state.last_trim = Some(now);
            false
        }
        Some(last) if now.duration_since(last) >= super::parked_trim::PASS_EVERY => {
            state.last_trim = Some(now);
            true
        }
        Some(_) => false,
    }
}

/// Measure the terminals whose history grew, and run the budget pass when the
/// total is over its trigger. It runs between write passes, and first in a turn
/// that also has a due write pass; the snapshots keep their own interval.
fn memory_pass(mux: &Arc<Mux>, store: &OutputStore) {
    let policy = store.cached_policy().unwrap_or_else(|| PersistencePolicy::current(mux));
    let _pass = store.lock_pass();
    super::memory_budget::measure_due(mux, store, policy.memory_total_bytes);
}

#[cfg(test)]
#[path = "writer_tests.rs"]
mod tests;
