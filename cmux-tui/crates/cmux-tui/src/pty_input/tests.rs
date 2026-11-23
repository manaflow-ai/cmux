use {super::*, crate::local_actor::TuiMuxOps};
mod retire_tests;
use cmux_tui_core::{Mux as TestMux, SurfaceOptions as TestSurfaceOptions};

fn lane(surface_id: SurfaceId) -> PtyInputLane {
    PtyInputLane { session_generation: 1, surface_id }
}

fn event(surface_id: SurfaceId, bytes: u8, kind: PtyInputKind) -> PtyInputEvent {
    PtyInputEvent::input(
        surface_id,
        SurfaceHandle::RemoteBrowserUnsupported,
        SmallVec::from_slice(&[bytes]),
        kind,
    )
}

#[test]
fn exited_input_is_rejected_before_transport_but_mutations_are_not() {
    assert!(known_exited_input(PtyInputKind::Ordered, true));
    assert!(!known_exited_input(PtyInputKind::Mutation, true));
    assert!(!known_exited_input(PtyInputKind::Ordered, false));
}

#[test]
fn clean_terminal_exit_is_known_not_delivered_and_does_not_fail_its_lane() {
    let mux = TestMux::new(
        "clean-terminal-exit-lane-test",
        TestSurfaceOptions {
            command: Some(vec!["/bin/sh".to_string(), "-c".to_string(), "exit 0".to_string()]),
            ..Default::default()
        },
    );
    let surface = mux.new_workspace(Some("work".to_string()), Some((20, 8))).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while !surface.is_dead() {
        assert!(Instant::now() < deadline, "terminal host did not exit");
        std::thread::yield_now();
    }

    let (failure_tx, failure_rx) = std::sync::mpsc::channel();
    let mut dispatcher = PtyInputDispatcher::spawn(move |failure| {
        failure_tx.send(failure).unwrap();
    })
    .unwrap();
    let input = || {
        PtyInputEvent::input(
            surface.id,
            SurfaceHandle::Local(surface.clone(), mux.clone()),
            PtyInputBytes::from_slice(b"x"),
            PtyInputKind::Ordered,
        )
    };

    assert_eq!(dispatcher.enqueue(input()), PtyInputEnqueueResult::Accepted);
    let failure = failure_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert_eq!(failure.label, "terminal exited");
    assert_eq!(failure.delivery, PtyOperationDelivery::KnownNotDelivered);
    assert!(!failure.lane_failed, "a clean process exit must not poison the input lane");
    assert_eq!(dispatcher.enqueue(input()), PtyInputEnqueueResult::Accepted);

    assert!(dispatcher.shutdown(Duration::from_secs(1)));
    mux.shutdown();
}

#[test]
fn exit_observed_after_a_failed_write_keeps_delivery_ambiguous() {
    let mux = TestMux::new("post-write-exit-delivery-test", TestSurfaceOptions::default());
    let surface = mux.new_workspace(None, Some((20, 8))).unwrap();
    let handle = SurfaceHandle::Local(surface.clone(), mux.clone());
    let (failure_tx, failure_rx) = std::sync::mpsc::channel();
    let dispatcher = PtyInputDispatcher::spawn(move |failure| {
        failure_tx.send(failure).unwrap();
    })
    .unwrap();
    dispatcher.sender().set_after_operation_before_cleanup(Some(Arc::new({
        let surface = surface.clone();
        move || surface.kill()
    })));
    let mut input = PtyInputEvent::input(
        surface.id,
        handle,
        PtyInputBytes::from_slice(b"x"),
        PtyInputKind::Ordered,
    );
    input.mutation = Some(Box::new(|| Err(anyhow::anyhow!("flush failed after acceptance"))));

    assert_eq!(dispatcher.enqueue(input), PtyInputEnqueueResult::Accepted);
    let failure = failure_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert_eq!(failure.delivery, PtyOperationDelivery::Ambiguous);
    assert!(failure.lane_failed);
    assert_eq!(failure.label, "PTY input");

    mux.shutdown();
}

fn mutation_with_retained_bytes(retained_bytes: usize) -> PtyInputEvent {
    PtyInputEvent::mutation_for_surface(
        "retained payload",
        PtyMutationIdentity { retained_bytes, ..Default::default() },
        false,
        None,
        None,
        || Ok(()),
    )
}

#[test]
fn consecutive_motion_on_one_surface_keeps_latest() {
    let mut events = VecDeque::new();
    let mut queued_bytes = 0;
    let mut releases = ReleaseReservations::default();
    assert!(enqueue_bounded(
        &mut events,
        &mut queued_bytes,
        &mut releases,
        event(1, 1, PtyInputKind::Motion),
        8,
        1024,
    ));
    assert!(enqueue_bounded(
        &mut events,
        &mut queued_bytes,
        &mut releases,
        event(1, 2, PtyInputKind::Motion),
        8,
        1024,
    ));
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].bytes.as_slice(), &[2]);
}

#[test]
fn bounded_queue_reports_evicted_motion_as_known_not_delivered() {
    let mut events = VecDeque::new();
    let mut queued_bytes = 0;
    let mut releases = ReleaseReservations::default();
    assert!(enqueue_bounded(
        &mut events,
        &mut queued_bytes,
        &mut releases,
        event(7, 1, PtyInputKind::Motion),
        1,
        1024,
    ));

    let outcome = enqueue_bounded_with_evictions(
        &mut events,
        &mut queued_bytes,
        &mut releases,
        event(8, 2, PtyInputKind::Ordered),
        1,
        1024,
    );

    assert!(outcome.accepted);
    assert_eq!(outcome.evicted.len(), 1);
    assert_eq!(outcome.evicted[0].surface_id, Some(7));
    assert_eq!(outcome.evicted[0].kind, Some(PtyInputKind::Motion));
    assert_eq!(outcome.evicted[0].delivery, PtyOperationDelivery::KnownNotDelivered);
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].surface_id, 8);
}

