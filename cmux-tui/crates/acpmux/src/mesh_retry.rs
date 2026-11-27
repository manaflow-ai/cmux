//! A hub call a person waits on (`acpmux last HOST/NAME`, `acpmux info HOST/NAME`, `acpmux
//! inbox`), tried again when the hub's failure is one that passes: no connection (`the hub: error
//! sending request`), a 408, 429 or 5xx (`503 mesh.unavailable`), or a 404 `mesh.not_found` on a
//! call that is safe to repeat. Before this a single blip failed the command, and the person ran it
//! again by hand until it went through (gcp-codex-swarm-07, 2026-11-19..20: 4 connection errors,
//! 7 `503 mesh.unavailable`, 6 `404 mesh.not_found` in two days, each passing within seconds).
//!
//! Bounded: at most [`ATTEMPTS`] tries, [`BACKOFF`] apart (or the hub's `retryAfterSeconds`, up
//! to [`MAX_RETRY_AFTER`]), so a command waits at most a few seconds more than before before it
//! says what failed. A caller with a deadline of its own (a read's `READ_WAIT`) passes it to
//! [`retry_within`], so no try runs past it. A refusal that does not pass (401, 403, 400, an unknown recipient) is never
//! tried again. The relay's own loops (inbox, heartbeat) keep their own backoff and do not come
//! through here.

use crate::mesh::HubError;
use std::future::Future;
use std::time::Duration;
use tokio::time::Instant;

/// The most tries of one call.
pub const ATTEMPTS: usize = 3;

/// The wait before the second and the third try.
pub const BACKOFF: [Duration; ATTEMPTS - 1] =
    [Duration::from_millis(500), Duration::from_millis(1500)];

/// The longest `retryAfterSeconds` honored; a longer one fails now and says so.
pub const MAX_RETRY_AFTER: Duration = Duration::from_secs(3);

/// Whether the hub's answer `e` is one that passes on its own. `not_found_passes`: the call is a
/// read or carries an idempotency key, so a 404 `mesh.not_found` (the hub briefly not listing a
/// daemon between its heartbeats, or a receipt it already let go) is worth one more try.
pub fn transient(e: &HubError, not_found_passes: bool) -> bool {
    if !e.refused {
        return true;
    }
    match e.status {
        Some(408 | 429) => true,
        Some(s) if s >= 500 => true,
        Some(404) => not_found_passes && e.code.as_deref() == Some("mesh.not_found"),
        _ => false,
    }
}

/// `call` until it succeeds, fails in a way that does not pass, or has been tried [`ATTEMPTS`]
/// times; the last failure is returned as it came.
pub async fn retry<T, F, Fut>(not_found_passes: bool, call: F) -> Result<T, HubError>
where
    F: FnMut() -> Fut,
    Fut: Future<Output = Result<T, HubError>>,
{
    tries(not_found_passes, None, call).await
}

/// [`retry`] within `deadline`: a try still waiting at the deadline ends there, as a hub that
/// did not answer, and no try starts at or after it (a read's whole wait, `READ_WAIT`, bounds
/// every try of it). Whether the deadline passed is the caller's to check.
pub async fn retry_within<T, F, Fut>(
    not_found_passes: bool,
    deadline: Instant,
    call: F,
) -> Result<T, HubError>
where
    F: FnMut() -> Fut,
    Fut: Future<Output = Result<T, HubError>>,
{
    tries(not_found_passes, Some(deadline), call).await
}

/// The longest `retryAfterSeconds` a send waits out ([`retry_send`]): the hub's windows are one
/// minute long, so its answer is never longer than this.
pub const SEND_MAX_RETRY_AFTER: Duration = Duration::from_secs(60);

/// A send to the hub (it carries an idempotency key, so posting it again is the same message),
/// tried again as [`retry`] does, but a 429's `retryAfterSeconds` is waited out up to
/// [`SEND_MAX_RETRY_AFTER`] instead of failing the send: before this, every send behind a full
/// rate window failed at once with `the hub answered 429 mesh.rate_limited`, though the window
/// reopened within the minute (2026-11-23, every relayed send to a busy host for two hours).
pub async fn retry_send<T, F, Fut>(call: F) -> Result<T, HubError>
where
    F: FnMut() -> Fut,
    Fut: Future<Output = Result<T, HubError>>,
{
    tries_with(true, None, SEND_MAX_RETRY_AFTER, call).await
}

async fn tries<T, F, Fut>(
    not_found_passes: bool,
    deadline: Option<Instant>,
    call: F,
) -> Result<T, HubError>
where
    F: FnMut() -> Fut,
    Fut: Future<Output = Result<T, HubError>>,
{
    tries_with(not_found_passes, deadline, MAX_RETRY_AFTER, call).await
}

async fn tries_with<T, F, Fut>(
    not_found_passes: bool,
    deadline: Option<Instant>,
    max_retry_after: Duration,
    mut call: F,
) -> Result<T, HubError>
where
    F: FnMut() -> Fut,
    Fut: Future<Output = Result<T, HubError>>,
{
    let mut attempt = 0;
    loop {
        let answered = match deadline {
            Some(deadline) => tokio::time::timeout_at(deadline, call()).await,
            None => Ok(call().await),
        };
        let e = match answered {
            Ok(Ok(value)) => return Ok(value),
            Ok(Err(e)) => e,
            Err(_) => return Err(HubError::unavailable("the mesh hub did not answer in time")),
        };
        let Some(wait) = BACKOFF.get(attempt).copied() else { return Err(e) };
        if !transient(&e, not_found_passes) {
            return Err(e);
        }
        let wait = match e.retry_after {
            Some(after) if after > max_retry_after => return Err(e),
            Some(after) => after.max(wait),
            None => wait,
        };
        if deadline.is_some_and(|deadline| Instant::now() + wait >= deadline) {
            return Err(e);
        }
        tracing::debug!(attempt, error = %e, "mesh hub call failed; trying again");
        tokio::time::sleep(wait).await;
        attempt += 1;
    }
}

#[cfg(test)]
#[path = "mesh_retry_tests.rs"]
mod tests;
