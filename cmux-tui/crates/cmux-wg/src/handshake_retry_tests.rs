use super::*;

const MS: Duration = Duration::from_millis(1);

#[test]
fn idle_has_no_deadline() {
    let mut retry = HandshakeRetry::default();
    retry.on_initiation(Instant::now(), true);
    assert_eq!(retry.deadline(None), None);
}

#[test]
fn resends_double_and_stop_before_boringtuns_retry() {
    let start = Instant::now();
    let mut retry = HandshakeRetry::default();
    retry.on_initiation(start, true);
    retry.set_waiting(start, true);
    let mut now = start;
    let mut waits = Vec::new();
    while let Some(due) = retry.deadline(None) {
        assert!(!retry.fire(due - MS, None));
        assert!(retry.fire(due, None));
        waits.push(due - now);
        now = due;
        retry.on_initiation(now, false);
    }
    assert_eq!(waits, [250 * MS, 500 * MS, 1000 * MS, 2000 * MS]);
}

#[test]
fn an_old_initiation_is_resent_at_once() {
    let start = Instant::now();
    let mut retry = HandshakeRetry::default();
    retry.on_initiation(start, true);
    let later = start + Duration::from_secs(3);
    retry.set_waiting(later, true);
    assert!(retry.fire(later, None));
}

#[test]
fn srtt_sets_the_first_wait() {
    let start = Instant::now();
    let mut retry = HandshakeRetry::default();
    retry.on_initiation(start, true);
    retry.set_waiting(start, true);
    assert_eq!(retry.deadline(Some(400 * MS)), Some(start + 800 * MS));
}

#[test]
fn a_spent_attempt_waits_for_a_fresh_one() {
    let start = Instant::now();
    let mut retry = HandshakeRetry::default();
    retry.on_initiation(start, true);
    retry.set_waiting(start, true);
    while let Some(due) = retry.deadline(None) {
        assert!(retry.fire(due, None));
        retry.on_initiation(due, false);
    }
    retry.on_initiation(start + Duration::from_secs(5), false);
    assert_eq!(retry.deadline(None), None, "boringtun's retry gets no resends");
    retry.on_initiation(start + Duration::from_secs(95), true);
    assert!(retry.deadline(None).is_some(), "a new attempt does");
    retry.on_session();
    assert_eq!(retry.deadline(None), None);
}