#[test]
fn sender_emits_failure_when_bounded_queue_evicts_motion() {
    let (failure_tx, failure_rx) = std::sync::mpsc::channel();
    let (started_tx, started_rx) = std::sync::mpsc::channel();
    let (unblock_tx, unblock_rx) = std::sync::mpsc::channel();
    let dispatcher = PtyInputDispatcher::spawn(move |failure| {
        failure_tx.send(failure).unwrap();
    })
    .unwrap();
    let sender = dispatcher.sender();
    sender.enqueue_session_mutation("blocker", false, move || {
        started_tx.send(()).unwrap();
        unblock_rx.recv().unwrap();
        Ok(())
    });
    started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert_eq!(sender.enqueue(event(7, 1, PtyInputKind::Motion)), PtyInputEnqueueResult::Accepted);
    for _ in 0..PTY_OPERATION_QUEUE_CAPACITY - 1 {
        assert_eq!(
            sender.enqueue(PtyInputEvent::mutation("fill", None, false, || Ok(()))),
            PtyInputEnqueueResult::Accepted
        );
    }

    assert_eq!(
        sender.enqueue(PtyInputEvent::mutation("overflow", None, false, || Ok(()))),
        PtyInputEnqueueResult::Accepted
    );
    let failure = failure_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert_eq!(failure.surface_id, Some(7));
    assert_eq!(failure.kind, Some(PtyInputKind::Motion));
    assert_eq!(failure.delivery, PtyOperationDelivery::KnownNotDelivered);

    unblock_tx.send(()).unwrap();
}

#[test]
fn ordered_bytes_batch_without_crossing_motion_or_surfaces() {
    let mut events = VecDeque::new();
    let mut queued_bytes = 0;
    let mut releases = ReleaseReservations::default();
    for item in [
        event(1, 1, PtyInputKind::Ordered),
        event(1, 2, PtyInputKind::Ordered),
        event(1, 3, PtyInputKind::Motion),
        event(2, 4, PtyInputKind::Ordered),
    ] {
        assert!(enqueue_bounded(&mut events, &mut queued_bytes, &mut releases, item, 8, 1024,));
    }
    assert_eq!(events.len(), 3);
    assert_eq!(events[0].bytes.as_slice(), &[1, 2]);
    assert!(!events[0].bytes.spilled());
    assert_eq!(events[1].bytes.as_slice(), &[3]);
    assert_eq!(events[2].bytes.as_slice(), &[4]);
}

#[test]
fn ordered_input_does_not_cross_a_session_mutation() {
    let mut events = VecDeque::new();
    let mut queued_bytes = 0;
    let mut releases = ReleaseReservations::default();
    assert!(enqueue_bounded(
        &mut events,
        &mut queued_bytes,
        &mut releases,
        event(1, 1, PtyInputKind::Ordered),
        8,
        1024,
    ));
    assert!(enqueue_bounded(
        &mut events,
        &mut queued_bytes,
        &mut releases,
        PtyInputEvent::mutation("close tab", None, false, || Ok(())),
        8,
        1024,
    ));
    assert!(enqueue_bounded(
        &mut events,
        &mut queued_bytes,
        &mut releases,
        event(1, 2, PtyInputKind::Ordered),
        8,
        1024,
    ));

    assert_eq!(events.len(), 3);
    assert_eq!(events[0].bytes.as_slice(), &[1]);
    assert_eq!(events[1].kind, PtyInputKind::Mutation);
    assert_eq!(events[2].bytes.as_slice(), &[2]);
}

#[test]
fn surface_operation_failure_keeps_its_surface_identity() {
    let (failure_tx, failure_rx) = std::sync::mpsc::channel();
    let dispatcher = PtyInputDispatcher::spawn(move |failure| {
        failure_tx.send(failure).unwrap();
    })
    .unwrap();

    assert_eq!(
        dispatcher.sender().enqueue_coalescing_surface_operation(
            "clear terminal history",
            42,
            false,
            || Err(anyhow::anyhow!("clear failed")),
        ),
        PtyInputEnqueueResult::Accepted
    );

    let failure = failure_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert_eq!(failure.surface_id, Some(42));
    assert_eq!(failure.kind, None);
    assert_eq!(failure.label, "clear terminal history");
    assert_eq!(failure.delivery, PtyOperationDelivery::Ambiguous);
}

#[test]
fn ambiguous_surface_operation_quarantines_only_its_surface() {
    let queue = Arc::new(SharedQueue::default());
    {
        let mut state = queue.state.lock().unwrap();
        state.events.push_back(event(41, 1, PtyInputKind::Ordered));
        state.events.push_back(event(42, 2, PtyInputKind::Ordered));
        state.queued_bytes = 2;
        state.in_flight_surface_operations.insert(lane(41), 0);
    }
    let failures = Arc::new(Mutex::new(Vec::new()));
    let captured_failures = failures.clone();
    let on_failure: Arc<dyn Fn(PtyOperationFailure) + Send + Sync> =
        Arc::new(move |failure| captured_failures.lock().unwrap().push(failure));
    let operation = PtyInputEvent::mutation_for_surface(
        "clear terminal history",
        PtyMutationIdentity {
            failure_surface_id: Some(41),
            concurrent_surface_operation: true,
            ..Default::default()
        },
        false,
        None,
        None,
        || Err(anyhow::anyhow!("partial fallback write")),
    );

    process_event(queue.clone(), on_failure.clone(), operation);

    {
        let state = queue.state.lock().unwrap();
        assert_eq!(
            state.events.iter().map(PtyInputEvent::ordering_surface_id).collect::<Vec<_>>(),
            vec![Some(42)],
            "same-surface input survived an ambiguous surface operation"
        );
        assert!(!state.in_flight_surface_operations.contains_key(&lane(41)));
    }
    let sender = PtyInputSender { queue, on_failure, session_generation: 1 };
    assert_eq!(
        sender.enqueue(event(41, 3, PtyInputKind::Ordered)),
        PtyInputEnqueueResult::Failed,
        "new same-surface input entered an ambiguous lane"
    );
    assert_eq!(
        sender.enqueue(event(42, 4, PtyInputKind::Ordered)),
        PtyInputEnqueueResult::Accepted,
        "an unrelated surface was quarantined"
    );

    let failures = failures.lock().unwrap();
    assert!(failures.iter().any(|failure| {
        failure.surface_id == Some(41)
            && failure.label == "clear terminal history"
            && failure.delivery == PtyOperationDelivery::Ambiguous
            && failure.lane_failed
    }));
    assert!(failures.iter().any(|failure| {
        failure.surface_id == Some(41)
            && failure.delivery == PtyOperationDelivery::KnownNotDelivered
            && failure.lane_failed
    }));
}

