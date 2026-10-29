//! The mux's blocking work, off request threads (p02-threads section 3F).
//!
//! A request handler answers from memory; what would block (a file read, a
//! wait for another thread) goes to a lane of the mux's one
//! [`cmux_threads::work::Work`] (`Mux::work`, p02-threads 220) and reports
//! back through the mux when it finishes, as Chrome posts a `MayBlock` task
//! and replies on the calling sequence (base/task/thread_pool.h
//! `PostTaskAndReplyWithResult`). [`MuxWork`] holds the mux's weak
//! reference that those items get.

use cmux_threads::sync::Mutex;
use std::collections::VecDeque;
use std::sync::atomic::Ordering;
use std::sync::{Arc, MutexGuard, OnceLock, PoisonError, Weak};
use std::time::Duration;

use cmux_threads::work::{Lane, Priority, Refused, Shutdown, Work};

use super::Mux;

/// The owning mux, bound once it is built. Items posted through
/// [`Mux::post_mux_work`] get it weakly.
#[derive(Default)]
pub(crate) struct MuxWork {
    mux: OnceLock<Weak<Mux>>,
}

impl MuxWork {
    pub(super) fn bind(&self, mux: Weak<Mux>) {
        let _ = self.mux.set(mux);
    }

    /// The owning mux, for a caller that holds it only by reference.
    pub(super) fn owner(&self) -> Option<Arc<Mux>> {
        self.mux.get()?.upgrade()
    }
}

impl Mux {
    /// What reaps the terminal hosts this mux launches: its one child reaper
    /// (`Mux::reaper`). Windows has none: a committed host is detached.
    #[cfg(any(unix, windows))]
    pub(crate) fn host_reaper(&self) -> Option<&crate::terminal_host_runtime::HostReaper> {
        #[cfg(unix)]
        return Some(&*self.reaper);
        #[cfg(windows)]
        return None;
    }

    /// Queues `body` on `Mux::work` with the mux's weak reference. The body
    /// upgrades it only for the moment it touches the mux, never across a
    /// wait, so an item that waits never keeps a dropped mux alive and never
    /// runs `Mux::drop` late on a worker.
    pub(super) fn post_mux_work(
        &self,
        priority: Priority,
        lane: Lane,
        shutdown: Shutdown,
        body: impl FnOnce(&Weak<Mux>) + Send + 'static,
    ) -> Result<(), Refused> {
        let mux = self.mux_work.mux.get().cloned().ok_or(Refused)?;
        self.work.post(priority, lane, shutdown, move || body(&mux))
    }

    /// [`Self::post_mux_work`] once `delay` has passed
    /// ([`cmux_threads::work::Work::post_delayed`]).
    pub(super) fn post_mux_work_after(
        &self,
        delay: Duration,
        priority: Priority,
        lane: Lane,
        shutdown: Shutdown,
        body: impl FnOnce(&Weak<Mux>) + Send + 'static,
    ) -> Result<(), Refused> {
        let mux = self.mux_work.mux.get().cloned().ok_or(Refused)?;
        self.work.post_delayed(delay, priority, lane, shutdown, move || body(&mux))
    }

    /// Queues `body` on `sequence`: it runs after every item posted to that
    /// sequence before it, never beside one, on `lane` (Chrome's
    /// `SequencedTaskRunner`, base/task/sequenced_task_runner.h). A refused
    /// or dropped drain drops the queued bodies.
    pub(crate) fn post_mux_work_sequenced(
        &self,
        sequence: &Arc<Sequence>,
        priority: Priority,
        lane: Lane,
        body: impl FnOnce(&Weak<Mux>) + Send + 'static,
    ) -> Result<(), Refused> {
        self.post_sequenced(sequence, priority, lane, Shutdown::SkipOnShutdown, Box::new(body))
    }

