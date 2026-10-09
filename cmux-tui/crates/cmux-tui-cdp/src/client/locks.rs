//! Poison handling for the client's locks: each lock says whether a
//! poisoned guard can still be trusted (recover), must be rebuilt, or must
//! never be read (close the connection).

use std::collections::HashMap;
use std::sync::{MutexGuard, PoisonError};

use std::sync::atomic::Ordering;

use super::{EventQueue, EventQueueState, FrameSession, Inner, PendingCall};

impl EventQueue {
    /// `retained_bytes` is the sum of the queued events' sizes. A panic while
    /// the lock was held (poison) can leave that sum stale, so it is rebuilt
    /// from the events (each push and pop keeps an event whole) and the
    /// poison is cleared.
    pub(super) fn lock_state(&self) -> MutexGuard<'_, EventQueueState> {
        self.state.lock().unwrap_or_else(|poisoned| {
            let mut state = poisoned.into_inner();
            state.retained_bytes = state.events.iter().map(|queued| queued.retained_bytes).sum();
            self.state.clear_poison();
            state
        })
    }
}

/// `pending` is one map and every critical section is a single insert,
/// remove or drain, so a poisoned lock (a panic elsewhere while it was held)
/// still guards a consistent map: recover it.
pub(super) fn pending_calls(inner: &Inner) -> MutexGuard<'_, HashMap<u64, PendingCall>> {
    inner.pending.lock().unwrap_or_else(PoisonError::into_inner)
}

const FRAME_STATE_POISONED: &str = "CDP frame state lock poisoned";

/// The frame sessions hold multi-field navigation and screencast state that
/// a panic mid-update can leave inconsistent. A poisoned lock is never read:
/// the connection closes (pending calls fail, the event stream ends with
/// `Closed`) and the caller gets `None`.
pub(super) fn frame_sessions(
    inner: &Inner,
) -> Option<MutexGuard<'_, HashMap<String, FrameSession>>> {
    match inner.frame_epochs.lock() {
        Ok(sessions) => Some(sessions),
        Err(poisoned) => {
            drop(poisoned);
            close_inner(inner, FRAME_STATE_POISONED);
            None
        }
    }
}

pub(super) fn frame_state_error() -> anyhow::Error {
    anyhow::anyhow!("{FRAME_STATE_POISONED}; the CDP connection is closed")
}

pub(super) fn close_inner(inner: &Inner, why: &str) {
    if inner.closed.swap(true, Ordering::AcqRel) {
        return;
    }
    for (_, pending) in pending_calls(inner).drain() {
        let _ = pending.response.send(Err(why.to_string()));
    }
    inner.events.close(why);
}
