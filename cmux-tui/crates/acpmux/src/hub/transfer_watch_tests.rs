use super::marker_is_uncommitted;

#[test]
fn marker_ahead_of_durable_epoch_is_not_resumed() {
    assert!(marker_is_uncommitted(Some(1), 0));
    assert!(!marker_is_uncommitted(Some(1), 1));
    assert!(!marker_is_uncommitted(None, 0));
}
