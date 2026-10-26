//! The mux's blocking work, off request threads (p02-threads section 3F).
//!
//! A request handler answers from memory; what would block (a file read, a
//! wait for another thread) goes to a lane of the mux's one
//! [`cmux_threads::work::Work`] (`Mux::work`, p02-threads 220) and reports
//! back through the mux when it finishes, as Chrome posts a `MayBlock` task
//! and replies on the calling sequence (base/task/thread_pool.h
//! `PostTaskAndReplyWithResult`). [`MuxWork`] holds the mux's weak
//! reference that those items get.

use std::collections::VecDeque;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex, OnceLock, PoisonError, Weak};
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
}

impl Mux {
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
    pub(super) fn post_mux_work_sequenced(
        &self,
        sequence: &Arc<Sequence>,
        priority: Priority,
        lane: Lane,
        body: impl FnOnce(&Weak<Mux>) + Send + 'static,
    ) -> Result<(), Refused> {
        if !sequence.push(Box::new(body)) {
            return Ok(());
        }
        let drain = SequenceDrain { sequence: Arc::clone(sequence), finished: false };
        // A refused post drops `drain`, which drops the queued bodies.
        self.post_mux_work(priority, lane, Shutdown::SkipOnShutdown, move |mux| drain.run(mux))
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
        post_retry(&self.work, mux, first_delay, priority, lane, Box::new(attempt))
    }
}

fn post_retry(
    work: &Work,
    mux: Weak<Mux>,
    delay: Duration,
    priority: Priority,
    lane: Lane,
    mut attempt: RetryAttempt,
) -> Result<(), Refused> {
    work.post_delayed(delay, priority, lane, Shutdown::ContinueOnShutdown, move || {
        let Some(owner) = mux.upgrade() else { return };
        if owner.shutting_down.load(Ordering::Acquire) {
            return;
        }
        if let Retry::After(backoff) = attempt(&owner) {
            // Refused: shutdown began, and the retry ends with it.
            let _ = post_retry(&owner.work, mux, backoff, priority, lane, attempt);
        }
    })
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
