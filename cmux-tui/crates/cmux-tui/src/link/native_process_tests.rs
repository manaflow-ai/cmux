use std::time::Duration;

use std::time::Instant;

use cmux_link::elapsed::Elapsed;

use super::{ReadFailure, keeps_policy, renewal_delay};

const S: Duration = Duration::from_secs(1);

#[test]
fn a_fast_read_renews_halfway_through_what_is_left() {
    assert_eq!(renewal_delay(28 * S, S / 2), 14 * S);
    assert_eq!(renewal_delay(110 * S, 2 * S), 55 * S);
}

#[test]
fn a_slow_read_starts_early_enough_to_land_before_the_lease_ends() {
    // 30 s lease, 10 s read: 20 s left, the next read starts after 4 s
    // (16 s of lead) and lands about 6 s before the end, where halfway
    // (10 s, landing at 20 s) would have been exactly at the end.
    let delay = renewal_delay(20 * S, 10 * S);
    assert_eq!(delay, 4 * S);
    assert!(delay + 10 * S < 20 * S);
    // 120 s lease, 20 s read: lands with a wide margin.
    let delay = renewal_delay(100 * S, 20 * S);
    assert_eq!(delay, 50 * S);
    assert!(delay + 20 * S < 100 * S);
}

#[test]
fn a_read_slower_than_what_is_left_starts_at_once() {
    assert_eq!(renewal_delay(8 * S, 12 * S), Duration::from_millis(250));
    assert_eq!(renewal_delay(Duration::ZERO, S), Duration::ZERO);
}

#[test]
fn local_admission_keeps_the_policy_through_a_read_with_no_answer() {
    let now = Instant::now();
    let end = now + 600 * S;
    assert_eq!(keeps_policy(ReadFailure::Unanswered, Some(end), None, now), Some(600 * S));
}

#[test]
fn a_refused_read_closes_even_under_local_admission() {
    let now = Instant::now();
    assert_eq!(keeps_policy(ReadFailure::Refused, Some(now + 600 * S), None, now), None);
}

#[test]
fn without_admit_until_or_a_lease_every_failed_read_closes() {
    // The kill switch: a policy with no admit_until gives no admission end,
    // and with no lease left there is nothing to keep serving.
    let now = Instant::now();
    assert_eq!(keeps_policy(ReadFailure::Unanswered, None, None, now), None);
}

#[test]
fn an_admission_that_has_ended_keeps_nothing() {
    let now = Instant::now() + 10 * S;
    assert_eq!(keeps_policy(ReadFailure::Unanswered, Some(now - S), None, now), None);
    assert_eq!(keeps_policy(ReadFailure::Unanswered, Some(now), None, now), None);
}

/// A lease that ends `left` from `now` on both clocks.
fn lease(now: Instant, left: Duration) -> (Instant, cmux_link::elapsed::Deadline) {
    let elapsed = Elapsed::system().expect("system clock");
    let deadline = elapsed.deadline_at(left).expect("deadline");
    (now + left, deadline)
}

#[test]
fn without_admit_until_a_read_with_no_answer_keeps_the_installed_lease() {
    // #36008: a failed renewal is not a revocation; the lease the receiver
    // already holds keeps serving until it ends on its own.
    let now = Instant::now();
    let kept = keeps_policy(ReadFailure::Unanswered, None, Some(&lease(now, 20 * S)), now).unwrap();
    assert!(kept <= 20 * S && kept > 19 * S, "{kept:?}");
}

#[test]
fn a_refused_read_closes_even_inside_its_lease() {
    let now = Instant::now();
    let lease = lease(now, 20 * S);
    assert_eq!(keeps_policy(ReadFailure::Refused, Some(now + 600 * S), Some(&lease), now), None);
}

#[test]
fn local_admission_outlasting_the_lease_keeps_to_admit_until() {
    let now = Instant::now();
    let lease = lease(now, 20 * S);
    assert_eq!(
        keeps_policy(ReadFailure::Unanswered, Some(now + 600 * S), Some(&lease), now),
        Some(600 * S)
    );
}
