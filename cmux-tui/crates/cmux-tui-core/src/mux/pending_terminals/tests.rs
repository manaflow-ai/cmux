use super::*;

/// Refusals make a host unadoptable only after enough of them in a row over
/// the minimum span; any other outcome starts the count again.
#[test]
fn refusal_streak_needs_count_and_span() {
    let start = Instant::now();
    let mut streak = RefusalStreak::default();
    assert!(!streak.record(true, start));
    assert!(!streak.record(true, start + Duration::from_secs(1)));
    // Three refusals, but within a burst shorter than the span.
    assert!(!streak.record(true, start + Duration::from_secs(2)));
    assert!(streak.record(true, start + NO_COMMON_PROTOCOL_MIN_SPAN));

    // A non-refusal resets the count and the start time.
    assert!(!streak.record(false, start + Duration::from_secs(20)));
    let later = start + Duration::from_secs(30);
    assert!(!streak.record(true, later));
    assert!(!streak.record(true, later + NO_COMMON_PROTOCOL_MIN_SPAN));
    assert!(streak.record(true, later + NO_COMMON_PROTOCOL_MIN_SPAN));
}
