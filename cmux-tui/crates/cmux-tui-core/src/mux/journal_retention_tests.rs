use super::*;

fn terminal(index: u8) -> TerminalPublicId {
    TerminalPublicId::parse(format!("term_{index:032x}")).unwrap()
}

fn schedule() -> RetentionSchedule {
    RetentionSchedule::new(Duration::from_secs(30), Duration::from_secs(1))
}

#[test]
fn a_reconnect_wave_coalesces_into_one_capture_after_it_settles() {
    let start = Instant::now();
    let mut schedule = schedule();
    for index in 0..100 {
        schedule.note(terminal(index), start + Duration::from_millis(u64::from(index)));
    }
    // One second after the last reconnect of the wave.
    assert_eq!(schedule.due_at(), Some(start + Duration::from_millis(1_099)));
    assert!(schedule.take_due(start + Duration::from_millis(1_098)).is_none());
    let batch = schedule.take_due(start + Duration::from_millis(1_099)).unwrap();
    assert_eq!(batch.len(), 100);
    assert_eq!(schedule.due_at(), None);
}

#[test]
fn captures_are_at_most_one_per_interval() {
    let start = Instant::now();
    let mut schedule = schedule();
    schedule.note(terminal(1), start);
    schedule.take_due(start + Duration::from_secs(1)).unwrap();
    schedule.captured(start + Duration::from_secs(2));
    schedule.note(terminal(2), start + Duration::from_secs(3));
    assert_eq!(schedule.due_at(), Some(start + Duration::from_secs(32)));
    schedule.note(terminal(2), start + Duration::from_secs(4));
    assert_eq!(schedule.pending_len(), 1, "a terminal is pending once");
}

#[test]
fn a_failed_capture_keeps_its_batch_and_backs_off_up_to_the_interval() {
    let start = Instant::now();
    let mut schedule = schedule();
    schedule.note(terminal(1), start);
    let batch = schedule.take_due(start + Duration::from_secs(1)).unwrap();
    schedule.failed(batch, start + Duration::from_secs(1));
    assert_eq!(schedule.pending_len(), 1);
    // The retry is spaced, and a re-queued batch settles again.
    assert_eq!(schedule.due_at(), Some(start + Duration::from_secs(2)));
    let mut now = start;
    for _ in 0..20 {
        now = schedule.due_at().unwrap();
        let batch = schedule.take_due(now).unwrap();
        schedule.failed(batch, now);
    }
    assert_eq!(
        schedule.due_at(),
        Some(now + Duration::from_secs(30)),
        "retry spacing is capped at the interval"
    );
}

#[test]
fn a_teardown_postpones_capture_until_it_ends() {
    let start = Instant::now();
    let mut schedule = schedule();
    schedule.note(terminal(1), start);
    schedule.begin_teardown();
    assert_eq!(schedule.due_at(), None);
    assert!(schedule.take_due(start + Duration::from_secs(60)).is_none());
    schedule.end_teardown();
    assert_eq!(schedule.due_at(), Some(start + Duration::from_secs(1)));
}

#[test]
fn a_wave_that_keeps_reconnecting_is_debounced_then_capped() {
    let start = Instant::now();
    let mut schedule = schedule();
    schedule.note(terminal(1), start);
    schedule.note(terminal(2), start + Duration::from_millis(900));
    assert_eq!(schedule.due_at(), Some(start + Duration::from_millis(1_900)));
    for step in 1..30_u64 {
        schedule.note(terminal(3), start + Duration::from_millis(900 * step));
    }
    assert_eq!(schedule.due_at(), Some(start + Duration::from_secs(10)));
}

#[test]
fn a_capture_during_teardown_or_handoff_does_not_run() {
    let mux = Mux::new_for_test("retention", SurfaceOptions::default());
    let teardown = mux.begin_terminal_teardown();
    assert!(matches!(mux.capture_coalesced_checkpoint(&[terminal(7)]), CaptureOutcome::Deferred));
    drop(teardown);
    mux.shutting_down.store(true, Ordering::Release);
    assert!(matches!(mux.capture_coalesced_checkpoint(&[terminal(7)]), CaptureOutcome::Skipped));
    assert_eq!(mux.coalesced_reconnect_checkpoints(), 0);
}
