use std::time::Duration;

use std::time::Instant;

use super::{
    ReadFailure, RenewalLog, admission_line, keeps_policy, next_read_delay, peerless_line,
    peerless_wait, renewal_delay,
};

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
fn a_policy_that_names_no_peers_is_read_again_within_seconds_not_at_renewal() {
    // A new machine read its policy before the team's mesh ACL named it: no
    // peers, a 120 s lease. It waited 55 s for the renewal and dropped every
    // dial meanwhile (prod 2026-11-06: "Machine didn't connect" at 40.7 s).
    let first = peerless_wait(None);
    assert_eq!(first, 2 * S);
    assert_eq!(next_read_delay(110 * S, 2 * S, Some(first)), 2 * S);
    // Then 4, 8, 16 s ... and never later than the normal renewal.
    let waits: Vec<Duration> =
        std::iter::successors(Some(first), |wait| Some(peerless_wait(Some(*wait))))
            .take(9)
            .collect();
    let expected = [2, 4, 8, 16, 32, 64, 120, 120, 120].map(|secs| secs * S);
    assert_eq!(waits, expected, "capped at the longest lease");
    assert_eq!(next_read_delay(110 * S, 2 * S, Some(120 * S)), 55 * S);
    // A policy with peers keeps the normal renewal.
    assert_eq!(next_read_delay(110 * S, 2 * S, None), 55 * S);
}

#[test]
fn the_journal_names_a_policy_that_starts_or_stops_naming_no_peers() {
    assert_eq!(
        peerless_line(None, Some(2 * S)).as_deref(),
        Some("cmux link: receiver policy names no peers; reading again in 2000 ms")
    );
    assert_eq!(peerless_line(Some(2 * S), Some(4 * S)), None);
    assert_eq!(
        peerless_line(Some(4 * S), None).as_deref(),
        Some("cmux link: receiver policy names its peers")
    );
    assert_eq!(peerless_line(None, None), None);
}

#[test]
fn renewal_log_backs_off_while_reads_name_no_peers_and_resets_when_peers_come() {
    let mut log = RenewalLog { last_slow: None, last_admits: None, peerless: None };
    assert_eq!(log.peers(true), Some(2 * S));
    assert_eq!(log.peers(true), Some(4 * S));
    assert_eq!(log.peers(false), None);
    assert_eq!(log.peers(true), Some(2 * S), "a policy that loses its peers starts again at 2 s");
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
    let mut log = RenewalLog { last_slow: None, last_admits: None, peerless: None };
    let ms = Duration::from_millis;
    let admitted = Some(Duration::from_secs(60));
    assert!(log.admission_change(ms(10), None).is_some(), "the first read is logged");
    assert_eq!(log.admission_change(ms(10), None), None, "the same admission again is not");
    assert!(log.admission_change(ms(10), admitted).is_some(), "admission appearing is logged");
    assert_eq!(log.admission_change(ms(10), admitted), None);
    assert!(log.admission_change(ms(10), None).is_some(), "admission ending is logged");
}