#[test]
fn blocking_surface_operation_is_a_per_surface_barrier() {
    let dispatcher = PtyInputDispatcher::spawn(|_| {}).unwrap();
    let sender = dispatcher.sender();
    let (started_tx, started_rx) = std::sync::mpsc::channel();
    let (unblock_tx, unblock_rx) = std::sync::mpsc::channel();
    let (same_surface_tx, same_surface_rx) = std::sync::mpsc::channel();
    let (other_surface_tx, other_surface_rx) = std::sync::mpsc::channel();

    assert_eq!(
        sender.enqueue_surface_operation_with_retained_bytes(
            "blocking surface operation",
            41,
            false,
            0,
            move || {
                started_tx.send(()).unwrap();
                let _ = unblock_rx.recv();
                Ok(())
            },
        ),
        PtyInputEnqueueResult::Accepted
    );
    started_rx.recv_timeout(Duration::from_secs(1)).unwrap();

    let mut same_surface = event(41, 1, PtyInputKind::Ordered);
    same_surface.after_operation = Some(Box::new(move || same_surface_tx.send(()).unwrap()));
    assert_eq!(sender.enqueue(same_surface), PtyInputEnqueueResult::Accepted);

    let mut other_surface = event(42, 2, PtyInputKind::Ordered);
    other_surface.after_operation = Some(Box::new(move || other_surface_tx.send(()).unwrap()));
    assert_eq!(sender.enqueue(other_surface), PtyInputEnqueueResult::Accepted);

    other_surface_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert!(same_surface_rx.recv_timeout(Duration::from_millis(50)).is_err());

    unblock_tx.send(()).unwrap();
    same_surface_rx.recv_timeout(Duration::from_secs(1)).unwrap();
}

#[test]
fn replacement_generation_isolates_a_reused_surface_lane() {
    let (failure_tx, failure_rx) = std::sync::mpsc::channel();
    let mut dispatcher = PtyInputDispatcher::spawn(move |failure| {
        failure_tx.send(failure).unwrap();
    })
    .unwrap();
    let old_sender = dispatcher.sender();
    let (old_started_tx, old_started_rx) = std::sync::mpsc::channel();
    let (old_release_tx, old_release_rx) = std::sync::mpsc::channel();

    assert_eq!(
        old_sender.enqueue_surface_operation_with_retained_bytes(
            "old session operation",
            41,
            false,
            0,
            move || {
                old_started_tx.send(()).unwrap();
                old_release_rx.recv().unwrap();
                Err(anyhow::anyhow!("ambiguous old session completion"))
            },
        ),
        PtyInputEnqueueResult::Accepted
    );
    old_started_rx.recv_timeout(Duration::from_secs(1)).unwrap();

    dispatcher.activate_session_generation(2);
    let new_sender = dispatcher.sender();
    assert_eq!(
        old_sender.enqueue(event(41, 1, PtyInputKind::Ordered)),
        PtyInputEnqueueResult::Failed,
        "a retired session sender remained active"
    );

    let (new_started_tx, new_started_rx) = std::sync::mpsc::channel();
    let (new_release_tx, new_release_rx) = std::sync::mpsc::channel();
    assert_eq!(
        new_sender.enqueue_surface_operation_with_retained_bytes(
            "new session operation",
            41,
            false,
            0,
            move || {
                new_started_tx.send(()).unwrap();
                new_release_rx.recv().unwrap();
                Ok(())
            },
        ),
        PtyInputEnqueueResult::Accepted
    );
    new_started_rx.recv_timeout(Duration::from_secs(1)).unwrap();

    let (follower_tx, follower_rx) = std::sync::mpsc::channel();
    let mut follower = event(41, 2, PtyInputKind::Ordered);
    follower.after_operation = Some(Box::new(move || follower_tx.send(()).unwrap()));
    assert_eq!(new_sender.enqueue(follower), PtyInputEnqueueResult::Accepted);

    old_release_tx.send(()).unwrap();
    let old_failure = failure_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert_eq!(old_failure.session_generation, 1);
    assert!(old_failure.lane_failed);
    assert!(
        follower_rx.recv_timeout(Duration::from_millis(50)).is_err(),
        "new-session input crossed its own surface barrier"
    );

    new_release_tx.send(()).unwrap();
    follower_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert!(dispatcher.shutdown(Duration::from_secs(1)));
}

#[test]
fn concurrent_surface_operations_respect_worker_cap() {
    const EXPECTED_MAX_CONCURRENT_SURFACE_OPERATIONS: usize = 32;
    let mut state = QueueState::default();
    for surface in 1..=(EXPECTED_MAX_CONCURRENT_SURFACE_OPERATIONS as u64 + 1) {
        state.events.push_back(PtyInputEvent::mutation_for_surface(
            "blocking surface operation",
            PtyMutationIdentity {
                failure_surface_id: Some(surface),
                concurrent_surface_operation: true,
                ..Default::default()
            },
            false,
            None,
            None,
            || Ok(()),
        ));
    }

    for _ in 0..EXPECTED_MAX_CONCURRENT_SURFACE_OPERATIONS {
        assert!(dequeue_ready_event(&mut state).is_some());
    }
    assert!(
        dequeue_ready_event(&mut state).is_none(),
        "surface operation scheduler exceeded its worker cap"
    );
}

#[test]
fn saturated_worker_cap_preserves_the_queued_surface_barrier() {
    let mut state = QueueState::default();
    for surface in 1..=MAX_CONCURRENT_SURFACE_OPERATIONS as u64 {
        state.in_flight_surface_operations.insert(lane(surface), 0);
    }
    state.events.push_back(PtyInputEvent::mutation_for_surface(
        "queued clear history",
        PtyMutationIdentity {
            failure_surface_id: Some(100),
            concurrent_surface_operation: true,
            ..Default::default()
        },
        false,
        None,
        None,
        || Ok(()),
    ));
    state.events.push_back(event(100, 1, PtyInputKind::Ordered));
    state.events.push_back(event(101, 2, PtyInputKind::Ordered));
    state.queued_bytes = state.events.iter().map(PtyInputEvent::queued_byte_len).sum();

    let ready = dequeue_ready_event(&mut state).unwrap();

    assert_eq!(
        ready.ordering_lane(),
        Some(lane(101)),
        "same-surface input overtook the clear blocked on worker capacity"
    );
    assert_eq!(
        state.events.iter().map(PtyInputEvent::ordering_lane).collect::<Vec<_>>(),
        vec![Some(lane(100)), Some(lane(100))]
    );
}

