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
//! - **Blocking.** A run reads without blocking. Registry publication
//!   (directory, progress, the exit) goes to the terminal work pool, but a
//!   query response written to a PTY whose child does not read its input
//!   still waits, as does any publication the full pool hands back. Those
//!   calls run in [`will_block`], Chrome's `ScopedBlockingCall` with
//!   `BlockingType::WILL_BLOCK` (base/threading/scoped_blocking_call.h): a
//!   worker inside it stops counting against [`MAX_READ_WORKERS`], so the
//!   other ready sources get a worker at once, as Chrome's thread group
//!   raises its max tasks for a worker that will block
//!   (base/task/thread_pool/thread_group.cc, `BlockingStarted`). A blocked
//!   terminal holds only its own thread, as its reader thread did.
//! - **Lifetime.** A source lives in the loop until its run returns
//!   [`ReadFlow::Finished`] (its end of stream); the loop then stops watching
//!   the descriptor before [`ReadSource::finish`] may close it. A dropped
//!   owner never cuts a live terminal off: the loop and its workers end
//!   once the last source finished.

use std::cell::RefCell;
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
    /// descriptor: the source may close it now. It may block: the loop runs
    /// it in [`will_block`].
    fn finish(self: Box<Self>);
}

thread_local! {
    /// The loop of the read worker on this thread, for [`will_block`].
    static WORKER_LOOP: RefCell<Option<Arc<Shared>>> = const { RefCell::new(None) };
}

/// Runs `f`, which may wait on others (a PTY write, sqlite, a contended
/// lock). On a read worker, the worker does not count against
/// [`MAX_READ_WORKERS`] while `f` runs, so a source that blocks here never
/// keeps another one from being read. Anywhere else it only runs `f`.
pub(crate) fn will_block<R>(f: impl FnOnce() -> R) -> R {
    // Taken for the scope, so a nested call only runs its `f`.
    let Some(shared) = WORKER_LOOP.with(|worker| worker.borrow_mut().take()) else { return f() };
    let _blocked = BlockedWorker::start(shared);
    f()
}

/// A read worker inside [`will_block`]; ends the scope on drop, an unwind
/// included.
struct BlockedWorker {
    shared: Option<Arc<Shared>>,
}

impl BlockedWorker {
    fn start(shared: Arc<Shared>) -> Self {
        {
            let mut state = shared.lock();
            state.blocked += 1;
            // A queued source gets the slot this worker leaves now.
            if !state.runnable.is_empty() {
                shared.start_worker(state);
            }
        }
        Self { shared: Some(shared) }
    }
}

impl Drop for BlockedWorker {
    fn drop(&mut self) {
        let Some(shared) = self.shared.take() else { return };
        shared.lock().blocked -= 1;
        WORKER_LOOP.with(|worker| *worker.borrow_mut() = Some(shared));
    }
}

/// A worker's place in its loop. A worker that exits gives its slot back
/// under the lock it decided in ([`Self::leave`]); one that unwinds gives it
/// back on drop and hands a queued source on, so a panic never keeps a slot
/// no thread holds.
struct WorkerSlot {
    shared: Arc<Shared>,
    held: bool,
}

impl WorkerSlot {
    fn enter(shared: &Arc<Shared>) -> Self {
        WORKER_LOOP.with(|worker| *worker.borrow_mut() = Some(shared.clone()));
        Self { shared: shared.clone(), held: true }
    }

    fn leave(&mut self, state: &mut State) {
        state.workers -= 1;
        self.held = false;
    }
}

impl Drop for WorkerSlot {
    fn drop(&mut self) {
        WORKER_LOOP.with(|worker| worker.borrow_mut().take());
        if !self.held {
            return;
        }
        let mut state = self.shared.lock();
        state.workers -= 1;
        if !state.runnable.is_empty() {
            self.shared.start_worker(state);
        }
    }
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
    /// Workers inside [`will_block`]: they do not count against
    /// [`MAX_READ_WORKERS`].
    blocked: usize,
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
    pub(crate) blocked: usize,
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
            // Not watched yet and no kick handed out, so nothing ran it.
            #[allow(
                clippy::expect_used,
                reason = "INVARIANT: the entry was inserted with its source above and no kick was handed out, so nothing took it"
            )]
            let source =
                entry.and_then(|entry| entry.source).expect("an unwatched source is never running");
            return Err(source);
        }
        Ok(ReadKick { shared: Arc::downgrade(shared), token })
    }

    #[cfg(test)]
    pub(crate) fn stats(&self) -> ReadLoopStats {
        let Some(shared) = self.shared.get() else { return ReadLoopStats::default() };
        let state = shared.lock();
        ReadLoopStats {
            sources: state.entries.len(),
            workers: state.workers,
            parked: state.parked,
            blocked: state.blocked,
        }
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

    /// Workers that count against [`MAX_READ_WORKERS`]: the ones not
    /// inside [`will_block`].
    fn active(state: &State) -> usize {
        state.workers - state.blocked
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
        if state.runnable.len() <= state.parked || Self::active(&state) >= MAX_READ_WORKERS {
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
            #[allow(
                clippy::expect_used,
                reason = "INVARIANT: a runnable token's entry keeps its source until this take marks it Running"
            )]
            let source = entry.source.take().expect("a queued source is not running");
            return Some((token, source));
        }
        None
    }

    fn work_loop(self: &Arc<Self>) {
        let mut slot = WorkerSlot::enter(self);
        let mut state = self.lock();
        loop {
            // One more than the bound while a blocked worker came back: the
            // others drain the queue.
            if Self::active(&state) > MAX_READ_WORKERS {
                slot.leave(&mut state);
                return;
            }
            if let Some((token, source)) = self.next_run(&mut state) {
                drop(state);
                self.run(token, source);
                state = self.lock();
                continue;
            }
            if state.parked >= PARKED_READ_WORKERS || Self::done(&state) {
                slot.leave(&mut state);
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
        #[allow(
            clippy::expect_used,
            reason = "INVARIANT: only a token's own run removes its entry (unwatch after this lookup), so it is registered while it runs"
        )]
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

    /// Stops watching `token` and finishes its source. A panicking finish
    /// ends only that source, as a panicking run does.
    fn remove(self: &Arc<Self>, token: u64) {
        let Some(source) = self.unwatch(token) else { return };
        let finished = will_block(|| {
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| source.finish()))
        });
        if finished.is_err() {
            eprintln!("cmux-tui: a terminal read source's finish panicked");
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
    crate::supervised::spawn_at(
        READ_LOOP_THREAD,
        crate::echo_thread::ECHO_PATH_QOS,
        crate::supervised::Fatal,
        crate::supervised::ShutdownBehavior::Continue,
        move || {
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
        },
    )
    .map(drop)
}

#[cfg(test)]
#[path = "read_loop_tests.rs"]
mod tests;
