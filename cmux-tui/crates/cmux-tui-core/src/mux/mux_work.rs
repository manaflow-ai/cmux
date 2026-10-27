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
use std::sync::{Arc, OnceLock, PoisonError, Weak};

use cmux_threads::work::{Lane, Priority, Refused, Shutdown};

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
        if !sequence.push(Box::new(body)) {
            return Ok(());
        }
        let drain = SequenceDrain { sequence: Arc::clone(sequence), finished: false };
        // A refused post drops `drain`, which drops the queued bodies.
        self.post_mux_work(priority, lane, Shutdown::SkipOnShutdown, move |mux| drain.run(mux))
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
