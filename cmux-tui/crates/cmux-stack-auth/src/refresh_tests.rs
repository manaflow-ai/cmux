use std::time::{Duration, Instant};

use super::*;

fn limited(retry_after_s: Option<f64>) -> RefreshOutcome {
    RefreshOutcome::RateLimited { retry_after_s, body_kind: BodyKind::Json }
}

#[test]
fn a_retry_after_is_clamped_to_one_to_six_hundred_seconds() {
    assert_eq!(RefreshRateLimiter::delay(Some(0.2), 1, 1.0), Duration::from_secs(1));
    assert_eq!(RefreshRateLimiter::delay(Some(42.0), 3, 0.5), Duration::from_secs(42));
    assert_eq!(RefreshRateLimiter::delay(Some(9_000.0), 1, 1.0), Duration::from_secs(600));
}

#[test]
fn with_no_retry_after_the_backoff_doubles_from_five_seconds_to_five_minutes() {
    let full: Vec<_> =
        (1..=8).map(|streak| RefreshRateLimiter::delay(None, streak, 1.0).as_secs()).collect();
    assert_eq!(full, [5, 10, 20, 40, 80, 160, 300, 300]);
    assert_eq!(RefreshRateLimiter::delay(None, 1, 0.5), Duration::from_millis(2500));
    // Jitter outside 0.5 to 1 is clamped.
    assert_eq!(RefreshRateLimiter::delay(None, 1, 0.0), Duration::from_millis(2500));
    assert_eq!(RefreshRateLimiter::delay(None, 1, 7.0), Duration::from_secs(5));
}

#[test]
fn a_429_cools_down_and_a_success_ends_the_streak() {
    let now = Instant::now();
    let mut limiter = RefreshRateLimiter::default();
    assert!(!limiter.cooling_down(now));
    assert_eq!(limiter.record(&limited(Some(30.0)), now, 1.0), Some(Duration::from_secs(30)));
    assert!(limiter.cooling_down(now + Duration::from_secs(29)));
    assert!(!limiter.cooling_down(now + Duration::from_secs(30)));
    assert_eq!(limiter.record(&limited(None), now, 1.0), Some(Duration::from_secs(10)));
    assert_eq!(limiter.streak(), 2);
    // A transient failure leaves the streak and cooldown as they were.
    assert_eq!(limiter.record(&RefreshOutcome::Transient, now, 1.0), None);
    assert_eq!(limiter.streak(), 2);
    assert!(limiter.cooling_down(now + Duration::from_secs(5)));
    limiter.record(&RefreshOutcome::Success { access_token: "t".into() }, now, 1.0);
    assert_eq!(limiter, RefreshRateLimiter::default());
}

#[test]
fn a_rejection_ends_the_streak_too() {
    let now = Instant::now();
    let mut limiter = RefreshRateLimiter::default();
    limiter.record(&limited(None), now, 1.0);
    limiter.record(&RefreshOutcome::Rejected, now, 1.0);
    assert!(!limiter.cooling_down(now));
    assert_eq!(limiter.streak(), 0);
}

#[test]
fn jitter_stays_in_range_and_a_success_debug_line_has_no_token() {
    for _ in 0..100 {
        let jitter = random_jitter();
        assert!((0.5..=1.0).contains(&jitter), "{jitter}");
    }
    let line = format!("{:?}", RefreshOutcome::Success { access_token: "secret".into() });
    assert!(!line.contains("secret"));
}
