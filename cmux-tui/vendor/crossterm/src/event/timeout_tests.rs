use std::time::{Duration, Instant};

use super::PollTimeout;

#[test]
pub fn test_timeout_without_duration_does_not_have_leftover() {
    let timeout = PollTimeout::new(None);
    assert_eq!(timeout.leftover(), None)
}

#[test]
pub fn test_timeout_without_duration_never_elapses() {
    let timeout = PollTimeout::new(None);
    assert!(!timeout.elapsed());
}

#[test]
pub fn test_timeout_elapses() {
    const TIMEOUT_MILLIS: u64 = 100;

    let timeout = PollTimeout {
        timeout: Some(Duration::from_millis(TIMEOUT_MILLIS)),
        start: Instant::now() - Duration::from_millis(2 * TIMEOUT_MILLIS),
    };

    assert!(timeout.elapsed());
}

#[test]
pub fn test_elapsed_timeout_has_zero_leftover() {
    const TIMEOUT_MILLIS: u64 = 100;

    let timeout = PollTimeout {
        timeout: Some(Duration::from_millis(TIMEOUT_MILLIS)),
        start: Instant::now() - Duration::from_millis(2 * TIMEOUT_MILLIS),
    };

    assert!(timeout.elapsed());
    assert_eq!(timeout.leftover(), Some(Duration::from_millis(0)));
}

#[test]
pub fn test_not_elapsed_timeout_has_positive_leftover() {
    let timeout = PollTimeout::new(Some(Duration::from_secs(60)));

    assert!(!timeout.elapsed());
    assert!(timeout.leftover().unwrap() > Duration::from_secs(0));
}
