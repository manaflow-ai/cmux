//! Deadline fanout pool and cell pixel fanout retries, acks, and viewer resize reports.

use super::*;

#[test]
fn cell_pixel_fanout_runs_concurrently_with_one_shared_deadline() {
    let pool = DeadlineFanoutPool::new();
    let (warm_tx, warm_rx) = std::sync::mpsc::sync_channel(1);
    assert!(pool.submit(Box::new(move || warm_tx.send(()).unwrap())));
    warm_rx.recv_timeout(Duration::from_secs(1)).expect("warmup fanout job did not run");
    let items = (0..8).collect::<Vec<_>>();
    let active = Arc::new(AtomicUsize::new(0));
    let max_active = Arc::new(AtomicUsize::new(0));
    let deadline = Instant::now() + Duration::from_secs(1);
    let operation_active = active;
    let operation_max_active = max_active.clone();

    let results = bounded_deadline_map(&pool, &items, deadline, move |item, observed_deadline| {
        assert_eq!(observed_deadline, deadline);
        let concurrent = operation_active.fetch_add(1, Ordering::AcqRel) + 1;
        operation_max_active.fetch_max(concurrent, Ordering::AcqRel);
        std::thread::sleep(Duration::from_millis(10));
        operation_active.fetch_sub(1, Ordering::AcqRel);
        item * 2
    });

    assert_eq!(
        results
            .into_iter()
            .map(|result| match result {
                DeadlineMapResult::Complete(result) => Some(result),
                DeadlineMapResult::Pending(_) | DeadlineMapResult::Unscheduled => None,
            })
            .collect::<Option<Vec<_>>>()
            .unwrap(),
        vec![0, 2, 4, 6, 8, 10, 12, 14]
    );
    assert!(max_active.load(Ordering::Acquire) > 1);
}

#[test]
fn deadline_fanout_rejects_work_after_the_shared_deadline() {
    let pool = DeadlineFanoutPool::new();
    let calls = Arc::new(AtomicUsize::new(0));
    let operation_calls = calls.clone();
    let deadline = Instant::now().checked_sub(Duration::from_millis(1)).unwrap();

    let results = bounded_deadline_map(&pool, &[1_u8], deadline, move |item, _| {
        operation_calls.fetch_add(1, Ordering::AcqRel);
        *item
    });

    assert!(matches!(results.as_slice(), [DeadlineMapResult::Unscheduled]));
    assert_eq!(calls.load(Ordering::Acquire), 0);
}

#[test]
fn fanout_completion_after_the_shared_deadline_remains_retryable() {
    let deadline = Instant::now();
    let pending = DeadlinePending {
        result: Arc::new(Mutex::new(Some(DeadlineCompletion {
            completed_at: deadline + Duration::from_millis(1),
            value: 42,
        }))),
    };

    assert_eq!(pending.try_take_before(deadline), None);
    assert_eq!(pending.try_take(), Some(42));
}

#[test]
fn deadline_fanout_workers_are_lazy_and_reclaim_idle_threads() {
    let pool = DeadlineFanoutPool::new();
    assert_eq!(pool.worker_count(), 0, "fanout construction eagerly retained workers");

    let (finished_tx, finished_rx) = std::sync::mpsc::sync_channel(1);
    assert!(pool.submit(Box::new(move || {
        finished_tx.send(()).unwrap();
    })));
    finished_rx.recv_timeout(Duration::from_secs(1)).expect("fanout job did not run");

    let deadline = Instant::now() + Duration::from_secs(1);
    while pool.worker_count() != 0 && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(pool.worker_count(), 0, "idle fanout worker was retained");

    let (teardown_tx, teardown_rx) = std::sync::mpsc::sync_channel(1);
    assert!(pool.submit(Box::new(move || teardown_tx.send(()).unwrap())));
    teardown_rx.recv_timeout(Duration::from_secs(1)).expect("teardown fanout job did not run");
    let inner = Arc::downgrade(&pool.inner);
    drop(pool);
    let deadline = Instant::now() + Duration::from_secs(1);
    while inner.upgrade().is_some() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(inner.upgrade().is_none(), "dropped fanout pool retained its executor state");
}

