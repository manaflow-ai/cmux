//! A chat's prompt admission: one prompt at a time takes its place (steer, inbox, queue or turn),
//! so two that come together are answered in the order they came (`turns.rs`, `queue.rs`
//! `queue_slot`).
//!
//! Admission is a lease, never a lock held across an unbounded await: it lapses [`LEASE`] after it
//! was taken. A prompt held up past it (an agent slot another task holds, a folder revived for a
//! cold chat, a config write) no longer keeps every later delivery of its chat unanswered; and a
//! prompt that would start its turn now but finds the turn lock held waits no longer than
//! [`TURN_LOCK_WAIT`] unanswered: it is queued, durably, and accepted as queued (`queue.rs`).
//! Leo, 2026-11-25 (claude-sr2-coord-old, 66 restored notices, every delivery unanswered): "A
//! delivery always gets an answer within seconds."

use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::OwnedMutexGuard;

/// How long one prompt may hold its chat's admission.
pub(crate) const LEASE: Duration = Duration::from_secs(3);

/// How long a prompt that found its chat free waits for the turn lock before it is queued and
/// accepted as queued instead.
pub(crate) const TURN_LOCK_WAIT: Duration = Duration::from_secs(2);

/// A chat's admission, held by one prompt until it is released or its lease lapses.
pub struct Admission(Arc<Mutex<Option<OwnedMutexGuard<()>>>>, tokio::task::AbortHandle);

impl Admission {
    /// Waits for the chat's admission (`Session::prompt_admission`) and holds it for at most
    /// [`LEASE`].
    pub(crate) async fn take(lock: &Arc<tokio::sync::Mutex<()>>) -> Self {
        let guard = lock.clone().lock_owned().await;
        let held = Arc::new(Mutex::new(Some(guard)));
        let lease = Arc::downgrade(&held);
        let timer = tokio::spawn(async move {
            tokio::time::sleep(LEASE).await;
            let lapsed = lease
                .upgrade()
                .and_then(|held| held.lock().unwrap_or_else(|e| e.into_inner()).take());
            if lapsed.is_some() {
                tracing::warn!("a prompt held its chat's admission past {LEASE:?}: it lapsed");
            }
        });
        Self(held, timer.abort_handle())
    }

    /// Lets the next prompt of the chat in. Again, or after the lease lapsed: nothing.
    pub(crate) fn release(&self) {
        drop(self.0.lock().unwrap_or_else(|e| e.into_inner()).take());
    }

    /// Whether this prompt still holds the admission (tests).
    #[cfg(test)]
    pub(crate) fn held(&self) -> bool {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).is_some()
    }
}

impl Drop for Admission {
    fn drop(&mut self) {
        self.release();
        self.1.abort();
    }
}
