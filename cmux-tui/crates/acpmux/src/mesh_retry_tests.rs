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

/// A deadline nearer than the first backoff: the failure is returned at once, with no sleep
/// and no second try.
#[tokio::test(start_paused = true)]
async fn a_deadline_shorter_than_the_first_backoff_ends_after_one_try() {
    let tries = AtomicUsize::new(0);
    let started = Instant::now();
    let deadline = started + BACKOFF[0] / 2;
    let got: Result<(), _> = retry_within(false, deadline, || async {
        tries.fetch_add(1, Ordering::SeqCst);
        Err(status(503, Some("mesh.unavailable")))
    })
    .await;
    assert_eq!(got.unwrap_err().status, Some(503));
    assert_eq!(tries.load(Ordering::SeqCst), 1);
    assert_eq!(started.elapsed(), Duration::ZERO);
}

/// A send waits out a 429's retryAfterSeconds (up to a minute) and goes; a read does not.
#[tokio::test(start_paused = true)]
async fn a_send_waits_out_a_rate_window_and_then_goes() {
    let calls = AtomicUsize::new(0);
    let started = Instant::now();
    let got = retry_send(|| {
        let n = calls.fetch_add(1, Ordering::SeqCst);
        async move {
            if n == 0 {
                let mut e = status(429, Some("mesh.rate_limited"));
                e.retry_after = Some(Duration::from_secs(40));
                Err(e)
            } else {
                Ok(n)
            }
        }
    })
    .await;
    assert_eq!(got.unwrap(), 1);
    assert_eq!(calls.load(Ordering::SeqCst), 2);
    assert!(started.elapsed() >= Duration::from_secs(40), "it waited the hub's retryAfterSeconds");
    // A read keeps its short bound: the same answer is not waited on.
    let read = retry(false, || async {
        let mut e = status(429, Some("mesh.rate_limited"));
        e.retry_after = Some(Duration::from_secs(40));
        Err::<(), _>(e)
    })
    .await;
    assert!(read.is_err());
}

/// A retryAfter under the cap but past the deadline is not waited: the 429 is returned now.
/// One that ends before the deadline is waited and the call tried again.
#[tokio::test(start_paused = true)]
async fn a_retry_after_that_would_cross_the_deadline_is_not_waited() {
    let limited = |after: u64| {
        let mut e = status(429, Some("mesh.rate_limited"));
        e.retry_after = Some(Duration::from_secs(after));
        e
    };
    let tries = AtomicUsize::new(0);
    let started = Instant::now();
    let deadline = started + Duration::from_secs(2);
    let got: Result<(), _> = retry_within(false, deadline, || async {
        tries.fetch_add(1, Ordering::SeqCst);
        Err(limited(MAX_RETRY_AFTER.as_secs()))
    })
    .await;
    assert_eq!(got.unwrap_err().status, Some(429));
    assert_eq!(tries.load(Ordering::SeqCst), 1);
    assert_eq!(started.elapsed(), Duration::ZERO);

    let tries = AtomicUsize::new(0);
    let started = Instant::now();
    let deadline = started + Duration::from_secs(5);
    let got = retry_within(false, deadline, || async {
        if tries.fetch_add(1, Ordering::SeqCst) == 0 { Err(limited(2)) } else { Ok(()) }
    })
    .await;
    assert!(got.is_ok());
    assert_eq!(tries.load(Ordering::SeqCst), 2);
    assert_eq!(started.elapsed(), Duration::from_secs(2));
}

/// A try still waiting at the deadline ends there, as a hub that did not answer (retryable),
/// and none starts after it; the same after a failed first try and its backoff.
#[tokio::test(start_paused = true)]
async fn a_try_still_waiting_at_the_deadline_ends_there() {
    let tries = AtomicUsize::new(0);
    let started = Instant::now();
    let deadline = started + Duration::from_secs(5);
    let got: Result<(), _> = retry_within(true, deadline, || async {
        tries.fetch_add(1, Ordering::SeqCst);
        tokio::time::sleep(Duration::from_secs(60)).await;
        Ok(())
    })
    .await;
    let e = got.unwrap_err();
    assert!(!e.refused && e.status.is_none(), "{e:?}");
    assert_eq!(tries.load(Ordering::SeqCst), 1);
    assert_eq!(started.elapsed(), Duration::from_secs(5));

    let tries = AtomicUsize::new(0);
    let started = Instant::now();
    let got: Result<(), _> = retry_within(true, started + Duration::from_secs(5), || async {
        if tries.fetch_add(1, Ordering::SeqCst) == 0 {
            return Err(HubError::unavailable("the hub: error sending request"));
        }
        tokio::time::sleep(Duration::from_secs(60)).await;
        Ok(())
    })
    .await;
    assert!(!got.unwrap_err().refused);
    assert_eq!(tries.load(Ordering::SeqCst), 2);
    assert_eq!(started.elapsed(), Duration::from_secs(5));
}