    /// Queues a connection's pump (`server::connection_scheduler`): it
    /// takes the connection's next request and runs it on `lane` at
    /// `priority` ([`ConnectionRoute`]), inside
    /// [`cmux_threads::work::will_block`] as [`Mux::post_request_wait`]'s
    /// items are (a request may wait on a terminal host or a child
    /// process). A connection has one pump at a time, so its requests keep
    /// their order with no sequence. A connection's reader disallows
    /// blocking (p02-threads 210, 211), so a request's SQLite, file and
    /// process work runs here, as Chrome's IO thread only routes a message
    /// and a task runner that may block runs it
    /// (content/browser/browser_thread_impl.cc, base/task/task_traits.h).
    /// Shutdown never waits for a request (one of them is the shutdown
    /// request). A refused or dropped item drops `body`, whose drop answers
    /// the requests it would have run.
    pub(crate) fn post_connection_request(
        &self,
        route: ConnectionRoute,
        body: impl FnOnce() + Send + 'static,
    ) -> Result<(), Refused> {
        debug_assert!(
            route.lane != Lane::User || route.priority == Priority::UserBlocking,
            "only the person's UserBlocking requests take the User lane"
        );
        self.work.post(route.priority, route.lane, Shutdown::ContinueOnShutdown, move || {
            cmux_threads::work::will_block(body);
        })
    }

    fn post_sequenced(
        &self,
        sequence: &Arc<Sequence>,
        priority: Priority,
        lane: Lane,
        shutdown: Shutdown,
        body: SequencedItem,
    ) -> Result<(), Refused> {
        if !sequence.push(body) {
            return Ok(());
        }
        let drain = SequenceDrain { sequence: Arc::clone(sequence), finished: false };
        // A refused post drops `drain`, which drops the queued bodies.
        self.post_mux_work(priority, lane, shutdown, move |mux| drain.run(mux))
    }
}

/// Where a connection's requests run. The person's connection takes the
/// User lane at `UserBlocking`, a may-block lane of its own, so a key's
/// request never queues behind automation's or background blocking work
/// (the repo rule: the person's input first, in a queue of its own, as
/// Chrome's `kUserInput` queue). Every other connection takes the System
/// lane at its request's cause (`EventCause::work_priority`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct ConnectionRoute {
    pub(crate) lane: Lane,
    pub(crate) priority: Priority,
}

impl ConnectionRoute {
    pub(crate) fn of(person: bool, cause: crate::event_cause::EventCause) -> Self {
        if person {
            return Self { lane: Lane::User, priority: Priority::UserBlocking };
        }
        Self { lane: Lane::System, priority: cause.work_priority() }
    }
}

/// What one try of a retried item asks for next ([`Mux::post_mux_retry`]).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Retry {
    Done,
    /// Try again after this backoff.
    After(Duration),
}

type RetryAttempt = Box<dyn FnMut(&Arc<Mux>) -> Retry + Send>;

impl Mux {
    /// Runs `attempt` on `lane` after `first_delay`, then again after each
    /// [`Retry::After`], until it says [`Retry::Done`], the mux is gone or
    /// shutdown begins. Each try is its own work item, reposted with a delay
    /// (Chrome retries by `PostDelayedTask`, net/base/backoff_entry.h), so no
    /// thread sleeps between tries. Shutdown drops a waiting try and never
    /// waits for a running one, and `attempt` (with what it owns) drops when
    /// the retry ends either way.
    pub(super) fn post_mux_retry(
        &self,
        first_delay: Duration,
        priority: Priority,
        lane: Lane,
        attempt: impl FnMut(&Arc<Mux>) -> Retry + Send + 'static,
    ) -> Result<(), Refused> {
        let mux = self.mux_work.mux.get().cloned().ok_or(Refused)?;
        let retry = RetryItem { mux, priority, lane, permits: None, attempt: Box::new(attempt) };
        retry.post(&self.work, first_delay)
    }

    /// [`Self::post_mux_retry`] whose tries each hold one of `permits`: at
    /// most its width run at once, beside the lane's own limits. A try that
    /// finds none free waits in `permits` with no thread and no timer, and is
    /// posted again when one frees.
    pub(super) fn post_mux_retry_limited(
        &self,
        first_delay: Duration,
        priority: Priority,
        lane: Lane,
        permits: &Arc<Permits>,
        attempt: impl FnMut(&Arc<Mux>) -> Retry + Send + 'static,
    ) -> Result<(), Refused> {
        let mux = self.mux_work.mux.get().cloned().ok_or(Refused)?;
        let permits = Some(Arc::downgrade(permits));
        let retry = RetryItem { mux, priority, lane, permits, attempt: Box::new(attempt) };
        retry.post(&self.work, first_delay)
    }
}

