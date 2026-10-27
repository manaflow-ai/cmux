//! One readiness loop for the output of every daemon-local PTY terminal,
//! instead of one blocking `surface-<id>-reader` thread per terminal.
//!
//! This is Chromium's IO-thread split (content/browser/browser_thread_impl.cc
//! over base/message_loop/message_pump_kqueue.cc): the `mux-terminal-io`
//! thread only waits on one kqueue (epoll on Linux) and routes; it runs no
//! handler. A ready terminal becomes one run on the `mux-terminal-read`
//! workers, which read and parse its output as the reader thread did.
//!
//! - **Order.** A source has at most one run queued or running. Its
//!   descriptor is watched one-shot and armed again only after the run
//!   ends, and a [`ReadKick`] during a run queues one more run after it, so
//!   one terminal's output is read and published in order on whichever
//!   worker runs it.
//! - **Fairness.** A run reads at most [`READS_PER_RUN`] chunks and then
//!   yields: a terminal that keeps writing goes behind the other ready ones.
//! - **Threads.** One loop thread per owner, started with the first source.
//!   Workers start on demand up to [`MAX_READ_WORKERS`]; with nothing to run,
//!   [`PARKED_READ_WORKERS`] of them park with no timeout (the next echo runs
//!   at once, no thread start) and the others exit. So any number of idle
//!   terminals costs two threads and no wakeup.
//! - **Lifetime.** A source lives in the loop until its run returns
//!   [`ReadFlow::Finished`] (its end of stream); the loop then stops watching
//!   the descriptor before [`ReadSource::finish`] may close it. A dropped
//!   owner never cuts a live terminal off: the loop and its workers end
//!   once the last source finished.

use std::collections::{HashMap, VecDeque};
use std::io;
use std::os::fd::RawFd;
use std::sync::{Arc, Condvar, Mutex, MutexGuard, OnceLock, PoisonError, Weak};

use super::read_poller::{Poller, WAKE_TOKEN};

/// Chunks one run reads before its source yields to the other ready ones.
pub(crate) const READS_PER_RUN: usize = 4;

/// Workers that run ready sources at once.
pub(crate) const MAX_READ_WORKERS: usize = 4;

/// Workers that wait for the next ready source instead of exiting.
const PARKED_READ_WORKERS: usize = 1;

/// The loop thread: routes readiness, runs nothing.
pub(crate) const READ_LOOP_THREAD: &str = "mux-terminal-io";

/// The worker threads.
pub(crate) const READ_WORKER_THREAD: &str = "mux-terminal-read";

/// What a source wants after a run.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ReadFlow {
    /// Watch the descriptor again.
    Continue,
    /// The stream ended: stop watching, then [`ReadSource::finish`].
    Finished,
}

/// One terminal's output on the loop.
pub(crate) trait ReadSource: Send + 'static {
    /// Reads and publishes what is ready; never blocks waiting for more.
    fn run(&mut self) -> ReadFlow;

    /// Runs once, on a worker, after the loop stopped watching the
    /// descriptor: the source may close it now.
    fn finish(self: Box<Self>);
}

/// Queues one more run of a source, as its readiness would. A run already in
/// progress is followed by another one.
#[derive(Clone)]
pub(crate) struct ReadKick {
    shared: Weak<Shared>,
    token: u64,
}

impl ReadKick {
    pub(crate) fn kick(&self) {
        if let Some(shared) = self.shared.upgrade() {
            shared.ready(self.token);
        }
    }
}

enum Phase {
    /// Waiting for its descriptor (watched and armed).
    Armed,
    /// In the run queue.
    Queued,
    /// On a worker; `again` when it became ready during the run.
    Running { again: bool },
}

struct Entry {
    fd: RawFd,
    phase: Phase,
    /// `None` while a worker runs it.
    source: Option<Box<dyn ReadSource>>,
}

#[derive(Default)]
struct State {
    entries: HashMap<u64, Entry>,
    next_token: u64,
    runnable: VecDeque<u64>,
    workers: usize,
    parked: usize,
    /// The owner dropped its [`TerminalReads`]: end once no source is left.
    owner_gone: bool,
    loop_started: bool,
}