#[test]
fn in_flight_surface_operation_counts_against_byte_budget() {
    let dispatcher = PtyInputDispatcher::spawn(|_| {}).unwrap();
    let sender = dispatcher.sender();
    let (started_tx, started_rx) = std::sync::mpsc::channel();
    let (unblock_tx, unblock_rx) = std::sync::mpsc::channel();

    assert_eq!(
        sender.enqueue_surface_operation_with_retained_bytes(
            "retained surface operation",
            41,
            false,
            MAX_QUEUED_BYTES,
            move || {
                started_tx.send(()).unwrap();
                let _ = unblock_rx.recv();
                Ok(())
            },
        ),
        PtyInputEnqueueResult::Accepted
    );
    started_rx.recv_timeout(Duration::from_secs(1)).unwrap();

    assert_eq!(
        sender.enqueue(event(42, 1, PtyInputKind::Ordered)),
        PtyInputEnqueueResult::Saturated
    );
    unblock_tx.send(()).unwrap();
}

#[test]
fn session_mutation_blocks_later_input_behind_surface_operation() {
    let dispatcher = PtyInputDispatcher::spawn(|_| {}).unwrap();
    let sender = dispatcher.sender();
    let (started_tx, started_rx) = std::sync::mpsc::channel();
    let (unblock_tx, unblock_rx) = std::sync::mpsc::channel();
    let (order_tx, order_rx) = std::sync::mpsc::channel();

    assert_eq!(
        sender.enqueue_surface_operation_with_retained_bytes(
            "blocking surface operation",
            41,
            false,
            0,
            move || {
                started_tx.send(()).unwrap();
                let _ = unblock_rx.recv();
                Ok(())
            },
        ),
        PtyInputEnqueueResult::Accepted
    );
    started_rx.recv_timeout(Duration::from_secs(1)).unwrap();

    let mutation_tx = order_tx.clone();
    sender.enqueue_session_mutation("close pane", false, move || {
        mutation_tx.send("mutation").unwrap();
        Ok(())
    });
    let mut input = event(42, 1, PtyInputKind::Ordered);
    input.after_operation = Some(Box::new(move || order_tx.send("input").unwrap()));
    assert_eq!(sender.enqueue(input), PtyInputEnqueueResult::Accepted);

    assert!(
        order_rx.recv_timeout(Duration::from_millis(50)).is_err(),
        "input overtook the earlier session mutation"
    );
    unblock_tx.send(()).unwrap();
    assert_eq!(order_rx.recv_timeout(Duration::from_secs(1)).unwrap(), "mutation");
    assert_eq!(order_rx.recv_timeout(Duration::from_secs(1)).unwrap(), "input");
}

#[test]
fn timed_out_surface_operation_prunes_only_its_surface() {
    let (failure_tx, failure_rx) = std::sync::mpsc::channel();
    let mut dispatcher = PtyInputDispatcher::spawn(move |failure| {
        let _ = failure_tx.send(failure);
    })
    .unwrap();
    let sender = dispatcher.sender();
    let (started_tx, started_rx) = std::sync::mpsc::channel();
    let (unblock_tx, unblock_rx) = std::sync::mpsc::channel();
    let (same_surface_tx, same_surface_rx) = std::sync::mpsc::channel();
    let (other_surface_tx, other_surface_rx) = std::sync::mpsc::channel();

    assert_eq!(
        sender.enqueue_surface_operation_with_retained_bytes(
            "timed out surface operation",
            41,
            true,
            0,
            move || {
                started_tx.send(()).unwrap();
                let _ = unblock_rx.recv();
                Err(crate::session::test_remote_timeout_error())
            },
        ),
        PtyInputEnqueueResult::Accepted
    );
    started_rx.recv_timeout(Duration::from_secs(1)).unwrap();

    let mut same_surface = event(41, 1, PtyInputKind::Ordered);
    same_surface.remote = true;
    same_surface.after_operation = Some(Box::new(move || same_surface_tx.send(()).unwrap()));
    assert_eq!(sender.enqueue(same_surface), PtyInputEnqueueResult::Accepted);

    let mut other_surface = event(42, 2, PtyInputKind::Ordered);
    other_surface.remote = true;
    other_surface.after_operation = Some(Box::new(move || other_surface_tx.send(()).unwrap()));
    assert_eq!(sender.enqueue(other_surface), PtyInputEnqueueResult::Accepted);

    other_surface_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    unblock_tx.send(()).unwrap();
    assert!(dispatcher.shutdown(Duration::from_secs(1)));
    assert!(same_surface_rx.recv_timeout(Duration::from_millis(50)).is_err());

    let failures = failure_rx.try_iter().collect::<Vec<_>>();
    assert!(failures.iter().any(|failure| {
        failure.surface_id == Some(41)
            && failure.label == "timed out surface operation"
            && failure.delivery == PtyOperationDelivery::Ambiguous
    }));
    assert!(failures.iter().any(|failure| {
        failure.surface_id == Some(41)
            && failure.label == "PTY input"
            && failure.delivery == PtyOperationDelivery::KnownNotDelivered
    }));
    assert!(!failures.iter().any(|failure| {
        failure.surface_id == Some(42)
            && failure.error.contains("canceled after a remote surface request timed out")
    }));
}

#[test]
fn coalescing_mutations_replace_by_key_across_adjacent_resize_work() {
    let mut events = VecDeque::new();
    let mut queued_bytes = 0;
    let mut releases = ReleaseReservations::default();
    for item in [
        PtyInputEvent::mutation("resize one", Some(("resize", 1, 0)), false, || Ok(())),
        PtyInputEvent::mutation("resize two", Some(("resize", 2, 0)), false, || Ok(())),
        PtyInputEvent::mutation("resize one latest", Some(("resize", 1, 0)), false, || Ok(())),
    ] {
        assert!(enqueue_bounded(&mut events, &mut queued_bytes, &mut releases, item, 8, 1024));
    }

    assert_eq!(events.len(), 2);
    assert_eq!(events[0].label, "resize two");
    assert_eq!(events[1].label, "resize one latest");

    assert!(enqueue_bounded(
        &mut events,
        &mut queued_bytes,
        &mut releases,
        event(1, 1, PtyInputKind::Ordered),
        8,
        1024,
    ));
    assert!(enqueue_bounded(
        &mut events,
        &mut queued_bytes,
        &mut releases,
        PtyInputEvent::mutation("resize after input", Some(("resize", 1, 0)), false, || Ok(()),),
        8,
        1024,
    ));
    assert_eq!(events.len(), 4);
}

#[test]
fn retained_mutation_payload_counts_toward_the_byte_limit() {
    let mut events = VecDeque::new();
    let mut queued_bytes = 0;
    let mut releases = ReleaseReservations::default();

    assert!(enqueue_bounded(
        &mut events,
        &mut queued_bytes,
        &mut releases,
        mutation_with_retained_bytes(6),
        8,
        10,
    ));
    assert!(!enqueue_bounded(
        &mut events,
        &mut queued_bytes,
        &mut releases,
        mutation_with_retained_bytes(5),
        8,
        10,
    ));

    assert_eq!(queued_bytes, 6);
    assert_eq!(events.len(), 1);
}

