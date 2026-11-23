use super::*;

#[test]
fn doubles_to_the_cap_and_resets() {
    let mut backoff =
        Backoff::new(Duration::from_millis(10), Duration::from_millis(50)).with_jitter(0.0);
    let delays: Vec<_> = (0..5).map(|_| backoff.next_delay().as_millis()).collect();
    assert_eq!(delays, vec![10, 20, 40, 50, 50]);
    backoff.reset();
    assert_eq!(backoff.next_delay(), Duration::from_millis(10));
}

#[test]
fn jitter_stays_within_its_fraction_and_the_cap() {
    let mut backoff = Backoff::new(Duration::from_millis(100), Duration::from_secs(1));
    for _ in 0..100 {
        backoff.reset();
        let delay = backoff.next_delay();
        assert!(delay >= Duration::from_millis(80) && delay <= Duration::from_millis(120));
    }
    for _ in 0..20 {
        assert!(backoff.next_delay() <= Duration::from_secs(1));
    }
}

#[test]
fn a_retry_waits_the_servers_retry_after_plus_full_jitter_doubling_to_the_cap() {
    let now = Instant::now();
    let mut retries = RetryBudget::until(
        Duration::from_millis(100),
        Duration::from_millis(300),
        now + Duration::from_secs(60),
    );
    let after = Some(Duration::from_millis(50));
    let tops: Vec<_> =
        (0..4).map(|_| retries.next_wait_drawn(after, 1.0, now).unwrap().as_millis()).collect();
    assert_eq!(tops, vec![150, 250, 350, 350]);
    let mut retries = RetryBudget::until(
        Duration::from_millis(100),
        Duration::from_secs(1),
        now + Duration::from_secs(60),
    );
    assert_eq!(retries.next_wait_drawn(after, 0.0, now), after);
    assert_eq!(retries.next_wait_drawn(None, 0.5, now), Some(Duration::from_millis(100)));
}

#[test]
fn a_wait_that_ends_past_the_budget_is_not_taken() {
    let now = Instant::now();
    let mut retries = RetryBudget::until(
        Duration::from_millis(100),
        Duration::from_secs(1),
        now + Duration::from_millis(120),
    );
    assert_eq!(retries.next_wait_drawn(None, 1.0, now), Some(Duration::from_millis(100)));
    assert_eq!(retries.next_wait_drawn(None, 0.6, now), None);
    let mut retries = RetryBudget::until(
        Duration::from_millis(10),
        Duration::from_secs(1),
        now + Duration::from_millis(120),
    );
    assert_eq!(retries.next_wait_drawn(Some(Duration::from_millis(500)), 0.0, now), None);
}

#[test]
fn with_no_budget_every_failure_waits_and_a_success_starts_over() {
    let now = Instant::now();
    let mut retries = RetryBudget::new(Duration::from_millis(100), Duration::from_millis(300));
    let tops: Vec<_> =
        (0..4).map(|_| retries.next_wait_drawn(None, 1.0, now).unwrap().as_millis()).collect();
    assert_eq!(tops, vec![100, 200, 300, 300]);
    retries.reset();
    assert_eq!(retries.next_wait_drawn(None, 1.0, now), Some(Duration::from_millis(100)));
}

#[test]
fn clients_refused_together_spread_over_the_whole_jitter_window() {
    let now = Instant::now();
    let after = Duration::from_millis(200);
    let waits: Vec<Duration> = (0..64)
        .map(|_| {
            RetryBudget::until(
                Duration::from_millis(100),
                Duration::from_secs(1),
                now + Duration::from_secs(60),
            )
            .next_wait(Some(after))
            .unwrap()
        })
        .collect();
    assert!(waits.iter().all(|wait| *wait >= after && *wait <= after + Duration::from_millis(100)));
    let spread = *waits.iter().max().unwrap() - *waits.iter().min().unwrap();
    assert!(spread >= Duration::from_millis(50), "64 draws within {spread:?}");
}

#[test]
fn descriptor_exhaustion_needs_backoff() {
    assert!(accept_error_needs_backoff(&io::Error::from_raw_os_error(libc::EMFILE)));
    assert!(accept_error_needs_backoff(&io::Error::from_raw_os_error(libc::ENFILE)));
    assert!(!accept_error_needs_backoff(&io::Error::from(io::ErrorKind::Interrupted)));
    assert!(!accept_error_needs_backoff(&io::Error::from(io::ErrorKind::PermissionDenied)));
}

#[test]
fn a_transient_accept_error_waits_doubling_and_any_other_ends_the_listener() {
    let mut backoff =
        Backoff::new(Duration::from_millis(10), Duration::from_millis(250)).with_jitter(0.0);
    let emfile = io::Error::from_raw_os_error(libc::EMFILE);
    let delays: Vec<_> =
        (0..6).map(|_| accept_retry_delay(&mut backoff, &emfile).unwrap().as_millis()).collect();
    assert_eq!(delays, vec![10, 20, 40, 80, 160, 250]);
    backoff.reset();
    let aborted = io::Error::from(io::ErrorKind::ConnectionAborted);
    assert_eq!(accept_retry_delay(&mut backoff, &aborted), Some(Duration::from_millis(10)));
    let invalid = io::Error::from_raw_os_error(libc::EINVAL);
    assert_eq!(accept_retry_delay(&mut backoff, &invalid), None);
    assert_eq!(backoff.attempts(), 1, "a fatal error takes no step");
}
