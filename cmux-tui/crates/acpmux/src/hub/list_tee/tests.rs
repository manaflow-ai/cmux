use super::*;

#[test]
fn mark_queue_deduplicates_ids_but_counts_each_mark() {
    let state = TeeState::default();
    state.mark("chat");
    state.mark("chat");
    state.mark("other");

    assert_eq!(state.marks.load(Ordering::Relaxed), 3);
    let mut ids = state.take();
    ids.sort();
    assert_eq!(ids, ["chat", "other"]);
    assert!(state.take().is_empty());
}

#[test]
fn expiry_deadlines_are_replaced_and_expiry_marks_once() {
    let state = TeeState::default();
    let mut expiries = Expiries::default();
    expiries.set("chat", Some(100));
    expiries.set("chat", Some(200));

    expiries.mark_due(&state, 150);
    assert!(state.take().is_empty(), "the replaced deadline must not fire");
    expiries.mark_due(&state, 200);
    assert_eq!(state.take(), vec!["chat".to_owned()]);
    expiries.mark_due(&state, 300);
    assert!(state.take().is_empty(), "an expired deadline is removed after one mark");
}

#[test]
fn removing_a_deadline_prevents_a_late_mark() {
    let state = TeeState::default();
    let mut expiries = Expiries::default();
    expiries.set("chat", Some(100));
    expiries.set("chat", None);
    expiries.mark_due(&state, 1000);
    assert!(state.take().is_empty());
}

#[test]
fn one_hundred_thousand_stream_sends_do_not_mark() {
    let events = super::super::list_guard::Events::new(1);
    let state = Arc::new(TeeState::default());
    events.install_tee(Arc::new(TeeHandle { state: state.clone() }));
    let mut event = super::super::row_log::row_event("chat");
    Arc::make_mut(&mut event.record).kind = "agent_message_chunk".into();
    for _ in 0..100_000 {
        let _ = events.send_live_stream(event.clone());
    }
    assert_eq!(state.marks.load(Ordering::Relaxed), 0);
    assert!(!state.has_pending());
    Arc::make_mut(&mut event.record).kind = "status".into();
    let _ = events.send(event);
    assert_eq!(state.take(), ["chat"]);
}

#[test]
fn due_work_is_bounded_and_drains_without_new_marks() {
    let state = TeeState::default();
    let mut expiries = Expiries::default();
    for n in 0..1000 {
        expiries.set(&format!("chat-{n}"), Some(100));
    }
    let mut total = 0;
    for _ in 0..4 {
        expiries.mark_due(&state, 100);
        let batch = state.take();
        assert!(batch.len() <= BATCH);
        total += batch.len();
    }
    assert_eq!(total, 1000);
    expiries.mark_due(&state, 100);
    assert!(!state.has_pending());
}
