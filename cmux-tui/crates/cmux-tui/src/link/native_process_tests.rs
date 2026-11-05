use std::time::Duration;

use std::time::Instant;

use super::{ReadFailure, RenewalLog, admission_line, keeps_policy, renewal_delay};

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
    assert_eq!(keeps_policy(ReadFailure::Unanswered, Some(end), now), Some(600 * S));
}

#[test]
fn a_refused_read_closes_even_under_local_admission() {
    let now = Instant::now();
    assert_eq!(keeps_policy(ReadFailure::Refused, Some(now + 600 * S), now), None);
}

#[test]
fn without_admit_until_every_failed_read_closes_as_before() {
    // The kill switch: a policy with no admit_until gives no admission end.
    let now = Instant::now();
    assert_eq!(keeps_policy(ReadFailure::Unanswered, None, now), None);
}

#[test]
fn an_admission_that_has_ended_keeps_nothing() {
    let now = Instant::now() + 10 * S;
    assert_eq!(keeps_policy(ReadFailure::Unanswered, Some(now - S), now), None);
    assert_eq!(keeps_policy(ReadFailure::Unanswered, Some(now), now), None);
}

#[test]
fn an_answered_read_says_whether_admit_until_is_present_and_how_long_it_took() {
    let ms = Duration::from_millis;
    assert_eq!(
        admission_line(ms(6970), Some(Duration::from_secs(600))),
        "cmux link: receiver policy read took 6970 ms; admit_until present (600 s of local admission)"
    );
    assert_eq!(
        admission_line(ms(212), None),
        "cmux link: receiver policy read took 212 ms; admit_until absent (no local admission)"
    );
}

#[test]
fn the_admission_line_is_written_on_the_first_read_and_on_each_change_only() {
    let mut log = RenewalLog { last_slow: None, last_admits: None };
    let ms = Duration::from_millis;
    log.admission(ms(10), None);
    assert_eq!(log.last_admits, Some(false));
    log.admission(ms(10), None);
    assert_eq!(log.last_admits, Some(false));
    log.admission(ms(10), Some(Duration::from_secs(60)));
    assert_eq!(log.last_admits, Some(true));
}
