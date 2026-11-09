//! Retiring a surface while its operations fail (moved from pty_input.rs).

use super::*;

#[test]
fn retiring_a_failed_surface_removes_its_lane_quarantine() {
    let (failure_tx, failure_rx) = std::sync::mpsc::channel();
    let dispatcher = PtyInputDispatcher::spawn(move |failure| {
        failure_tx.send(failure).unwrap();
    })
    .unwrap();
    let sender = dispatcher.sender();

    assert_eq!(
        sender.enqueue_coalescing_surface_operation("clear terminal history", 41, false, || Err(
            anyhow::anyhow!("partial fallback write")
        ),),
        PtyInputEnqueueResult::Accepted
    );
    let failure = failure_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert!(failure.lane_failed);
    assert_eq!(sender.enqueue(event(41, 1, PtyInputKind::Ordered)), PtyInputEnqueueResult::Failed);

    sender.retire_surface(41);
    // The failure is reported before the operation leaves the in-flight set
    // (completion is a barrier), so read the lane state only once it settled.
    wait_until_lane_settles(&sender, 41);

    let state = sender.queue.state.lock().unwrap();
    assert!(!state.failed_lanes.contains(&lane(41)));
    assert!(!state.retired_in_flight_lanes.contains(&lane(41)));
    drop(state);
    assert_eq!(
        sender.enqueue(event(41, 2, PtyInputKind::Ordered)),
        PtyInputEnqueueResult::Accepted
    );
}

#[test]
fn retiring_an_in_flight_surface_prevents_late_lane_quarantine() {
    let (failure_tx, failure_rx) = std::sync::mpsc::channel();
    let dispatcher = PtyInputDispatcher::spawn(move |failure| {
        failure_tx.send(failure).unwrap();
    })
    .unwrap();
    let sender = dispatcher.sender();
    let (finished_tx, finished_rx) = std::sync::mpsc::channel();
    let (resume_tx, resume_rx) = std::sync::mpsc::channel();
    let resume_rx = Arc::new(Mutex::new(resume_rx));
    sender.set_after_operation_before_cleanup(Some(Arc::new(move || {
        finished_tx.send(()).unwrap();
        resume_rx.lock().unwrap().recv().unwrap();
    })));

    assert_eq!(
        sender.enqueue_coalescing_surface_operation("clear terminal history", 41, false, || Err(
            anyhow::anyhow!("partial fallback write")
        ),),
        PtyInputEnqueueResult::Accepted
    );
    finished_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    sender.retire_surface(41);
    resume_tx.send(()).unwrap();
    let failure = failure_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert!(failure.lane_failed);
    sender.set_after_operation_before_cleanup(None);

    let state = sender.queue.state.lock().unwrap();
    assert!(!state.failed_lanes.contains(&lane(41)));
    assert!(!state.retired_in_flight_lanes.contains(&lane(41)));
    drop(state);
    assert_eq!(
        sender.enqueue(event(41, 2, PtyInputKind::Ordered)),
        PtyInputEnqueueResult::Accepted
    );
}

/// A surface retired from inside its own operation's failure report (the
/// report runs before the operation leaves the in-flight set) must not keep
/// a stale retirement once the operation completes (hosted flake of
/// retiring_a_failed_surface_removes_its_lane_quarantine).
#[test]
fn retiring_a_surface_during_its_failure_report_leaves_no_stale_retirement() {
    let holder: Arc<std::sync::OnceLock<PtyInputSender>> = Arc::new(std::sync::OnceLock::new());
    let retire_from_report = holder.clone();
    let (failure_tx, failure_rx) = std::sync::mpsc::channel();
    let dispatcher = PtyInputDispatcher::spawn(move |failure| {
        if let Some(sender) = retire_from_report.get() {
            sender.retire_surface(41);
        }
        failure_tx.send(failure).unwrap();
    })
    .unwrap();
    let sender = dispatcher.sender();
    assert!(holder.set(sender.clone()).is_ok());

    assert_eq!(
        sender.enqueue_coalescing_surface_operation("clear terminal history", 41, false, || Err(
            anyhow::anyhow!("partial fallback write")
        ),),
        PtyInputEnqueueResult::Accepted
    );
    let failure = failure_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    assert!(failure.lane_failed);
    wait_until_lane_settles(&sender, 41);

    let state = sender.queue.state.lock().unwrap();
    assert!(!state.failed_lanes.contains(&lane(41)));
    assert!(!state.retired_in_flight_lanes.contains(&lane(41)), "stale retirement");
    drop(state);
    assert_eq!(
        sender.enqueue(event(41, 2, PtyInputKind::Ordered)),
        PtyInputEnqueueResult::Accepted
    );
}

/// Waits (bounded) until `surface`'s lane has no operation in flight.
fn wait_until_lane_settles(sender: &PtyInputSender, surface: SurfaceId) {
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut state = sender.queue.state.lock().unwrap();
    while state.in_flight_surface_operations.contains_key(&lane(surface)) {
        let left = deadline.saturating_duration_since(Instant::now());
        assert!(!left.is_zero(), "surface {surface} operation never left the in-flight set");
        state = sender.queue.changed.wait_timeout(state, left).unwrap().0;
    }
}
