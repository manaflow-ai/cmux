use super::*;

#[test]
fn stalled_rd_media_handoff_expires_without_aging_control() {
    let queued = QueuedMedia { queued_at: Instant::now(), datagram: vec![1] };
    let at = queued.queued_at;
    assert_eq!(queued.take_payload_if_fresh(at + Duration::from_millis(50)), Some(vec![1]));
    let queued = QueuedMedia { queued_at: at, datagram: vec![2] };
    assert!(queued.take_payload_if_fresh(at + Duration::from_millis(51)).is_none());
}

/// The wake-up both platforms wait on: idle, pending after wakes, idle again once drained.
#[test]
fn wake_is_readable_only_while_pending() {
    let wake = Wake::new().unwrap();
    let idle = Instant::now();
    wait_readable(&[wake.raw()], 50);
    assert!(idle.elapsed() >= Duration::from_millis(40), "idle wake was readable");
    wake.wake();
    wake.wake();
    let pending = Instant::now();
    wait_readable(&[wake.raw()], 5_000);
    assert!(pending.elapsed() < Duration::from_secs(4), "pending wake never became readable");
    wake.drain();
    let drained = Instant::now();
    wait_readable(&[wake.raw()], 50);
    assert!(drained.elapsed() >= Duration::from_millis(40), "drained wake stayed readable");
}