#[test]
fn coalescing_mutations_distinguish_both_subject_ids() {
    let mut events = VecDeque::new();
    let mut queued_bytes = 0;
    let mut releases = ReleaseReservations::default();
    for item in [
        PtyInputEvent::mutation("surface 7 client 1", Some(("sizing", 7, 1)), false, || Ok(())),
        PtyInputEvent::mutation("surface 7 client 2", Some(("sizing", 7, 2)), false, || Ok(())),
        PtyInputEvent::mutation("surface 8 client 1", Some(("sizing", 8, 1)), false, || Ok(())),
        PtyInputEvent::mutation("surface 7 client 1 latest", Some(("sizing", 7, 1)), false, || {
            Ok(())
        }),
    ] {
        assert!(enqueue_bounded(&mut events, &mut queued_bytes, &mut releases, item, 8, 1024));
    }

    assert_eq!(events.len(), 3);
    assert_eq!(events[0].label, "surface 7 client 2");
    assert_eq!(events[1].label, "surface 8 client 1");
    assert_eq!(events[2].label, "surface 7 client 1 latest");
}

#[test]
fn coalescing_mutation_reports_the_replaced_sample_as_superseded() {
    let mut events = VecDeque::new();
    let mut queued_bytes = 0;
    let mut releases = ReleaseReservations::default();
    let superseded = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let replaced = superseded.clone();
    assert!(enqueue_bounded(
        &mut events,
        &mut queued_bytes,
        &mut releases,
        PtyInputEvent::mutation_with_superseded(
            "resize old",
            Some(("resize", 1, 0)),
            false,
            Some(Box::new(move || {
                replaced.store(true, std::sync::atomic::Ordering::Release);
            })),
            None,
            || Ok(()),
        ),
        8,
        1024,
    ));
    assert!(enqueue_bounded(
        &mut events,
        &mut queued_bytes,
        &mut releases,
        PtyInputEvent::mutation("resize latest", Some(("resize", 1, 0)), false, || Ok(())),
        8,
        1024,
    ));

    assert!(superseded.load(std::sync::atomic::Ordering::Acquire));
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].label, "resize latest");
}

#[test]
fn rejected_coalescing_replacement_restores_the_previous_sample() {
    let mut events = VecDeque::new();
    let mut queued_bytes = 0;
    let mut releases = ReleaseReservations::default();
    let superseded = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let replaced = superseded.clone();
    let mut previous = PtyInputEvent::mutation_with_superseded(
        "resize old",
        Some(("resize", 1, 0)),
        false,
        Some(Box::new(move || {
            replaced.store(true, std::sync::atomic::Ordering::Release);
        })),
        None,
        || Ok(()),
    );
    previous.bytes = PtyInputBytes::from_slice(&[1]);
    assert!(enqueue_bounded(&mut events, &mut queued_bytes, &mut releases, previous, 8, 1,));

    let mut too_large =
        PtyInputEvent::mutation("resize latest", Some(("resize", 1, 0)), false, || Ok(()));
    too_large.bytes = PtyInputBytes::from_slice(&[2, 3]);
    assert!(!enqueue_bounded(&mut events, &mut queued_bytes, &mut releases, too_large, 8, 1,));

    assert!(!superseded.load(std::sync::atomic::Ordering::Acquire));
    assert_eq!(queued_bytes, 1);
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].label, "resize old");
    assert_eq!(events[0].bytes.as_slice(), &[1]);
}

#[test]
fn accepted_press_guarantees_its_release_slot() {
    let mut events = VecDeque::new();
    let mut queued_bytes = 0;
    let mut releases = ReleaseReservations::default();
    assert!(enqueue_bounded(
        &mut events,
        &mut queued_bytes,
        &mut releases,
        event(1, 1, PtyInputKind::Press),
        3,
        1024,
    ));
    assert_eq!(releases.len(), 1);
    assert!(enqueue_bounded(
        &mut events,
        &mut queued_bytes,
        &mut releases,
        event(2, 2, PtyInputKind::Ordered),
        3,
        1024,
    ));
    assert!(!enqueue_bounded(
        &mut events,
        &mut queued_bytes,
        &mut releases,
        event(3, 3, PtyInputKind::Ordered),
        3,
        1024,
    ));
    assert!(enqueue_bounded(
        &mut events,
        &mut queued_bytes,
        &mut releases,
        event(1, 4, PtyInputKind::Release),
        3,
        1024,
    ));
    assert_eq!(releases.len(), 0);
    assert_eq!(events.len(), 3);
    assert_eq!(events.back().unwrap().bytes.as_slice(), &[4]);
}

#[test]
fn failed_consumed_press_does_not_cancel_a_newer_reservation() {
    let mut reservations = ReleaseReservations::default();
    let first = reservations.reserve(lane(7));
    assert!(reservations.consume(lane(7)));
    let second = reservations.reserve(lane(7));

    reservations.outstanding.remove(&first);

    assert_eq!(reservations.len(), 1);
    assert!(reservations.outstanding.contains_key(&second));
}

#[test]
fn release_consumes_only_its_exact_reservation() {
    let mut events = VecDeque::new();
    let mut queued_bytes = 0;
    let mut releases = ReleaseReservations::default();
    assert!(enqueue_bounded(
        &mut events,
        &mut queued_bytes,
        &mut releases,
        event(7, 1, PtyInputKind::Press),
        8,
        1024,
    ));
    let first = releases.next_id;
    assert!(enqueue_bounded(
        &mut events,
        &mut queued_bytes,
        &mut releases,
        event(7, 2, PtyInputKind::Press),
        8,
        1024,
    ));
    let second = releases.next_id;

    let mut release = event(7, 3, PtyInputKind::Release);
    release.reservation_id = Some(first);
    assert!(enqueue_bounded(&mut events, &mut queued_bytes, &mut releases, release, 8, 1024,));

    assert!(!releases.outstanding.contains_key(&first));
    assert_eq!(releases.outstanding.get(&second), Some(&lane(7)));
}

#[test]
fn ordered_batch_respects_byte_budget() {
    let mut events = VecDeque::new();
    let mut queued_bytes = 0;
    let mut releases = ReleaseReservations::default();
    let mut first = event(1, 1, PtyInputKind::Ordered);
    first.bytes = vec![1; 8].into();
    assert!(enqueue_bounded(&mut events, &mut queued_bytes, &mut releases, first, 8, 10,));
    let mut overflow = event(1, 2, PtyInputKind::Ordered);
    overflow.bytes = vec![2; 3].into();
    assert!(!enqueue_bounded(&mut events, &mut queued_bytes, &mut releases, overflow, 8, 10,));
    assert_eq!(queued_bytes, 8);
}