struct Shared {
    poller: Poller,
    state: Mutex<State>,
    work: Condvar,
}

/// Counts for tests.
#[cfg(test)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct ReadLoopStats {
    pub(crate) sources: usize,
    pub(crate) workers: usize,
    pub(crate) parked: usize,
}

/// The owner's handle on its read loop. The poller and the loop thread start
/// with the first source, so an owner with no daemon-local PTY holds neither.
#[derive(Default)]
pub(crate) struct TerminalReads {
    shared: OnceLock<Arc<Shared>>,
}

impl TerminalReads {
    pub(crate) fn new() -> Self {
        Self::default()
    }

    fn shared(&self) -> io::Result<&Arc<Shared>> {
        if let Some(shared) = self.shared.get() {
            return Ok(shared);
        }
        let shared = Arc::new(Shared {
            poller: Poller::new()?,
            state: Mutex::default(),
            work: Condvar::new(),
        });
        // A racing first register may have won; its poller is the one.
        Ok(self.shared.get_or_init(|| shared))
    }

    /// Watches `fd` for `source` and returns the kick that queues a run
    /// without readiness. `fd` must stay open until `source` finishes.
    /// Returns `source` when the descriptor cannot be watched or the loop
    /// thread cannot start.
    pub(crate) fn register(
        &self,
        fd: RawFd,
        source: Box<dyn ReadSource>,
    ) -> Result<ReadKick, Box<dyn ReadSource>> {
        let Ok(shared) = self.shared() else { return Err(source) };
        let token = {
            let mut state = shared.lock();
            if !state.loop_started {
                if spawn_loop(shared).is_err() {
                    return Err(source);
                }
                state.loop_started = true;
            }
            let token = state.next_token;
            state.next_token += 1;
            state.entries.insert(token, Entry { fd, phase: Phase::Armed, source: Some(source) });
            token
        };
        if shared.poller.add(fd, token).is_err() {
            let entry = shared.lock().entries.remove(&token);
            let source = entry.and_then(|entry| entry.source);
            // Not watched yet and no kick handed out, so nothing ran it.
            return Err(source.expect("an unwatched source is never running"));
        }
        Ok(ReadKick { shared: Arc::downgrade(shared), token })
    }

    #[cfg(test)]
    pub(crate) fn stats(&self) -> ReadLoopStats {
        let Some(shared) = self.shared.get() else { return ReadLoopStats::default() };
        let state = shared.lock();
        ReadLoopStats { sources: state.entries.len(), workers: state.workers, parked: state.parked }
    }
}

impl Drop for TerminalReads {
    fn drop(&mut self) {
        let Some(shared) = self.shared.get() else { return };
        shared.lock().owner_gone = true;
        shared.work.notify_all();
        let _ = shared.poller.wake();
    }
}

impl Shared {
    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn done(state: &State) -> bool {
        state.owner_gone && state.entries.is_empty()
    }

    /// `token`'s descriptor is ready or it was kicked.
    fn ready(self: &Arc<Self>, token: u64) {
        let mut state = self.lock();
        let Some(entry) = state.entries.get_mut(&token) else { return };
        match &mut entry.phase {
            Phase::Armed => entry.phase = Phase::Queued,
            Phase::Queued => return,
            Phase::Running { again } => {
                *again = true;
                return;
            }
        }
        state.runnable.push_back(token);
        self.start_worker(state);
    }

    /// Wakes a parked worker for the queue, or starts one. A worker that
    /// cannot start leaves the run queued for the next worker or readiness;
    /// it never runs on the caller, which may hold the source's own lock (a
    /// resize's drain kicks under it).
    fn start_worker(self: &Arc<Self>, mut state: MutexGuard<'_, State>) {
        if state.parked > 0 {
            self.work.notify_one();
        }
        if state.runnable.len() <= state.parked || state.workers >= MAX_READ_WORKERS {
            return;
        }
        state.workers += 1;
        drop(state);
        let shared = self.clone();
        if crate::echo_thread::spawn(READ_WORKER_THREAD, move || shared.work_loop()).is_err() {
            eprintln!("cmux-tui: a terminal read worker could not start");
            self.lock().workers -= 1;
        }
    }