#[test]
fn cell_pixel_fanout_returns_when_an_operation_ignores_its_deadline() {
    let gate = Arc::new((Mutex::new(false), Condvar::new()));
    let (sender, receiver) = std::sync::mpsc::sync_channel(1);
    let caller_gate = gate.clone();
    let caller = std::thread::spawn(move || {
        let pool = DeadlineFanoutPool::new();
        let items = vec![1_u8];
        let deadline = Instant::now() + Duration::from_millis(30);
        let results = bounded_deadline_map(&pool, &items, deadline, move |item, _| {
            let (released, changed) = &*caller_gate;
            let mut released = released.lock().unwrap();
            while !*released {
                released = changed.wait(released).unwrap();
            }
            *item
        });
        let _ = sender.send(results);
    });

    let returned_before_release = receiver.recv_timeout(Duration::from_millis(150)).is_ok();
    {
        let (released, changed) = &*gate;
        *released.lock().unwrap() = true;
        changed.notify_all();
    }
    caller.join().unwrap();

    assert!(
        returned_before_release,
        "fanout joined an operation after its shared deadline elapsed"
    );
}

#[test]
fn timed_out_cell_pixel_failure_is_retried_after_the_worker_finishes() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let attempts = Arc::new(AtomicUsize::new(0));
    *mux.cell_pixel_fanout_timeout.lock().unwrap() = Some(Duration::from_millis(20));
    *mux.cell_pixel_operation.lock().unwrap() = Some(Arc::new({
        let attempts = attempts.clone();
        move |surface, target, _deadline| {
            if attempts.fetch_add(1, Ordering::AcqRel) == 0 {
                std::thread::sleep(Duration::from_millis(60));
                anyhow::bail!("injected late cell-pixel failure");
            }
            surface.set_cell_pixel_size(target.0, target.1).map(|changed| changed.then_some(0))
        }
    }));

    let update = mux.set_cell_pixel_size(9, 18);
    assert_eq!(update.failures.len(), 1);
    assert!(update.failures[0].deferred);

    let deadline = Instant::now() + Duration::from_secs(1);
    while mux.cell_pixel_size() != (9, 18) && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(
        attempts.load(Ordering::Acquire) >= 2,
        "the failed operation that finished after the shared deadline was never retried"
    );
    assert_eq!(mux.cell_pixel_size(), (9, 18));
    assert_eq!(surface.test_cell_pixel_size(), (9, 18));
}

#[test]
fn cell_pixel_fanout_retries_the_same_metric_before_publishing_it() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    surface.fail_next_test_master_resize();

    let update = mux.set_cell_pixel_size(9, 18);

    assert!(update.resizes.is_empty());
    assert_eq!(update.failures.len(), 1);
    assert_eq!(update.failures[0].surface, surface.id);
    assert!(update.failures[0].error.contains("injected PTY master resize failure"));
    assert_eq!(
        mux.cell_pixel_size(),
        (8, 16),
        "published metric must remain at the last fully converged value"
    );
    assert_eq!(mux.cell_pixel_creation_size(), (8, 16));
    assert_eq!(surface.test_cell_pixel_size(), (8, 16));
    let created_while_pending = mux.new_workspace(None, Some((80, 24))).unwrap();
    assert_eq!(created_while_pending.test_cell_pixel_size(), (8, 16));
    let master = surface.test_master_size();
    assert_eq!(
        (master.cols, master.rows, master.pixel_width, master.pixel_height),
        (80, 24, 640, 384)
    );

    let retried = mux.set_cell_pixel_size(9, 18);
    assert!(retried.failures.is_empty());
    assert_eq!(
        retried.resizes,
        vec![(surface.id, (80, 24), 0), (created_while_pending.id, (80, 24), 0)]
    );
    assert_eq!(mux.cell_pixel_size(), (9, 18));
    assert_eq!(surface.test_cell_pixel_size(), (9, 18));
}