/// [`Mux::post_mux_retry`] from a thread that holds the mux only weakly
/// (the host-close pool). `Err` when the mux is gone or shutdown began.
pub(super) fn post_mux_retry_from(
    owner: &Weak<Mux>,
    first_delay: Duration,
    priority: Priority,
    lane: Lane,
    attempt: impl FnMut(&Arc<Mux>) -> Retry + Send + 'static,
) -> Result<(), Refused> {
    let permits = None;
    let retry =
        RetryItem { mux: owner.clone(), priority, lane, permits, attempt: Box::new(attempt) };
    let owner = owner.upgrade().ok_or(Refused)?;
    retry.post(&owner.work, first_delay)
}

impl Mux {
    /// The mux's weak reference, for a seam that posts work later from a
    /// thread that does not hold the mux (empty before the mux is bound).
    pub(super) fn work_owner(&self) -> Weak<Mux> {
        self.mux_work.mux.get().cloned().unwrap_or_default()
    }
}

/// One retried item between tries: it holds the mux and its permits
/// weakly, so a waiting or parked try never keeps a dropped mux alive (a
/// parked try sits in its permits).
struct RetryItem {
    mux: Weak<Mux>,
    priority: Priority,
    lane: Lane,
    permits: Option<Weak<Permits>>,
    attempt: RetryAttempt,
}

impl RetryItem {
    fn post(self, work: &Work, delay: Duration) -> Result<(), Refused> {
        let (priority, lane) = (self.priority, self.lane);
        work.post_delayed(delay, priority, lane, Shutdown::ContinueOnShutdown, move || self.run())
    }

    fn run(mut self) {
        let Some(owner) = self.mux.upgrade() else { return };
        if owner.shutting_down.load(Ordering::Acquire) {
            return;
        }
        let permits = match self.permits.as_ref().map(Weak::upgrade) {
            None => None,
            Some(Some(permits)) => Some(permits),
            // The mux that owned them is gone.
            Some(None) => return,
        };
        let _permit = match permits.as_ref().map(Permits::take) {
            None => None,
            Some(Ok(permit)) => Some(permit),
            Some(Err(parking)) => {
                // Posted again with no delay when a permit frees.
                parking.park(Box::new(move || {
                    if let Some(owner) = self.mux.upgrade() {
                        // Refused: shutdown began, and the retry ends with it.
                        let _ = self.post(&owner.work, Duration::ZERO);
                    }
                }));
                return;
            }
        };
        if let Retry::After(backoff) = (self.attempt)(&owner) {
            // Refused: shutdown began, and the retry ends with it.
            let _ = self.post(&owner.work, backoff);
        }
    }
}

type ParkedTry = Box<dyn FnOnce() + Send>;

/// A counted limit on how many items of one kind run at once, as Chrome's
/// `PostJob` bounds a job's workers by its max concurrency
/// (base/task/post_job.h) while the pool's own limits stay shared. An item
/// that finds every permit taken parks; a permit that frees posts the
/// longest-parked item again. Nothing waits on a thread for a permit.
pub(crate) struct Permits {
    width: usize,
    // Lock carve-out: a leaf lock over a count and a queue; no item runs and
    // no other lock is taken under it.
    state: Mutex<PermitState>,
}

#[derive(Default)]
struct PermitState {
    held: usize,
    parked: VecDeque<ParkedTry>,
}

impl Permits {
    pub(crate) fn new(width: usize) -> Arc<Permits> {
        Arc::new(Permits { width: width.max(1), state: Mutex::default() })
    }

    /// A permit, or the place to park until one frees. Parking holds the
    /// lock, so no permit frees between the refusal and the park.
    fn take(self: &Arc<Self>) -> Result<Permit, Parking<'_>> {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        if state.held < self.width {
            state.held += 1;
            return Ok(Permit { permits: Arc::clone(self) });
        }
        Err(Parking { state })
    }

    /// Permits held now.
    #[cfg(test)]
    pub(crate) fn held(&self) -> usize {
        self.state.lock().unwrap_or_else(PoisonError::into_inner).held
    }

    /// Items parked for a permit.
    #[cfg(test)]
    pub(crate) fn parked(&self) -> usize {
        self.state.lock().unwrap_or_else(PoisonError::into_inner).parked.len()
    }
}

/// Every permit is taken: park here.
struct Parking<'a> {
    state: MutexGuard<'a, PermitState>,
}