    fn next_run(&self, state: &mut State) -> Option<(u64, Box<dyn ReadSource>)> {
        while let Some(token) = state.runnable.pop_front() {
            let Some(entry) = state.entries.get_mut(&token) else { continue };
            entry.phase = Phase::Running { again: false };
            let source = entry.source.take().expect("a queued source is not running");
            return Some((token, source));
        }
        None
    }

    fn work_loop(self: &Arc<Self>) {
        let mut state = self.lock();
        loop {
            if let Some((token, source)) = self.next_run(&mut state) {
                drop(state);
                self.run(token, source);
                state = self.lock();
                continue;
            }
            if state.parked >= PARKED_READ_WORKERS || Self::done(&state) {
                state.workers -= 1;
                return;
            }
            state.parked += 1;
            state = self.work.wait(state).unwrap_or_else(PoisonError::into_inner);
            state.parked -= 1;
        }
    }

    fn run(self: &Arc<Self>, token: u64, mut source: Box<dyn ReadSource>) {
        let flow = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| source.run()));
        let mut state = self.lock();
        let entry = state.entries.get_mut(&token).expect("a running source stays registered");
        match flow {
            Ok(ReadFlow::Continue) => {
                entry.source = Some(source);
                let fd = entry.fd;
                if matches!(entry.phase, Phase::Running { again: true }) {
                    entry.phase = Phase::Queued;
                    state.runnable.push_back(token);
                    return;
                }
                // Armed under the lock, so no kick can run it before its
                // descriptor is watched again.
                if self.poller.rearm(fd, token).is_ok() {
                    entry.phase = Phase::Armed;
                    return;
                }
                // The descriptor can no longer be watched: end the stream
                // here instead of leaving it unread. Still `Running`, so a
                // kick cannot queue it before it is removed.
                drop(state);
                self.remove(token);
            }
            Ok(ReadFlow::Finished) => {
                entry.source = Some(source);
                drop(state);
                self.remove(token);
            }
            Err(_) => {
                eprintln!("cmux-tui: a terminal read run panicked");
                drop(state);
                // Dropped without `finish`, as a panicking reader thread ended.
                drop(self.unwatch(token));
                drop(source);
            }
        }
    }

    /// Stops watching `token` and finishes its source.
    fn remove(self: &Arc<Self>, token: u64) {
        if let Some(source) = self.unwatch(token) {
            source.finish();
        }
    }

    /// Takes `token` out of the loop and stops watching its descriptor, so
    /// the source may close it. The last source of a dropped owner ends the
    /// loop and the parked workers.
    fn unwatch(&self, token: u64) -> Option<Box<dyn ReadSource>> {
        let (entry, done) = {
            let mut state = self.lock();
            let entry = state.entries.remove(&token);
            let done = Self::done(&state);
            if done {
                self.work.notify_all();
            }
            (entry, done)
        };
        if let Some(entry) = entry.as_ref() {
            let _ = self.poller.delete(entry.fd);
        }
        if done {
            let _ = self.poller.wake();
        }
        entry.and_then(|entry| entry.source)
    }
}

fn spawn_loop(shared: &Arc<Shared>) -> io::Result<()> {
    let shared = shared.clone();
    // Routing only: the loop waits in the poller and hands ready sources on.
    cmux_threads::spawn(READ_LOOP_THREAD, crate::echo_thread::ECHO_PATH_QOS, move || {
        let mut tokens = Vec::new();
        loop {
            if shared.poller.wait(&mut tokens).is_err() {
                // Leave the sources to the workers already running; a poller
                // that fails once fails every later wait too.
                eprintln!("cmux-tui: the terminal read loop's poller failed");
                return;
            }
            for &token in &tokens {
                if token != WAKE_TOKEN {
                    shared.ready(token);
                }
            }
            if Shared::done(&shared.lock()) {
                return;
            }
        }
    })
    .map(drop)
}

#[cfg(test)]
#[path = "read_loop_tests.rs"]
mod tests;
