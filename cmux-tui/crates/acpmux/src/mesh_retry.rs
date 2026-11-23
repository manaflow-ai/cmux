//! A hub call a person waits on (`acpmux last HOST/NAME`, `acpmux info HOST/NAME`, `acpmux
//! inbox`), tried again when the hub's failure is one that passes: no connection (`the hub: error
//! sending request`), a 408, 429 or 5xx (`503 mesh.unavailable`), or a 404 `mesh.not_found` on a
//! call that is safe to repeat. Before this a single blip failed the command, and the person ran it
//! again by hand until it went through (gcp-codex-swarm-07, 2026-11-19..20: 4 connection errors,
//! 7 `503 mesh.unavailable`, 6 `404 mesh.not_found` in two days, each passing within seconds).
//!
//! Bounded: at most [`ATTEMPTS`] tries, [`BACKOFF`] apart (or the hub's `retryAfterSeconds`, up
//! to [`MAX_RETRY_AFTER`]), so a command waits at most a few seconds more than before before it
//! says what failed. A refusal that does not pass (401, 403, 400, an unknown recipient) is never
//! tried again. The relay's own loops (inbox, heartbeat) keep their own backoff and do not come
//! through here.

use crate::mesh::HubError;
use std::future::Future;
use std::time::Duration;

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
pub async fn retry<T, F, Fut>(not_found_passes: bool, mut call: F) -> Result<T, HubError>
where
    F: FnMut() -> Fut,
    Fut: Future<Output = Result<T, HubError>>,
{
    let mut attempt = 0;
    loop {
        let e = match call().await {
            Ok(value) => return Ok(value),
            Err(e) => e,
        };
        let Some(wait) = BACKOFF.get(attempt).copied() else { return Err(e) };
        if !transient(&e, not_found_passes) {
            return Err(e);
        }
        let wait = match e.retry_after {
            Some(after) if after > MAX_RETRY_AFTER => return Err(e),
            Some(after) => after.max(wait),
            None => wait,
        };
        tracing::debug!(attempt, error = %e, "mesh hub call failed; trying again");
        tokio::time::sleep(wait).await;
        attempt += 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn status(status: u16, code: Option<&str>) -> HubError {
        let mut e = HubError::refused(format!("the hub answered {status}"));
        e.refused = !(status == 408 || status == 429 || status >= 500);
        e.status = Some(status);
        e.code = code.map(str::to_owned);
        e
    }

    /// The failures seen in the field pass; a refusal of the request or the credential does not.
    #[test]
    fn only_failures_that_pass_are_tried_again() {
        assert!(transient(&HubError::unavailable("the hub: error sending request"), false));
        assert!(transient(&status(503, Some("mesh.unavailable")), false));
        assert!(transient(&status(502, None), false));
        assert!(transient(&status(429, Some("mesh.rate_limited")), false));
        assert!(transient(&status(404, Some("mesh.not_found")), true));
        assert!(!transient(&status(404, Some("mesh.not_found")), false));
        assert!(!transient(&status(404, Some("mesh.unknown_recipient")), true));
        assert!(!transient(&status(401, None), true));
        assert!(!transient(&status(403, Some("mesh.forbidden")), true));
        assert!(!transient(&status(400, Some("mesh.bad_request")), true));
        assert!(!transient(&HubError::refused("no token command"), true));
    }

    /// Two blips then an answer: the caller sees the answer, after the two backoffs.
    #[tokio::test(start_paused = true)]
    async fn a_blip_then_an_answer_is_the_answer() {
        let tries = AtomicUsize::new(0);
        let started = tokio::time::Instant::now();
        let got = retry(false, || async {
            match tries.fetch_add(1, Ordering::SeqCst) {
                0 => Err(HubError::unavailable("the hub: error sending request")),
                1 => Err(status(503, Some("mesh.unavailable"))),
                _ => Ok(7),
            }
        })
        .await;
        assert_eq!(got.unwrap(), 7);
        assert_eq!(tries.load(Ordering::SeqCst), 3);
        assert_eq!(started.elapsed(), BACKOFF[0] + BACKOFF[1]);
    }

    /// A hub that stays down is tried [`ATTEMPTS`] times and its last failure returned.
    #[tokio::test(start_paused = true)]
    async fn a_hub_that_stays_down_is_tried_a_bounded_number_of_times() {
        let tries = AtomicUsize::new(0);
        let got: Result<(), _> = retry(true, || async {
            tries.fetch_add(1, Ordering::SeqCst);
            Err(status(503, Some("mesh.unavailable")))
        })
        .await;
        assert_eq!(got.unwrap_err().status, Some(503));
        assert_eq!(tries.load(Ordering::SeqCst), ATTEMPTS);
    }

    /// A refusal is returned at once; a retryAfter past the cap fails now; one under it is waited.
    #[tokio::test(start_paused = true)]
    async fn a_refusal_or_a_long_retry_after_is_not_waited_on() {
        let tries = AtomicUsize::new(0);
        let got: Result<(), _> = retry(true, || async {
            tries.fetch_add(1, Ordering::SeqCst);
            Err(status(403, Some("mesh.forbidden")))
        })
        .await;
        assert_eq!(got.unwrap_err().status, Some(403));
        assert_eq!(tries.load(Ordering::SeqCst), 1);

        let long = || {
            let mut e = status(429, Some("mesh.rate_limited"));
            e.retry_after = Some(Duration::from_secs(60));
            e
        };
        let tries = AtomicUsize::new(0);
        let got: Result<(), _> = retry(false, || async {
            tries.fetch_add(1, Ordering::SeqCst);
            Err(long())
        })
        .await;
        assert_eq!(got.unwrap_err().retry_after, Some(Duration::from_secs(60)));
        assert_eq!(tries.load(Ordering::SeqCst), 1);

        let tries = AtomicUsize::new(0);
        let started = tokio::time::Instant::now();
        let got = retry(false, || async {
            if tries.fetch_add(1, Ordering::SeqCst) == 0 {
                let mut e = status(429, Some("mesh.rate_limited"));
                e.retry_after = Some(Duration::from_secs(2));
                Err(e)
            } else {
                Ok(())
            }
        })
        .await;
        assert!(got.is_ok());
        assert_eq!(started.elapsed(), Duration::from_secs(2));
    }
}