impl Parking<'_> {
    fn park(mut self, wake: ParkedTry) {
        self.state.parked.push_back(wake);
    }
}

/// One of a [`Permits`]' width, held for the whole of one try.
struct Permit {
    permits: Arc<Permits>,
}

impl Drop for Permit {
    fn drop(&mut self) {
        let next = {
            let mut state = self.permits.state.lock().unwrap_or_else(PoisonError::into_inner);
            state.held -= 1;
            state.parked.pop_front()
        };
        // Outside the lock: it posts a work item.
        if let Some(next) = next {
            next();
        }
    }
}

type SequencedItem = Box<dyn FnOnce(&Weak<Mux>) + Send>;

/// Items that run one at a time in the order posted
/// ([`Mux::post_mux_work_sequenced`]). The lock guards only the queue: it is
/// never held while an item runs.
#[derive(Default)]
pub(crate) struct Sequence {
    queue: Mutex<SequenceQueue>,
}

#[derive(Default)]
struct SequenceQueue {
    items: VecDeque<SequencedItem>,
    /// A drain item is queued or running.
    draining: bool,
}

impl Sequence {
    /// Queues `item`; whether the caller must post the drain.
    fn push(&self, item: SequencedItem) -> bool {
        let mut queue = self.queue.lock().unwrap_or_else(PoisonError::into_inner);
        queue.items.push_back(item);
        !std::mem::replace(&mut queue.draining, true)
    }

    /// The next item, or `None` after it ends the drain.
    fn next(&self) -> Option<SequencedItem> {
        let mut queue = self.queue.lock().unwrap_or_else(PoisonError::into_inner);
        let item = queue.items.pop_front();
        queue.draining = item.is_some();
        item
    }

    /// Ends a drain that stopped early; the caller drops the queued items
    /// outside the lock.
    fn abandon(&self) -> VecDeque<SequencedItem> {
        let mut queue = self.queue.lock().unwrap_or_else(PoisonError::into_inner);
        queue.draining = false;
        std::mem::take(&mut queue.items)
    }
}

/// The posted drain of a [`Sequence`]. Dropped before it finishes (the job
/// was dropped unrun or an item panicked), it ends the drain, so the next
/// post starts a new one.
struct SequenceDrain {
    sequence: Arc<Sequence>,
    finished: bool,
}

impl SequenceDrain {
    fn run(mut self, mux: &Weak<Mux>) {
        while let Some(item) = self.sequence.next() {
            item(mux);
        }
        self.finished = true;
    }
}

impl Drop for SequenceDrain {
    fn drop(&mut self) {
        if !self.finished {
            drop(self.sequence.abandon());
        }
    }
}

/// A reply sent exactly once: with the work's result, or with
/// `unanswered()` when the item carrying it is dropped first (shutdown, a
/// dropped job, a panic), so a request never waits for an answer that
/// cannot come.
pub(crate) struct Answer<T> {
    send: Option<Box<dyn FnOnce(T) + Send>>,
    unanswered: fn() -> T,
}

impl<T> Answer<T> {
    pub(crate) fn new(send: impl FnOnce(T) + Send + 'static, unanswered: fn() -> T) -> Self {
        Self { send: Some(Box::new(send)), unanswered }
    }

    pub(crate) fn send(mut self, value: T) {
        if let Some(send) = self.send.take() {
            send(value);
        }
    }
}

impl<T> Drop for Answer<T> {
    fn drop(&mut self) {
        if let Some(send) = self.send.take() {
            send((self.unanswered)());
        }
    }
}

/// Runs `f` on a new thread that disallows blocking, in the detector's panic
/// mode: the test stand-in for a request thread (`CMUX_DAEMON_BLOCKING=panic`).
/// `Err` is the panic of a blocking call `f` reached.
#[cfg(test)]
pub(crate) fn on_request_thread_in_panic_mode<R: Send + 'static>(
    f: impl FnOnce() -> R + Send + 'static,
) -> std::thread::Result<R> {
    cmux_threads::blocking::set_mode(cmux_threads::BlockingMode::Panic);
    let request = std::thread::Builder::new()
        .name("test-request".to_owned())
        .spawn(move || {
            cmux_threads::disallow_blocking();
            f()
        })
        .expect("spawn the request thread");
    cmux_threads::checked::sync::join(request)
}