#[test]
fn shutdown_drains_and_joins_the_worker() {
    let mut dispatcher = PtyInputDispatcher::spawn(|_| {}).unwrap();
    assert_eq!(
        dispatcher.enqueue(event(1, 1, PtyInputKind::Ordered)),
        PtyInputEnqueueResult::Accepted
    );
    assert!(dispatcher.shutdown(Duration::from_secs(1)));
}

#[test]
fn shutdown_retains_release_for_worker_behind_in_flight_operation() {
    let queue = Arc::new(SharedQueue::default());
    let released = Arc::new(std::sync::atomic::AtomicBool::new(false));
    {
        let mut state = queue.state.lock().unwrap();
        state.events.push_back(event(1, 1, PtyInputKind::Motion));
        let released_flag = released.clone();
        let mut release = event(1, 2, PtyInputKind::Release);
        release.reservation_id = Some(7);
        release.mutation = Some(Box::new(move || {
            released_flag.store(true, std::sync::atomic::Ordering::Release);
            Ok(())
        }));
        state.events.push_back(release);
        state.queued_bytes = 2;
        state.in_flight = Some(InFlightInput { lane: Some(lane(2)), kind: PtyInputKind::Ordered });
    }
    let mut dispatcher = PtyInputDispatcher {
        sender: PtyInputSender {
            queue: queue.clone(),
            on_failure: Arc::new(|_| {}),
            session_generation: 1,
        },
        worker: None,
    };

    assert!(!dispatcher.shutdown(Duration::ZERO));

    let state = queue.state.lock().unwrap();
    assert!(state.closed);
    assert_eq!(state.events.len(), 1);
    assert_eq!(state.queued_bytes, 1);
    assert_eq!(state.release_reservations.len(), 0);
    assert!(!released.load(std::sync::atomic::Ordering::Acquire));
}

#[test]
fn shutdown_waits_for_worker_ordered_release_after_response_wait_is_canceled() {
    let (line_tx, line_rx) = std::sync::mpsc::channel();
    let (cancel_tx, cancel_rx) = std::sync::mpsc::channel();
    let mut dispatcher = PtyInputDispatcher::spawn(|_| {}).unwrap();
    dispatcher.sender().enqueue_session_mutation("in flight", true, move || {
        line_tx.send("request").unwrap();
        cancel_rx.recv().unwrap();
        Ok(())
    });
    assert_eq!(line_rx.recv_timeout(Duration::from_secs(1)).unwrap(), "request");

    let released = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let released_flag = released.clone();
    let mut release = event(1, 2, PtyInputKind::Release);
    release.mutation = Some(Box::new(move || {
        released_flag.store(true, std::sync::atomic::Ordering::Release);
        Ok(())
    }));
    assert_eq!(dispatcher.enqueue(release), PtyInputEnqueueResult::Accepted);

    let shutdown = std::thread::spawn(move || dispatcher.shutdown(Duration::from_secs(1)));
    cancel_tx.send(()).unwrap();
    assert!(shutdown.join().unwrap());
    assert!(released.load(std::sync::atomic::Ordering::Acquire));
}

#[test]
fn shutdown_closes_enqueue_then_drains_accepted_fifo_work() {
    let (started_tx, started_rx) = std::sync::mpsc::channel();
    let (unblock_tx, unblock_rx) = std::sync::mpsc::channel();
    let order = Arc::new(Mutex::new(Vec::new()));
    let mut dispatcher = PtyInputDispatcher::spawn(|_| {}).unwrap();
    let sender = dispatcher.sender();
    let first_order = order.clone();
    sender.enqueue_session_mutation("first", false, move || {
        started_tx.send(()).unwrap();
        unblock_rx.recv().unwrap();
        first_order.lock().unwrap().push(1);
        Ok(())
    });
    started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    let second_order = order.clone();
    sender.enqueue_session_mutation("second", false, move || {
        second_order.lock().unwrap().push(2);
        Ok(())
    });

    let queue = dispatcher.sender.queue.clone();
    let shutdown = std::thread::spawn(move || dispatcher.shutdown(Duration::from_secs(1)));
    while !queue.state.lock().unwrap().closed {
        std::thread::yield_now();
    }
    assert_eq!(
        sender.enqueue(event(1, 3, PtyInputKind::Ordered)),
        PtyInputEnqueueResult::Saturated
    );
    unblock_tx.send(()).unwrap();

    assert!(shutdown.join().unwrap());
    assert_eq!(*order.lock().unwrap(), vec![1, 2]);
}

#[test]
fn recovery_prune_drops_release_paired_with_a_canceled_queued_press() {
    let mut state = QueueState::default();
    let mut press = event(7, 1, PtyInputKind::Press);
    press.reservation_id = Some(11);
    let mut paired_release = event(7, 2, PtyInputKind::Release);
    paired_release.reservation_id = Some(11);
    let mut ambiguous_release = event(7, 3, PtyInputKind::Release);
    ambiguous_release.reservation_id = Some(12);
    state.events = VecDeque::from([press, paired_release, ambiguous_release]);
    state.queued_bytes = 3;
    state.release_reservations.outstanding.insert(11, lane(7));

    let canceled = prune_to_recovery_releases(&mut state, 1, "timed out");

    assert_eq!(canceled.len(), 2);
    assert_eq!(state.events.len(), 1);
    assert_eq!(state.events[0].reservation_id, Some(12));
    assert_eq!(state.queued_bytes, 1);
    assert!(!state.release_reservations.outstanding.contains_key(&11));
}

#[test]
fn shutdown_timeout_discards_backlog_without_an_in_flight_press() {
    let queue = Arc::new(SharedQueue::default());
    {
        let mut state = queue.state.lock().unwrap();
        state.events.push_back(event(1, 1, PtyInputKind::Ordered));
        state.queued_bytes = 1;
        state.in_flight = Some(InFlightInput { lane: Some(lane(1)), kind: PtyInputKind::Ordered });
    }
    let mut dispatcher = PtyInputDispatcher {
        sender: PtyInputSender {
            queue: queue.clone(),
            on_failure: Arc::new(|_| {}),
            session_generation: 1,
        },
        worker: None,
    };

    assert!(!dispatcher.shutdown(Duration::ZERO));

    let state = queue.state.lock().unwrap();
    assert!(state.events.is_empty());
    assert!(state.shutdown_release_drain);
}

