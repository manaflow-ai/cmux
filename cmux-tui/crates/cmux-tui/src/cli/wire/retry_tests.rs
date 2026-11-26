use super::{Failure, decide};

#[test]
fn a_dropped_mutation_is_resent_with_its_key() {
    assert!(decide(true, false, Failure::Dropped));
}

#[test]
fn a_timed_out_mutation_is_not_resent() {
    // The daemon may still run it; a resend could only join, never help.
    assert!(!decide(true, false, Failure::Timeout));
}

#[test]
fn a_read_is_resent_after_a_drop_or_a_timeout() {
    assert!(decide(false, false, Failure::Dropped));
    assert!(decide(false, false, Failure::Timeout));
}

#[test]
fn streams_and_protocol_errors_are_never_resent() {
    assert!(!decide(false, true, Failure::Dropped));
    assert!(!decide(false, false, Failure::Other));
    assert!(!decide(true, false, Failure::Other));
}
