/// A task that is busy while its folder churns holds one wake however many signals come, and
/// its next wait ends once; a gone task is told (RFD 0124 R4).
#[test]
fn signals_to_a_busy_watch_task_hold_one_wake() {
    let (signal, mut wakes) = super::wake_slot();
    for _ in 0..10_000 {
        assert!(super::wake(&signal), "the task is there");
    }
    assert_eq!(signal.capacity(), 0, "one wake waits");
    assert!(wakes.try_recv().is_ok());
    assert!(wakes.try_recv().is_err(), "and only one");
    drop(wakes);
    assert!(!super::wake(&signal), "a gone task is told");
}
