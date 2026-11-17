//! The output store's writer thread: it sleeps until a terminal prints or asks for a measurement
//! (or until the tail files written since their last sync are due for it, `snapshot.rs` `sync_due_tails`),
//! then runs the turn that is due: the measurement of the terminals whose history grew
//! (`memory_budget.rs`), the snapshot and tail pass (`snapshot.rs`), or both.

use std::path::Path;
use std::sync::{Arc, Condvar, Mutex, PoisonError, Weak};
use std::time::{Duration, Instant};

use super::snapshot::write_pass;
use super::{OutputStore, PersistencePolicy};
use crate::Mux;
use crate::mux::stop_join;

/// The writer's thread, in what the owner's release says of a thread that a
/// stop left alive.
const OUTPUT_STORE_WRITER: &str = "output store writer";

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
    /// The thread that a stop left alive, for each later stop.
    left: Mutex<Option<Arc<std::thread::JoinHandle<()>>>>,
    /// The line that the store's stop wrote to stderr when it made no last
    /// write; a test reads it.
    #[cfg(test)]
    stop_line: Mutex<Option<String>>,
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

    /// Stop the writer and wait for its thread's end, with the bound that
    /// each join of a stop has (`mux/stop_join.rs`; decision of 2026-11-17).
    /// A thread that does not end in that time (a pass that waits for a lock
    /// or for the disk) is left alive: it goes with its name and with
    /// `owner`, the session folder of the store's owner, into the list that
    /// the owner's release reads, and each later stop finds it here.
    pub(super) fn stop(&self, owner: Option<&Path>) -> WriterStop {
        {
            let (lock, changed) = &*self.state;
            lock.lock().unwrap_or_else(PoisonError::into_inner).stop = true;
            changed.notify_all();
        }
        // Held to this stop's end: a stop that comes beside this one reads
        // what this one found.
        let mut left = self.left.lock().unwrap_or_else(PoisonError::into_inner);
        let thread = self.thread.lock().unwrap_or_else(PoisonError::into_inner).take();
        let Some(thread) = thread else {
            let lives = left.as_ref().is_some_and(|thread| !thread.is_finished());
            return if lives { WriterStop::LeftBefore } else { WriterStop::Ended };
        };
        // The writer can hold the last Mux handle, so the Mux may drop
        // (and stop the writer) on the writer thread itself.
        if thread.thread().id() == std::thread::current().id() {
            return WriterStop::Ended;
        }
        if stop_join::ended_by(&thread, Instant::now() + stop_join::STOP_JOIN_WAIT) {
            let _ = thread.join();
            return WriterStop::Ended;
        }
        let thread = Arc::new(thread);
        *left = Some(Arc::clone(&thread));
        stop_join::left(owner, OUTPUT_STORE_WRITER, move || thread.is_finished());
        WriterStop::LeftNow
    }
}

/// How a stop of the writer ended.
pub(super) enum WriterStop {
    /// The writer's thread ended, or the store had none.
    Ended,
    /// The thread did not end in this stop's bound: this stop left it alive.
    LeftNow,
    /// A stop before this one left the thread alive, and it still lives.
    LeftBefore,
}

impl OutputStore {
    /// Final write at quit, on the caller's thread: stop the writer, then
    /// make every terminal's unwritten bytes durable.
    ///
    /// A stop that left the writer alive makes no last write (decision of
    /// 2026-11-17): that write needs the pass lock, and a writer in a pass
    /// holds it. That stop says so in one stderr line. Each later stop that
    /// finds that thread alive makes no last write either, and has no line.
    pub(crate) fn shutdown(&self, mux: &Mux) {
        if self.directory.is_none() {
            return;
        }
        match self.writer.stop(self.directory().and_then(Path::parent)) {
            WriterStop::Ended => {}
            WriterStop::LeftBefore => return,
            WriterStop::LeftNow => {
                let line = format!(
                    "cmux-tui: the {OUTPUT_STORE_WRITER} did not stop within {} ms; shutdown \
                     goes on without it and makes no last write of the output store",
                    stop_join::STOP_JOIN_WAIT.as_millis()
                );
                eprintln!("{line}");
                #[cfg(test)]
                {
                    *self.writer.stop_line.lock().unwrap_or_else(PoisonError::into_inner) =
                        Some(line);
                }
                return;
            }
        }
        // A terminal whose bytes since its snapshot are all in a synced tail
        // is visited too: the pass reads its screen (a digest, no snapshot)
        // and writes a snapshot only where the tail cannot carry it, a
        // terminal on the alternate screen included (quit_pass_tests.rs).
        for log in self.logs.lock().unwrap_or_else(PoisonError::into_inner).values() {
            let mut state = log.state.lock().unwrap_or_else(PoisonError::into_inner);
            if state.tail_bytes > 0 {
                state.dirty = true;
            }
        }
        self.write_now(mux);
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

/// What a test of the store's stop needs. The store's own file is past its
/// size limit, so these are here.
#[cfg(test)]
mod worker_tests {
    use super::*;

    impl OutputStore {
        /// The line that this store's stop wrote to stderr when it made no last
        /// write; `None`: the stop made that write, or the store had no stop.
        pub(crate) fn stop_line(&self) -> Option<String> {
            self.writer.stop_line.lock().unwrap_or_else(PoisonError::into_inner).clone()
        }

        /// Gives the store of `mux` a writer that is in a pass: its thread holds
        /// the store's pass lock, runs `pass` and ends. The store's own writer
        /// ends at its stop first. The channel that comes back closes when the
        /// thread has given up the lock and its handle of `mux`.
        pub(crate) fn put_a_writer_in_a_pass(
            mux: &Arc<Mux>,
            pass: impl FnOnce() + Send + 'static,
        ) -> std::sync::mpsc::Receiver<()> {
            let writer = &mux.output_store.writer;
            writer.stop(mux.stop_owner());
            let (ends, ended) = std::sync::mpsc::channel();
            let owner = Arc::clone(mux);
            let thread = std::thread::spawn(move || {
                {
                    let _pass = owner.output_store.lock_pass();
                    pass();
                }
                drop(owner);
                drop(ends);
            });
            *writer.thread.lock().unwrap_or_else(PoisonError::into_inner) = Some(thread);
            ended
        }

        /// Whether the store's state of `terminal` says that output of it is
        /// in no file: bytes that no write took, a tail that no sync made
        /// durable, or a snapshot that a pass owes.
        pub(crate) fn has_unwritten_output_of(
            &self,
            terminal: &crate::resource::TerminalPublicId,
        ) -> bool {
            let logs = self.logs.lock().unwrap_or_else(PoisonError::into_inner);
            logs.get(terminal).is_some_and(|log| {
                let state = log.state.lock().unwrap_or_else(PoisonError::into_inner);
                !state.pending.is_empty() || state.tail_unsynced || state.force_snapshot
            })
        }
    }
}

#[cfg(test)]
#[path = "writer_tests.rs"]
mod tests;
