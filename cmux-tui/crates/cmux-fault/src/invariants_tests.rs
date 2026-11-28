use super::*;

#[test]
fn lost_doubled_invented_and_reordered_records_are_named() {
    assert!(client_equals_journal(&[1, 2, 3], &[1, 2, 3]).is_ok());
    assert!(client_equals_journal(&[1, 2, 3], &[1, 3]).unwrap_err().contains("never reached"));
    assert!(client_equals_journal(&[1, 2], &[1, 2, 2]).unwrap_err().contains("twice"));
    assert!(client_equals_journal(&[1, 2], &[1, 2, 9]).unwrap_err().contains("lacks"));
    assert!(client_equals_journal(&[1, 2], &[2, 1]).unwrap_err().contains("order"));
    assert!(each_once(&["a", "b"], &["b", "a"]).is_ok());
    assert!(each_once(&["a"], &["a", "a"]).unwrap_err().contains("2 times"));
}

#[test]
fn a_state_must_be_read_right_after_its_bound() {
    let at = |ms, state| Reading { at: Duration::from_millis(ms), state };
    let readings = [at(100, "connecting"), at(900, "connecting"), at(1_200, "credential")];
    let ok = |s: &&str| *s != "connecting";
    assert!(state_within(&readings, Duration::ZERO, Duration::from_secs(1), "x", ok).is_ok());
    let late = state_within(&readings, Duration::ZERO, Duration::from_millis(500), "x", ok);
    assert!(late.unwrap_err().contains("connecting"));
    let unread = state_within(&readings, Duration::from_secs(5), Duration::ZERO, "x", ok);
    assert!(unread.unwrap_err().contains("no reading"));
    assert!(restarts_within("d", 3, 2).is_err());
    assert!(recovered_within("d", None, Duration::ZERO).is_err());
}
