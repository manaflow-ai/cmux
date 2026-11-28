use super::*;

#[test]
fn capacity_failures_are_consecutive_and_end_once() {
    let mut retries = Retries::default();
    assert!(!retries.observe(1));
    assert!(!retries.observe(1));
    assert!(!retries.observe(2), "a model response starts a new sequence");
    assert!(!retries.observe(2));
    assert!(retries.observe(2));
    assert!(!retries.observe(2));
}
