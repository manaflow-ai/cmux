//! Event subscriptions as work items (p05-ipc-146).
//!
//! A `subscribe` stream, a `session.events` stream and a
//! `conversation.events` stream each held a thread blocked on its source
//! (`mux-events-out`, `mux-resource-session-events`,
//! `mux-resource-conversation-events`). Each is now a [`SubscriptionPump`]:
//! a sequence on the mux's work lanes (`Mux::post_mux_work_sequenced`) whose
//! drain task takes what its source holds and returns when the source is
//! empty, when its outbound stream holds its backpressure cap, or when its
//! turn's budget is spent. Chrome runs an observer's notifications as tasks
//! on the observer's sequence (base/observer_list_threadsafe.h) and prefers
//! sequences to threads (docs/threading_and_tasks.md); the attach streams do
//! the same on the sequenced pool (attach_pump.rs, p05-ipc-079).
//!
//! The drains read SQLite (a `session.events` page, a tree delta's registry
//! event), which the pool's request-class workers forbid, so they run on the
//! Files lane at `UserVisible`: the lane's workers allow file I/O and run at
//! the request class's QoS, as the threads did.
//!
//! Wakes, never polls: the source's ready hook, the journal's commit watch,
//! the writer's space hook for the stream, and the stop interrupt, which the
//! close of the connection or of the stream fires. A turn that finds nothing
//! returns; nothing waits between events (0 idle wakeups).
//!
//! Lifetime: the stop interrupt's waker holds the pump until it fires, as a
//! thread holds what it runs; the sources hold it weakly. When the drain is
//! done the pump fires the interrupt, which drops that waker.

use cmux_threads::sync::Mutex;
use cmux_threads::work::{Lane, Priority, Refused};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Weak};

use crate::Mux;
use crate::mux::mux_work::Sequence;
use crate::panic_free::RecoverPoison;
use crate::server::attach_lifecycle::attach_pump::Turn;
use crate::stream_interrupt::StreamInterrupt;

/// Items one drain task sends before it yields its lane slot.
pub(super) const TURN_BUDGET: usize = 64;

/// A subscription's work, owned by its pump's sequence: one task of the
/// sequence runs it at a time.
pub(super) trait SubscriptionDrain: Send + 'static {
    /// Handles what is ready, without waiting.
    fn turn(&mut self) -> Turn;
}

struct PumpInner {
    mux: Weak<Mux>,
    sequence: Arc<Sequence>,
    /// A turn is posted and has not started yet.
    scheduled: AtomicBool,
    stop: Arc<StreamInterrupt>,
    /// Only the sequence's running task takes it, so it is never contended
    /// (Chrome's `SequenceBound`).
    drain: Mutex<Option<Box<dyn SubscriptionDrain>>>,
}

/// One subscription's drain on the mux's work lanes.
pub(super) struct SubscriptionPump {
    inner: Arc<PumpInner>,
}

impl SubscriptionPump {
    pub(super) fn new(mux: &Arc<Mux>) -> Self {
        let inner = Arc::new(PumpInner {
            mux: Arc::downgrade(mux),
            sequence: Arc::default(),
            // Nothing runs before `start`.
            scheduled: AtomicBool::new(true),
            stop: StreamInterrupt::new(),
            drain: Mutex::new(None),
        });
        let keep = inner.clone();
        inner.stop.on_fire(move || wake(&keep));
        Self { inner }
    }

    /// The hook a source runs when it has something for the drain. It holds
    /// the pump weakly: a source never keeps an ended subscription alive.
    pub(super) fn hook(&self) -> impl Fn() + Send + Sync + 'static {
        let pump = Arc::downgrade(&self.inner);
        move || {
            if let Some(inner) = pump.upgrade() {
                wake(&inner);
            }
        }
    }

    /// Fired by any close the subscription ends on; it wakes the drain.
    pub(super) fn stop(&self) -> &Arc<StreamInterrupt> {
        &self.inner.stop
    }

    /// Installs `drain` and runs its first turn: what queued since the
    /// sources were bound. Refused only once shutdown began; the drain is
    /// then dropped unrun.
    pub(super) fn start(self, drain: Box<dyn SubscriptionDrain>) -> Result<(), Refused> {
        *self.inner.drain.lock().recover_poison() = Some(drain);
        // `scheduled` stays set from `new`: a wake before this post is
        // covered by it, and the turn clears it when it starts.
        let posted = post(&self.inner);
        if posted.is_err() {
            let drain = self.inner.drain.lock().recover_poison().take();
            drop(drain);
            self.inner.stop.fire();
        }
        posted
    }
}

fn wake(inner: &Arc<PumpInner>) {
    if inner.scheduled.swap(true, Ordering::SeqCst) {
        return;
    }
    if post(inner).is_err() {
        inner.scheduled.store(false, Ordering::SeqCst);
    }
}

fn post(inner: &Arc<PumpInner>) -> Result<(), Refused> {
    let mux = inner.mux.upgrade().ok_or(Refused)?;
    let task = inner.clone();
    mux.post_mux_work_sequenced(&inner.sequence, Priority::UserVisible, Lane::Files, move |_| {
        run(&task);
    })
}

fn run(inner: &Arc<PumpInner>) {
    // Cleared before the sources are read: a wake from here on posts the
    // next turn, so none is lost.
    inner.scheduled.store(false, Ordering::SeqCst);
    let mut slot = inner.drain.lock().recover_poison();
    let Some(drain) = slot.as_mut() else { return };
    match drain.turn() {
        Turn::Idle => {}
        Turn::Yield => {
            drop(slot);
            wake(inner);
        }
        Turn::Done => {
            let drain = slot.take();
            drop(slot);
            drop(drain);
            inner.stop.fire();
        }
    }
}

#[cfg(test)]
#[path = "subscription_pump_tests.rs"]
mod tests;
