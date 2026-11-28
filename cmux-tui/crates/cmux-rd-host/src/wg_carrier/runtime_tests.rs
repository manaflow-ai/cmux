use super::*;

#[test]
fn stalled_media_queue_expires_at_handoff() {
    let queued = QueuedMedia { queued_at: Instant::now(), payload: vec![1] };
    let at = queued.queued_at;
    assert_eq!(queued.take_payload_if_fresh(at + Duration::from_millis(50)), Some(vec![1]));
    let queued = QueuedMedia { queued_at: at, payload: vec![2] };
    assert!(queued.take_payload_if_fresh(at + Duration::from_millis(51)).is_none());
}

#[test]
fn only_media_uses_expiring_handoff() {
    assert!(expires_at_media_handoff(Priority::Media));
    assert!(!expires_at_media_handoff(Priority::Interactive));
    assert!(!expires_at_media_handoff(Priority::Bulk));
}