#[test]
fn cell_pixel_fanout_retries_work_skipped_after_the_shared_deadline() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    for _ in 1..=CELL_PIXEL_FANOUT_MAX_WORKERS {
        mux.new_tab(Some(pane), None, Some((80, 24))).unwrap();
    }
    let mut surface_ids = mux.state.lock().unwrap().surfaces.keys().copied().collect::<Vec<_>>();
    surface_ids.sort_unstable();
    assert_eq!(surface_ids.len(), CELL_PIXEL_FANOUT_MAX_WORKERS + 1);
    let last_surface = *surface_ids.last().unwrap();
    let last_attempts = Arc::new(AtomicUsize::new(0));
    *mux.cell_pixel_fanout_timeout.lock().unwrap() = Some(Duration::from_millis(50));
    *mux.cell_pixel_operation.lock().unwrap() = Some(Arc::new({
        let last_attempts = last_attempts.clone();
        move |surface, target, deadline| {
            if surface.id != last_surface {
                std::thread::sleep(
                    deadline.saturating_duration_since(Instant::now()) + Duration::from_millis(10),
                );
            } else {
                last_attempts.fetch_add(1, Ordering::AcqRel);
                if Instant::now() >= deadline {
                    return Err(
                        crate::terminal_host_runtime::CellPixelRequestDeadlineElapsed.into()
                    );
                }
            }
            surface.set_cell_pixel_size(target.0, target.1).map(|changed| changed.then_some(0))
        }
    }));

    let update = mux.set_cell_pixel_size(9, 18);

    // The first worker wave finishes just after the shared deadline. Its
    // completion callbacks may reconcile those surfaces before this call
    // returns, depending on scheduler timing. The unscheduled final
    // surface must remain deferred in either ordering.
    assert!(update.failures.iter().any(|failure| failure.surface == last_surface));
    assert!(update.failures.iter().all(|failure| failure.deferred));
    let retry_deadline = Instant::now() + Duration::from_secs(1);
    while mux.cell_pixel_size() != (9, 18) && Instant::now() < retry_deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(
        mux.cell_pixel_size(),
        (9, 18),
        "work that missed the first worker wave was never reconciled"
    );
    assert!(mux.pending_cell_pixels.lock().unwrap().is_none());
    assert_eq!(last_attempts.load(Ordering::Acquire), 1);
}

#[test]
fn cell_pixel_deadline_retries_stop_and_report_terminal_failure() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let attempts = Arc::new(AtomicUsize::new(0));
    // The operation answers at once; a generous fanout wait means a
    // worker thread that starts late under load still counts as an
    // attempt instead of a fanout timeout.
    *mux.cell_pixel_fanout_timeout.lock().unwrap() = Some(Duration::from_secs(30));
    *mux.cell_pixel_operation.lock().unwrap() = Some(Arc::new({
        let attempts = attempts.clone();
        move |_, _, _| {
            attempts.fetch_add(1, Ordering::AcqRel);
            Err(crate::terminal_host_runtime::CellPixelRequestDeadlineElapsed.into())
        }
    }));
    let events = mux.subscribe();

    let update = mux.set_cell_pixel_size(9, 18);

    assert_eq!(update.failures.len(), 1);
    assert!(update.failures[0].deferred);
    // A safety bound only: the retries stop after their attempts.
    let deadline = Instant::now() + Duration::from_secs(30);
    while mux.cell_pixel_retries.lock().unwrap().worker_running && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(
        !mux.cell_pixel_retries.lock().unwrap().worker_running,
        "deadline retries did not stop after {} attempts",
        attempts.load(Ordering::Acquire)
    );
    assert_eq!(attempts.load(Ordering::Acquire), usize::from(CELL_PIXEL_RETRY_MAX_ATTEMPTS) + 1);
    assert_eq!(mux.cell_pixel_creation_size(), (8, 16));
    assert!(events.try_iter().any(|event| matches!(
        event,
        MuxEvent::GraphicsStatus(GraphicsStatus::CellPixelUpdateRetriesExhausted {
            attempts: CELL_PIXEL_RETRY_MAX_ATTEMPTS,
            remaining: 1,
            cell_pixels: (9, 18),
        })
    )));

    assert!(surface.set_cell_pixel_size(9, 18).unwrap());
    mux.reconcile_deferred_cell_pixel_ack(surface.id, (9, 18));
    assert_eq!(mux.cell_pixel_size(), (9, 18));
    assert!(mux.pending_cell_pixels.lock().unwrap().is_none());
}

#[test]
fn late_cell_pixel_ack_publishes_the_pending_creation_metric() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    surface.fail_next_test_master_resize();

    let update = mux.set_cell_pixel_size(9, 18);
    assert_eq!(update.failures.len(), 1);
    assert_eq!(mux.cell_pixel_size(), (8, 16));
    assert_eq!(mux.cell_pixel_creation_size(), (8, 16));

    assert!(surface.set_cell_pixel_size(9, 18).unwrap());
    mux.reconcile_deferred_cell_pixel_ack(surface.id, (9, 18));

    assert_eq!(mux.cell_pixel_size(), (9, 18));
    assert_eq!(mux.cell_pixel_creation_size(), (9, 18));
    assert!(mux.pending_cell_pixels.lock().unwrap().is_none());
}

