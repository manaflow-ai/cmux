//! A client's `$/cancel_request` (JSON-RPC / LSP / ACP `CancelRequestNotification`), as the work
//! it cancelled sees it.
//!
//! The connection that took the request (`server/in_flight.rs`) answers it with
//! [`cancelled_error`] at once, frees its slot, and drops the future that serves it inside
//! [`until_cancelled`]'s scope. What that future was waiting on reads [`requested`] while it is
//! dropped and tells its own backend: an agent's request (`agent.rs`) and a peer's forwarded one
//! (`peer.rs`) send `$/cancel_request` on, forget their pending entry, and keep the id, so the
//! answer that still comes is dropped on purpose and logged under [`LOG_TARGET`] instead of
//! being lost or handed to a waiter that is gone.
//!
//! A future dropped for any other reason (a turn handed to the next daemon, a timeout) sees no
//! request here and keeps what it did before.

use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::future::Future;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Instant;
use tokio::sync::oneshot;

/// JSON-RPC's RequestCancelled (LSP): the answer to a request its client cancelled.
pub const REQUEST_CANCELLED: i64 = -32800;

/// The `initialize` feature of a daemon that honors `$/cancel_request`: the request is answered
/// with [`REQUEST_CANCELLED`] and the cancel goes on to the agent or peer. A peer link sends the
/// cancel on only to a peer that lists it (an older one ignores it anyway). The old
/// `cancelRequest` feature only said the notification is accepted.
pub const FEATURE: &str = "cancelRequestV2";

/// The tracing target of the cancel path's lines (the dropped late answers).
pub const LOG_TARGET: &str = "acpmux::cancel";

/// How long a cancelled id is kept for its late answer: the peer's request deadline
/// (`peer_link::LinkTimings::request`, 600 s), past which the peer gave up on the work itself. An
/// answer later than that (an agent that took longer) is still logged, as an unknown id.
pub const KEEP_FOR: std::time::Duration = std::time::Duration::from_secs(600);

/// How many cancelled ids an agent or peer keeps at most, whatever their age: a hard memory
/// bound (one id and method each) for a client that cancels faster than answers come.
pub const REMEMBERED: usize = 1024;

tokio::task_local! {
    static CANCELLED: Arc<AtomicBool>;
}

/// The error a cancelled request is answered with.
pub fn cancelled_error() -> RpcError {
    RpcError::new(REQUEST_CANCELLED, "request cancelled")
        .with_data(json!({"reason": "request.cancelled"}))
}

/// The request id a `$/cancel_request` names: ACP's `requestId`, or LSP's `id`.
pub fn named_id(params: &Value) -> Option<&Value> {
    params.get("requestId").or_else(|| params.get("id")).filter(|v| v.is_string() || v.is_number())
}

/// Whether the request this task serves was cancelled by its client. True only while the
/// future [`until_cancelled`] ran is dropped after a cancel.
pub fn requested() -> bool {
    CANCELLED.try_with(|c| c.load(Ordering::SeqCst)).unwrap_or(false)
}

/// `fut`, unless `cancel` fires first: then None, and `fut` is dropped with [`requested`] true.
/// A `cancel` whose sender is dropped never fires.
pub async fn until_cancelled<F: Future>(
    cancel: oneshot::Receiver<()>,
    fut: F,
) -> Option<F::Output> {
    until_either(cancel, None, fut).await
}

/// [`until_cancelled`], cancelled by whichever of `cancel` and `also` fires first: a request's
/// own cancel, or one of its copy on another connection (`server/dual_requests.rs`).
pub async fn until_either<F: Future>(
    cancel: oneshot::Receiver<()>,
    also: Option<oneshot::Receiver<()>>,
    fut: F,
) -> Option<F::Output> {
    // A receiver whose sender is dropped never fires.
    let fired = |rx: Option<oneshot::Receiver<()>>| async move {
        let fired = match rx {
            Some(rx) => rx.await.is_ok(),
            None => false,
        };
        if !fired {
            std::future::pending::<()>().await;
        }
    };
    let flag = Arc::new(AtomicBool::new(false));
    let scoped = CANCELLED.scope(flag.clone(), fut);
    tokio::pin!(scoped);
    let out = tokio::select! {
        biased;
        out = &mut scoped => Some(out),
        () = fired(Some(cancel)) => None,
        () = fired(also) => None,
    };
    if out.is_none() {
        flag.store(true, Ordering::SeqCst);
    }
    // `scoped` is dropped as this returns, inside its scope (tokio's `TaskLocalFuture` drops its
    // future with the value set), so what it waited on reads `requested`.
    out
}

/// Ids of cancelled requests, oldest first, with the method each was and when: what a late
/// answer is recognized by. Each is kept [`KEEP_FOR`], and at most [`REMEMBERED`] are; every id
/// that goes unanswered is logged by name as it goes, and once any went, an answer for an id
/// not known here is logged as possibly one of them (review F2 of #41285), never dropped
/// silently.
#[derive(Default)]
pub struct Cancelled {
    ids: std::collections::VecDeque<(String, String, Instant)>,
    /// Late answers dropped so far.
    pub dropped: u64,
    /// Ids forgotten unanswered so far (by age or by the bound).
    pub evicted: u64,
}

impl Cancelled {
    pub fn remember(&mut self, key: String, method: String) {
        self.remember_at(key, method, Instant::now());
    }

    /// [`Self::remember`] at `now` (a test's clock).
    pub fn remember_at(&mut self, key: String, method: String, now: Instant) {
        self.expire(now);
        while self.ids.len() >= REMEMBERED {
            self.evict("the bound of remembered cancels");
        }
        self.ids.push_back((key, method, now));
    }

    /// An answer for `key` came with nobody waiting: true when it was a cancelled request's,
    /// which is then dropped and logged (once).
    pub fn take_late(&mut self, key: &str, from: &str) -> bool {
        self.take_late_at(key, from, Instant::now())
    }

    /// [`Self::take_late`] at `now` (a test's clock).
    pub fn take_late_at(&mut self, key: &str, from: &str, now: Instant) -> bool {
        self.expire(now);
        let Some(at) = self.ids.iter().position(|(k, _, _)| k == key) else {
            if self.evicted > 0 {
                tracing::debug!(
                    target: LOG_TARGET,
                    id = %key,
                    from,
                    evicted = self.evicted,
                    "an answer came for an unknown id, possibly evicted cancel"
                );
            }
            return false;
        };
        let method = self.ids.remove(at).map(|(_, method, _)| method).unwrap_or_default();
        self.dropped += 1;
        tracing::debug!(
            target: LOG_TARGET,
            id = %key,
            method = %method,
            from,
            "dropped the late answer to a cancelled request"
        );
        true
    }

    /// Forgets the ids older than [`KEEP_FOR`] at `now`.
    fn expire(&mut self, now: Instant) {
        while self
            .ids
            .front()
            .is_some_and(|(_, _, at)| now.saturating_duration_since(*at) > KEEP_FOR)
        {
            self.evict("its age");
        }
    }

    fn evict(&mut self, why: &str) {
        let Some((key, method, _)) = self.ids.pop_front() else { return };
        self.evicted += 1;
        tracing::debug!(
            target: LOG_TARGET,
            id = %key,
            method = %method,
            why,
            "evicted a cancelled request's id unanswered: a later answer logs as an unknown id"
        );
    }

    pub fn len(&self) -> usize {
        self.ids.len()
    }

    pub fn is_empty(&self) -> bool {
        self.ids.is_empty()
    }
}

#[cfg(test)]
mod tests;