#[test]
fn accepted_operation_completes_before_following_mutation_without_blocking_enqueue() {
    let dispatcher = PtyInputDispatcher::spawn(|_| {}).unwrap();
    let sender = dispatcher.sender();
    let mutated = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let (started_tx, started_rx) = std::sync::mpsc::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    sender.enqueue_session_mutation("blocking operation", false, move || {
        started_tx.send(()).unwrap();
        release_rx.recv().unwrap();
        Ok(())
    });
    let mutation = mutated.clone();
    sender.enqueue_session_mutation("following mutation", false, move || {
        mutation.store(true, std::sync::atomic::Ordering::Release);
        Ok(())
    });

    started_rx.recv().unwrap();
    assert!(!mutated.load(std::sync::atomic::Ordering::Acquire));
    release_tx.send(()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(1);
    while !mutated.load(std::sync::atomic::Ordering::Acquire) && Instant::now() < deadline {
        std::thread::yield_now();
    }
    assert!(mutated.load(std::sync::atomic::Ordering::Acquire));
}

#[test]
fn operation_failure_is_reported() {
    let (failure_tx, failure_rx) = std::sync::mpsc::channel();
    let dispatcher = PtyInputDispatcher::spawn(move |failure| {
        failure_tx.send(failure).unwrap();
    })
    .unwrap();

    dispatcher
        .sender()
        .enqueue_session_mutation("close pane", false, || anyhow::bail!("write failed"));

    let failure = failure_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert_eq!(failure.label, "close pane");
    assert_eq!(failure.error, "write failed");
}

#[test]
fn remote_mutation_timeout_is_reported_only_by_its_session_outcome() {
    let (failure_tx, failure_rx) = std::sync::mpsc::channel();
    let dispatcher = PtyInputDispatcher::spawn(move |failure| {
        failure_tx.send(failure).unwrap();
    })
    .unwrap();

    dispatcher.sender().enqueue_session_mutation("timed out mutation", true, || {
        Err(crate::session::test_remote_timeout_error())
    });

    assert!(failure_rx.recv_timeout(Duration::from_millis(100)).is_err());
}

#[test]
fn pty_write_failure_is_reported_with_its_surface() {
    let (failure_tx, failure_rx) = std::sync::mpsc::channel();
    let dispatcher = PtyInputDispatcher::spawn(move |failure| {
        failure_tx.send(failure).unwrap();
    })
    .unwrap();

    assert_eq!(
        dispatcher.enqueue(event(42, 1, PtyInputKind::Ordered)),
        PtyInputEnqueueResult::Accepted
    );

    let failure = failure_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert_eq!(failure.surface_id, Some(42));
    assert_eq!(failure.kind, Some(PtyInputKind::Ordered));
    assert_eq!(failure.label, "PTY input");
    assert!(failure.error.contains("browser surface"));
}

#[test]
fn failed_press_releases_its_reserved_queue_slot() {
    let (failure_tx, failure_rx) = std::sync::mpsc::channel();
    let dispatcher = PtyInputDispatcher::spawn(move |failure| {
        failure_tx.send(failure).unwrap();
    })
    .unwrap();

    assert_eq!(
        dispatcher.enqueue(event(7, 1, PtyInputKind::Press)),
        PtyInputEnqueueResult::Accepted
    );
    let failure = failure_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert_eq!(failure.delivery, PtyOperationDelivery::KnownNotDelivered);
    assert_eq!(dispatcher.sender.queue.state.lock().unwrap().release_reservations.len(), 0);
}

#[test]
fn timed_out_remote_press_keeps_its_release_reservation() {
    let (failure_tx, failure_rx) = std::sync::mpsc::channel();
    let dispatcher = PtyInputDispatcher::spawn(move |failure| {
        failure_tx.send(failure).unwrap();
    })
    .unwrap();
    let mut press = event(7, 1, PtyInputKind::Press);
    press.remote = true;
    press.mutation = Some(Box::new(|| Err(crate::session::test_remote_timeout_error())));

    let (result, reservation_id) = dispatcher.enqueue_with_reservation(press);
    assert_eq!(result, PtyInputEnqueueResult::Accepted);
    assert!(reservation_id.is_some());
    let failure = failure_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert_eq!(failure.delivery, PtyOperationDelivery::Ambiguous);
    assert_eq!(failure.reservation_id, reservation_id);
    assert_eq!(dispatcher.sender.queue.state.lock().unwrap().release_reservations.len(), 1);

    assert_eq!(
        dispatcher.enqueue(event(7, 2, PtyInputKind::Release)),
        PtyInputEnqueueResult::Accepted
    );
    assert_eq!(dispatcher.sender.queue.state.lock().unwrap().release_reservations.len(), 0);
}

#[test]
fn ambiguous_local_press_keeps_its_recovery_release_reservation() {
    let (failure_tx, failure_rx) = std::sync::mpsc::channel();
    let mut dispatcher = PtyInputDispatcher::spawn(move |failure| {
        failure_tx.send(failure).unwrap();
    })
    .unwrap();
    let mux = cmux_tui_core::Mux::new(
        "ambiguous-local-press-recovery-test",
        cmux_tui_core::SurfaceOptions::default(),
    );
    let surface = mux.new_workspace(None, Some((20, 8))).unwrap();
    let handle = SurfaceHandle::Local(surface.clone(), mux.clone());
    let mut press = PtyInputEvent::input(
        surface.id,
        handle.clone(),
        PtyInputBytes::from_slice(b"press"),
        PtyInputKind::Press,
    );
    press.mutation = Some(Box::new(|| Err(anyhow::anyhow!("flush failed"))));

    let (result, reservation_id) = dispatcher.enqueue_with_reservation(press);
    assert_eq!(result, PtyInputEnqueueResult::Accepted);
    let reservation_id = reservation_id.unwrap();
    let failure = failure_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert_eq!(failure.delivery, PtyOperationDelivery::Ambiguous);
    assert!(failure.lane_failed);
    assert_eq!(failure.reservation_id, Some(reservation_id));

    assert_eq!(
        dispatcher.enqueue(PtyInputEvent::release(
            surface.id,
            handle,
            PtyInputBytes::from_slice(b"release"),
            reservation_id,
        )),
        PtyInputEnqueueResult::Accepted,
        "lane quarantine rejected the matching recovery release"
    );
    assert!(dispatcher.shutdown(Duration::from_secs(1)));
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn ambiguous_release_is_retained_for_retry() {
    let mut state = QueueState::default();
    let mut release = event(7, 3, PtyInputKind::Release);
    release.reservation_id = Some(11);

    requeue_ambiguous_release(&mut state, release);

    assert_eq!(state.queued_bytes, 1);
    assert_eq!(state.events.len(), 1);
    assert_eq!(state.events[0].kind, PtyInputKind::Release);
    assert_eq!(state.events[0].reservation_id, Some(11));
}

#[test]
fn remote_transport_failure_cancels_backlog_and_rejects_later_operations() {
    let (failure_tx, failure_rx) = std::sync::mpsc::channel();
    let dispatcher = PtyInputDispatcher::spawn(move |failure| {
        failure_tx.send(failure).unwrap();
    })
    .unwrap();
    let sender = dispatcher.sender();
    let ran = Arc::new(std::sync::atomic::AtomicBool::new(false));

    sender.enqueue_session_mutation("remote input", true, || {
        Err(crate::session::test_remote_transport_error())
    });
    let follower_ran = ran.clone();
    sender.enqueue_session_mutation("queued close", true, move || {
        follower_ran.store(true, std::sync::atomic::Ordering::Release);
        Ok(())
    });

    let first = failure_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    let second = failure_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert!([first.label, second.label].contains(&"remote input"));
    assert!([first.label, second.label].contains(&"queued close"));
    assert!(first.lane_failed);
    assert!(second.lane_failed);
    let remote_failure =
        [&first, &second].into_iter().find(|failure| failure.label == "remote input").unwrap();
    let canceled_failure =
        [&first, &second].into_iter().find(|failure| failure.label == "queued close").unwrap();
    assert_eq!(remote_failure.delivery, PtyOperationDelivery::Ambiguous);
    assert_eq!(canceled_failure.delivery, PtyOperationDelivery::KnownNotDelivered);
    assert!(!ran.load(std::sync::atomic::Ordering::Acquire));

    sender.enqueue_session_mutation("later resize", true, || Ok(()));
    let later = failure_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert_eq!(later.label, "later resize");
    assert!(later.error.contains("unavailable"));
    assert!(later.lane_failed);
}

#[test]
fn remote_timeout_cancels_stale_backlog_but_allows_recovery() {
    let (failure_tx, failure_rx) = std::sync::mpsc::channel();
    let dispatcher = PtyInputDispatcher::spawn(move |failure| {
        failure_tx.send(failure).unwrap();
    })
    .unwrap();
    let sender = dispatcher.sender();
    let stale_ran = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let recovered = Arc::new(std::sync::atomic::AtomicBool::new(false));

    sender.enqueue_session_mutation("timed out request", true, || {
        Err(crate::session::test_remote_timeout_error())
    });
    let stale = stale_ran.clone();
    sender.enqueue_session_mutation("stale queued request", true, move || {
        stale.store(true, std::sync::atomic::Ordering::Release);
        Ok(())
    });

    let canceled = failure_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert_eq!(canceled.label, "stale queued request");
    assert!(!canceled.lane_failed);
    assert!(failure_rx.try_recv().is_err());
    assert!(!stale_ran.load(std::sync::atomic::Ordering::Acquire));

    let recovery = recovered.clone();
    sender.enqueue_session_mutation("recovery request", true, move || {
        recovery.store(true, std::sync::atomic::Ordering::Release);
        Ok(())
    });
    let deadline = Instant::now() + Duration::from_secs(1);
    while !recovered.load(std::sync::atomic::Ordering::Acquire) && Instant::now() < deadline {
        std::thread::yield_now();
    }
    assert!(recovered.load(std::sync::atomic::Ordering::Acquire));
}

#[test]
fn remote_surface_timeout_quarantines_only_its_lane() {
    let (failure_tx, failure_rx) = std::sync::mpsc::channel();
    let dispatcher = PtyInputDispatcher::spawn(move |failure| {
        failure_tx.send(failure).unwrap();
    })
    .unwrap();
    let sender = dispatcher.sender();

    assert_eq!(
        sender.enqueue_surface_operation_with_retained_bytes(
            "timed out clear",
            41,
            true,
            0,
            || Err(crate::session::test_remote_timeout_error()),
        ),
        PtyInputEnqueueResult::Accepted
    );
    let failure = failure_rx.recv_timeout(Duration::from_secs(1)).unwrap();

    assert_eq!(failure.surface_id, Some(41));
    assert_eq!(failure.delivery, PtyOperationDelivery::Ambiguous);
    assert!(failure.lane_failed);
    assert_eq!(
        sender.enqueue(event(41, 1, PtyInputKind::Ordered)),
        PtyInputEnqueueResult::Failed,
        "same-surface input entered a lane with an ambiguous timeout"
    );
    assert_eq!(
        sender.enqueue(event(42, 2, PtyInputKind::Ordered)),
        PtyInputEnqueueResult::Accepted,
        "an unrelated surface was quarantined"
    );
}

#[test]
fn remote_command_rejection_keeps_the_operation_lane_available() {
    let (failure_tx, failure_rx) = std::sync::mpsc::channel();
    let dispatcher = PtyInputDispatcher::spawn(move |failure| {
        failure_tx.send(failure).unwrap();
    })
    .unwrap();
    let sender = dispatcher.sender();
    let ran = Arc::new(std::sync::atomic::AtomicBool::new(false));

    sender.enqueue_session_mutation("invalid remote command", true, || {
        Err(crate::session::test_remote_rejected_error())
    });
    let follower_ran = ran.clone();
    sender.enqueue_session_mutation("following operation", true, move || {
        follower_ran.store(true, std::sync::atomic::Ordering::Release);
        Ok(())
    });

    let failure = failure_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert_eq!(failure.label, "invalid remote command");
    assert!(!failure.lane_failed);
    assert_eq!(failure.delivery, PtyOperationDelivery::Ambiguous);
    let deadline = Instant::now() + Duration::from_secs(1);
    while !ran.load(std::sync::atomic::Ordering::Acquire) && Instant::now() < deadline {
        std::thread::yield_now();
    }
    assert!(ran.load(std::sync::atomic::Ordering::Acquire));
}

#[test]
fn oversized_input_is_distinguished_from_queue_saturation() {
    let dispatcher = PtyInputDispatcher::spawn(|_| {}).unwrap();
    let mut oversized = event(1, 1, PtyInputKind::Ordered);
    oversized.bytes = vec![1; MAX_QUEUED_BYTES + 1].into();

    assert_eq!(dispatcher.enqueue(oversized), PtyInputEnqueueResult::Oversized);
}
