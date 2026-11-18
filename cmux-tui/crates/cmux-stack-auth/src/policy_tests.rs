use std::time::Duration;

use super::*;
use crate::error::RateLimit;

#[test]
fn the_sign_in_wait_honors_retry_after_within_one_to_one_hundred_twenty_seconds() {
    let after = |s| Some(Duration::from_secs(s));
    assert_eq!(SignInRateLimit::delay(after(0), 1, 1.0), Duration::from_secs(1));
    assert_eq!(SignInRateLimit::delay(after(45), 4, 0.5), Duration::from_secs(45));
    assert_eq!(SignInRateLimit::delay(after(900), 1, 1.0), Duration::from_secs(120));
}

#[test]
fn the_sign_in_wait_without_retry_after_doubles_from_two_to_sixty_seconds() {
    let full: Vec<_> =
        (1..=8).map(|retry| SignInRateLimit::delay(None, retry, 1.0).as_secs()).collect();
    assert_eq!(full, [2, 4, 8, 16, 32, 60, 60, 60]);
    assert_eq!(SignInRateLimit::delay(None, 0, 0.5), Duration::from_secs(1));
    assert_eq!(SignInRateLimit::MAXIMUM_RETRIES, 6);
}

#[test]
fn a_rate_limit_is_recognized_on_either_code() {
    let limited = StackError::RateLimited(RateLimit {
        endpoint: "/api/v1/users/me".into(),
        body_kind: BodyKind::Html,
        retry_after_s: Some(3.5),
        request_id: None,
    });
    let read = SignInRateLimit::from_error(&limited).unwrap();
    assert_eq!(read.retry_after, Some(Duration::from_millis(3500)));
    assert_eq!(read.endpoint, "/api/v1/users/me");
    assert_eq!(read.body_kind, BodyKind::Html);

    let known = StackError::Known {
        code: "rate_limit".into(),
        message: String::new(),
        http_status: 400,
        request_id: None,
        details: None,
    };
    assert_eq!(SignInRateLimit::from_error(&known).map(|r| r.endpoint), Some("/unknown".into()));
    assert_eq!(SignInRateLimit::from_error(&StackError::TimedOut), None);
}

#[test]
fn the_production_deadlines() {
    let timeouts = AuthTimeouts::default();
    assert_eq!(timeouts.interactive_flow, Duration::from_secs(300));
    assert_eq!(timeouts.network, Duration::from_secs(60));
    assert_eq!(timeouts.session_restore, Duration::from_secs(8));
    let custom = AuthTimeouts::new(Duration::from_secs(1), Duration::from_secs(2), None);
    assert_eq!(custom.session_restore, Duration::from_secs(2));
}
