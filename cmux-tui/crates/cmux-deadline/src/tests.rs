use super::*;
use std::time::Instant;

const S: fn(u64) -> Duration = Duration::from_secs;

#[test]
fn remaining_counts_down_and_never_goes_negative() {
    let t0 = Instant::now();
    let d = Deadline::starting(t0, S(60));
    assert_eq!(d.remaining_at(t0), S(60));
    assert_eq!(d.remaining_at(t0 + S(45)), S(15));
    assert_eq!(d.remaining_at(t0 + S(90)), Duration::ZERO);
    assert!(!d.expired_at(t0 + S(59)));
    assert!(d.expired_at(t0 + S(60)));
    assert_eq!(d.elapsed_at(t0 + S(7)), S(7));
}

/// A step's cap never outlives its parent; a short cap ends first.
#[test]
fn sub_ends_at_the_earlier_of_its_cap_and_the_parent() {
    let t0 = Instant::now();
    let d = Deadline::starting(t0, S(60));
    assert_eq!(d.sub_at(t0 + S(50), S(30)).end(), d.end());
    assert_eq!(d.sub_at(t0 + S(10), S(5)).end(), t0 + S(15));
    assert_eq!(d.sub_at(t0 + S(10), S(5)).start(), t0 + S(10));
}

#[test]
fn timeout_keeps_the_reserve_obeys_the_cap_and_never_hands_out_zero() {
    let t0 = Instant::now();
    let d = Deadline::starting(t0, S(60));
    assert_eq!(d.timeout_at(t0, None, S(1), S(10)), S(50));
    assert_eq!(d.timeout_at(t0, Some(S(5)), S(1), Duration::ZERO), S(5));
    assert_eq!(d.timeout_at(t0 + S(120), None, S(1), Duration::ZERO), S(1));
}

/// The bug the type exists for: a retry loop of 10 s tries under one 25 s deadline makes three
/// tries and ends on time, where a fresh budget per try would go on.
#[test]
fn a_retry_loop_under_one_deadline_ends_when_it_does() {
    let t0 = Instant::now();
    let d = Deadline::starting(t0, S(25));
    let mut now = t0;
    let mut tries = 0;
    while !d.expired_at(now) {
        let step = d.timeout_at(now, Some(S(10)), Duration::from_millis(1), Duration::ZERO);
        now += step;
        tries += 1;
    }
    assert_eq!((tries, now), (3, t0 + S(25)));
}

#[test]
fn a_bound_past_the_clock_is_clamped_not_a_panic() {
    let d = Deadline::<Instant>::after(Duration::MAX);
    assert!(!d.expired());
    assert!(d.remaining() > S(86_400));
}

#[cfg(feature = "tokio")]
#[tokio::test(start_paused = true)]
async fn a_paused_tokio_clock_moves_a_tokio_deadline() {
    let d = Deadline::<tokio::time::Instant>::after(S(30));
    tokio::time::advance(S(20)).await;
    assert_eq!(d.remaining(), S(10));
    tokio::time::advance(S(20)).await;
    assert!(d.expired());
}