#[test]
fn deferred_cell_pixel_target_sizes_new_surfaces_before_the_ack_arrives() {
    let mux = test_mux();
    let pending_surface = 99_999;
    *mux.pending_cell_pixels.lock().unwrap() = Some(PendingCellPixelUpdate {
        generation: 1,
        target: (9, 18),
        failures: HashSet::from([pending_surface]),
        use_for_creation: true,
    });

    let created = mux.new_workspace(None, Some((80, 24))).unwrap();

    assert_eq!(mux.cell_pixel_size(), (8, 16));
    assert_eq!(created.test_cell_pixel_size(), (9, 18));
    mux.reconcile_deferred_cell_pixel_ack(pending_surface, (9, 18));
    assert_eq!(mux.cell_pixel_size(), (9, 18));
}

#[test]
fn closing_the_last_failed_terminal_publishes_pending_cell_pixels() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    *mux.pending_cell_pixels.lock().unwrap() = Some(PendingCellPixelUpdate {
        generation: 1,
        target: (9, 18),
        failures: HashSet::from([surface.id]),
        use_for_creation: false,
    });

    assert_eq!(mux.cell_pixel_size(), (8, 16));
    close_terminal_runtime_for_test(&mux, &surface);

    assert_eq!(mux.cell_pixel_size(), (9, 18));
    assert!(mux.pending_cell_pixels.lock().unwrap().is_none());
}

#[test]
fn failed_viewer_resize_preserves_previous_report_and_creation_default() {
    let mux = test_mux();
    let missing_surface = 99_999;
    mux.record_client_size(90, 30);
    mux.client_sizing
        .lock()
        .unwrap()
        .surfaces
        .entry(missing_surface)
        .or_default()
        .insert(7, (80, 25));

    assert!(mux.resize_surface_for_client(missing_surface, 7, 120, 40).is_err());
    assert_eq!(mux.client_surface_size(missing_surface, 7), Some((80, 25)));
    assert_eq!(mux.new_workspace(None, None).unwrap().size(), (90, 30));
}

#[test]
fn failed_first_terminal_report_removes_empty_sizing_indexes() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    assert_eq!(mux.claim_terminal_geometry(surface.id, 0), Some(true));
    surface.fail_next_test_master_resize();

    assert!(mux.resize_surface_for_client(surface.id, 0, 100, 30).is_err());
    let sizing = mux.client_sizing.lock().unwrap();
    assert!(!sizing.surfaces.contains_key(&surface.id));
    assert!(!sizing.report_order.contains_key(&(surface.id, 0)));
    assert!(!sizing.terminal_runtime_by_placement.contains_key(&surface.id));
}

#[test]
fn concurrent_browser_viewer_reports_settle_at_the_shared_minimum() {
    let mux = test_mux();
    let surface =
        mux.new_browser_tab("about:blank#concurrent-sizing".into(), None, Some((100, 30))).unwrap();
    let surface_id = surface.id;
    let pause_first = Arc::new(AtomicBool::new(true));
    let (reached_tx, reached_rx) = std::sync::mpsc::sync_channel(1);
    let release = Arc::new((Mutex::new(false), Condvar::new()));
    let hook_release = release.clone();
    mux.set_client_resize_before_apply(Some(Arc::new(move || {
        if pause_first.swap(false, Ordering::SeqCst) {
            reached_tx.send(()).unwrap();
            let (lock, ready) = &*hook_release;
            let mut released = lock.lock().unwrap();
            while !*released {
                released = ready.wait(released).unwrap();
            }
        }
    })));

    let first_mux = mux.clone();
    let first = std::thread::spawn(move || {
        first_mux.resize_surface_for_client(surface_id, 1, 120, 40).unwrap();
    });
    reached_rx.recv_timeout(Duration::from_secs(1)).unwrap();

    let second_mux = mux.clone();
    let second = std::thread::spawn(move || {
        second_mux.resize_surface_for_client(surface_id, 2, 80, 50).unwrap();
    });
    let (lock, ready) = &*release;
    *lock.lock().unwrap() = true;
    ready.notify_all();
    first.join().unwrap();
    second.join().unwrap();

    if let Some(pending) = surface.pending_resize_completion(80, 40).unwrap() {
        assert_eq!(pending.completion.recv_timeout(Duration::from_secs(10)).unwrap(), Ok(()));
    }
    assert_eq!(surface.size(), (80, 40));
    mux.set_client_resize_before_apply(None);
    mux.shutdown();
}
