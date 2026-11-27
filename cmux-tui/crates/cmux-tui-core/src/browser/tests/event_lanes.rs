//! The shared CDP event-lane pool: per-surface order, no surface thread, and
//! one stuck or panicking lane never holds the others.

use super::*;
use crate::browser::SurfaceRoute;
use crate::browser::event_lanes::{EVENT_POOL_THREADS, LaneFlow, serving_threads};

fn navigated(epoch: u64) -> cmux_tui_cdp::CdpEvent {
    cmux_tui_cdp::CdpEvent::FrameNavigated {
        params: Value::Null,
        session_id: "session-1".to_string(),
        frame_epoch: epoch,
    }
}

fn epoch_of(event: &cmux_tui_cdp::CdpEvent) -> Option<u64> {
    match event {
        cmux_tui_cdp::CdpEvent::FrameNavigated { frame_epoch, .. } => Some(*frame_epoch),
        _ => None,
    }
}

/// A handler that reports each event's epoch (or `None` for its Closed) and
/// ends at Closed, as the surface handler does.
fn reporting_lane(route: &Arc<SurfaceRoute>) -> mpsc::Receiver<Option<u64>> {
    let (tx, rx) = mpsc::channel();
    route
        .attach_handler(Box::new(move |event| {
            let closed = matches!(event, cmux_tui_cdp::CdpEvent::Closed(_));
            let _ = tx.send(epoch_of(&event));
            if closed { LaneFlow::End } else { LaneFlow::Continue }
        }))
        .unwrap();
    rx
}

#[test]
fn a_lane_serves_its_events_in_order_on_the_shared_pool() {
    let route = Arc::new(SurfaceRoute::new());
    // Queued before the handler: served first, in order.
    for epoch in 0..10 {
        assert!(!route.deliver(navigated(epoch)));
    }
    let rx = reporting_lane(&route);
    // Within the lane's bound even if nothing is served yet (an overflow
    // closes the route).
    let total = cmux_tui_cdp::CDP_EVENT_QUEUE_CAPACITY as u64 / 2;
    for epoch in 10..total {
        assert!(!route.deliver(navigated(epoch)));
    }
    let served =
        (0..total).map(|_| rx.recv_timeout(BROWSER_TEST_SAFETY_BOUND).unwrap()).collect::<Vec<_>>();
    assert_eq!(served, (0..total).map(Some).collect::<Vec<_>>());

    let threads = serving_threads();
    assert!(
        threads.iter().all(|name| name.starts_with("browser-events-")),
        "lane handlers ran off the pool: {threads:?}"
    );
    assert!(threads.len() <= EVENT_POOL_THREADS, "pool grew: {threads:?}");
}

#[test]
fn a_lane_keeps_its_order_across_turns() {
    // Five times a turn (32 events) through one lane, in batches of 40 so
    // at most 40 are unserved (the bound is 64): the lane yields and is
    // requeued many times.
    let route = Arc::new(SurfaceRoute::new());
    let rx = reporting_lane(&route);
    for batch in 0..4u64 {
        for epoch in batch * 40..(batch + 1) * 40 {
            assert!(!route.deliver(navigated(epoch)));
        }
        for epoch in batch * 40..(batch + 1) * 40 {
            assert_eq!(rx.recv_timeout(BROWSER_TEST_SAFETY_BOUND).unwrap(), Some(epoch));
        }
    }
}

#[test]
fn many_lanes_share_the_pool_threads() {
    let lanes = (0..64)
        .map(|_| {
            let route = Arc::new(SurfaceRoute::new());
            let rx = reporting_lane(&route);
            (route, rx)
        })
        .collect::<Vec<_>>();
    for epoch in 0..20 {
        for (route, _) in &lanes {
            assert!(!route.deliver(navigated(epoch)));
        }
    }
    for (_, rx) in &lanes {
        for epoch in 0..20 {
            assert_eq!(rx.recv_timeout(BROWSER_TEST_SAFETY_BOUND).unwrap(), Some(epoch));
        }
    }
    let threads = serving_threads();
    assert!(threads.len() <= EVENT_POOL_THREADS, "64 lanes used {threads:?}");
}

#[test]
fn a_stuck_lane_does_not_hold_another_surfaces_events() {
    let stuck = Arc::new(SurfaceRoute::new());
    let (entered_tx, entered_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel::<()>();
    let release_rx = Mutex::new(release_rx);
    stuck
        .attach_handler(Box::new(move |_| {
            let _ = entered_tx.send(());
            let _ = release_rx.lock().unwrap().recv();
            LaneFlow::Continue
        }))
        .unwrap();
    assert!(!stuck.deliver(navigated(0)));
    entered_rx.recv_timeout(BROWSER_TEST_SAFETY_BOUND).unwrap();

    let other = Arc::new(SurfaceRoute::new());
    let rx = reporting_lane(&other);
    assert!(!other.deliver(navigated(7)));
    assert_eq!(rx.recv_timeout(BROWSER_TEST_SAFETY_BOUND).unwrap(), Some(7));
    release_tx.send(()).unwrap();
}

#[test]
fn a_panicking_handler_ends_only_its_lane() {
    let broken = Arc::new(SurfaceRoute::new());
    broken.attach_handler(Box::new(|_| panic!("handler bug"))).unwrap();
    assert!(!broken.deliver(navigated(0)));
    assert!(broken.wait_ended(BROWSER_TEST_SAFETY_BOUND), "the panicking lane ended");
    assert!(broken.deliver(navigated(1)), "an ended lane asks the router to drop it");

    let other = Arc::new(SurfaceRoute::new());
    let rx = reporting_lane(&other);
    assert!(!other.deliver(navigated(3)));
    assert_eq!(rx.recv_timeout(BROWSER_TEST_SAFETY_BOUND).unwrap(), Some(3));
}

#[test]
fn closing_a_route_serves_its_close_and_ends_the_lane() {
    let route = Arc::new(SurfaceRoute::new());
    let rx = reporting_lane(&route);
    assert!(!route.deliver(navigated(1)));
    // A close drops what is still queued (as before), so let 1 be served.
    assert_eq!(rx.recv_timeout(BROWSER_TEST_SAFETY_BOUND).unwrap(), Some(1));
    route.close("browser surface closed".to_string());
    assert_eq!(rx.recv_timeout(BROWSER_TEST_SAFETY_BOUND).unwrap(), None);
    assert!(route.wait_ended(BROWSER_TEST_SAFETY_BOUND));
    assert!(route.deliver(navigated(2)));
    // The handler (and what it holds) is gone with the lane.
    assert!(rx.recv_timeout(Duration::from_millis(50)).is_err());
}

#[test]
fn registry_waits_do_not_block_other_event_lanes() {
    let mux = Mux::new("browser-event-lanes-registry", SurfaceOptions::default());
    let surfaces = (0..EVENT_POOL_THREADS)
        .map(|_| mux.new_browser_tab("https://example.test".into(), None, Some((10, 5))).unwrap())
        .collect::<Vec<_>>();
    let routes = surfaces
        .iter()
        .map(|surface| {
            let route = Arc::new(SurfaceRoute::new());
            start_surface_thread(
                surface.clone(),
                route.clone(),
                Arc::downgrade(&mux),
                Weak::new(),
                "session-test".into(),
            )
            .unwrap();
            route
        })
        .collect::<Vec<_>>();

    let (entered_tx, entered_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel::<()>();
    let registry_mux = mux.clone();
    let holder = thread::spawn(move || {
        registry_mux
            .read_registry_state(|_| {
                entered_tx.send(()).unwrap();
                let _ = release_rx.recv();
                Ok(())
            })
            .unwrap();
    });
    entered_rx.recv_timeout(BROWSER_TEST_SAFETY_BOUND).unwrap();

    // Both navigation handlers precede the probe in the pool's FIFO. If
    // either performs registry I/O here, two tabs consume the whole pool.
    for route in &routes {
        assert!(!route.deliver(cmux_tui_cdp::CdpEvent::TargetInfoChanged(
            cmux_tui_cdp::TargetInfo {
                session_id: Some("session-test".into()),
                target_id: "target-test".into(),
                title: "Next page".into(),
                url: "https://example.test/next".into(),
            },
        )));
    }
    let probe = Arc::new(SurfaceRoute::new());
    let rx = reporting_lane(&probe);
    assert!(!probe.deliver(navigated(7)));
    let served = rx.recv_timeout(BROWSER_TEST_SAFETY_BOUND);

    // Release before asserting so a failing run cannot strand the shared
    // pool or a registry holder for the rest of this test binary.
    drop(release_tx);
    holder.join().unwrap();
    for route in routes {
        route.close("test complete".into());
    }
    probe.close("test complete".into());
    mux.shutdown();
    assert_eq!(served.unwrap(), Some(7), "registry work held every event worker");
}

#[test]
fn paused_lane_survives_runtime_unregister_and_serves_close() {
    let route = Arc::new(SurfaceRoute::new());
    let weak = Arc::downgrade(&route);
    let handler_route = weak.clone();
    let (paused_tx, paused_rx) = mpsc::channel();
    let (closed_tx, closed_rx) = mpsc::channel();
    route
        .attach_handler(Box::new(move |event| match event {
            cmux_tui_cdp::CdpEvent::Closed(_) => {
                closed_tx.send(()).unwrap();
                LaneFlow::End
            }
            _ => {
                paused_tx.send(handler_route.upgrade().unwrap().pause()).unwrap();
                LaneFlow::Continue
            }
        }))
        .unwrap();
    assert!(!route.deliver(navigated(1)));
    let resume = paused_rx.recv_timeout(BROWSER_TEST_SAFETY_BOUND).unwrap();
    route.close("runtime unregistered its route".into());
    drop(route);
    assert!(weak.upgrade().is_some(), "pending work owns the paused route");
    drop(resume);
    closed_rx.recv_timeout(BROWSER_TEST_SAFETY_BOUND).unwrap();
}

#[test]
fn pause_on_turn_boundary_keeps_queued_events() {
    let route = Arc::new(SurfaceRoute::new());
    let weak = Arc::downgrade(&route);
    let (paused_tx, paused_rx) = mpsc::channel();
    let (served_tx, served_rx) = mpsc::channel();
    route
        .attach_handler(Box::new(move |event| {
            if let cmux_tui_cdp::CdpEvent::FrameNavigated { frame_epoch, .. } = event {
                if frame_epoch == 31 {
                    paused_tx.send(weak.upgrade().unwrap().pause()).unwrap();
                }
                served_tx.send(frame_epoch).unwrap();
            }
            LaneFlow::Continue
        }))
        .unwrap();
    for epoch in 0..40 {
        assert!(!route.deliver(navigated(epoch)));
    }
    let resume = paused_rx.recv_timeout(BROWSER_TEST_SAFETY_BOUND).unwrap();
    for epoch in 0..32 {
        assert_eq!(served_rx.recv_timeout(BROWSER_TEST_SAFETY_BOUND).unwrap(), epoch);
    }
    assert!(served_rx.try_recv().is_err(), "later events wait for the durable work");
    drop(resume);
    for epoch in 32..40 {
        assert_eq!(served_rx.recv_timeout(BROWSER_TEST_SAFETY_BOUND).unwrap(), epoch);
    }
    route.close("test complete".into());
}

#[test]
fn resume_before_handler_returns_does_not_lose_wakeup() {
    let route = Arc::new(SurfaceRoute::new());
    let weak = Arc::downgrade(&route);
    let (served_tx, served_rx) = mpsc::channel();
    route
        .attach_handler(Box::new(move |event| {
            let route = weak.upgrade().unwrap();
            drop(route.pause());
            if let cmux_tui_cdp::CdpEvent::FrameNavigated { frame_epoch, .. } = event {
                served_tx.send(frame_epoch).unwrap();
            }
            LaneFlow::Continue
        }))
        .unwrap();
    for epoch in 0..40 {
        assert!(!route.deliver(navigated(epoch)));
    }
    for epoch in 0..40 {
        assert_eq!(served_rx.recv_timeout(BROWSER_TEST_SAFETY_BOUND).unwrap(), epoch);
    }
    route.close("test complete".into());
}

#[test]
fn paused_lane_still_answers_dialogs_needed_by_its_command_worker() {
    for prequeued in [true, false] {
        let route = Arc::new(SurfaceRoute::new());
        let weak = Arc::downgrade(&route);
        let (paused_tx, paused_rx) = mpsc::channel();
        let (dialog_tx, dialog_rx) = mpsc::channel();
        let handler: crate::browser::event_lanes::LaneHandler = Box::new(move |event| {
            match event {
                cmux_tui_cdp::CdpEvent::FrameNavigated { .. } => {
                    paused_tx.send(weak.upgrade().unwrap().pause()).unwrap();
                }
                cmux_tui_cdp::CdpEvent::Other { method, .. }
                    if method == "Page.javascriptDialogOpening" =>
                {
                    dialog_tx.send(()).unwrap();
                }
                _ => {}
            }
            LaneFlow::Continue
        });
        let dialog = cmux_tui_cdp::CdpEvent::Other {
            method: "Page.javascriptDialogOpening".into(),
            session_id: Some("session-1".into()),
            params: serde_json::json!({"type": "beforeunload"}),
        };
        if prequeued {
            assert!(!route.deliver(navigated(1)));
            assert!(!route.deliver(dialog));
        } else {
            assert!(!route.deliver(navigated(1)));
        }
        route.attach_handler(handler).unwrap();
        let resume = paused_rx.recv_timeout(BROWSER_TEST_SAFETY_BOUND).unwrap();
        if !prequeued {
            assert!(!route.deliver(cmux_tui_cdp::CdpEvent::Other {
                method: "Page.javascriptDialogOpening".into(),
                session_id: Some("session-1".into()),
                params: serde_json::json!({"type": "beforeunload"}),
            }));
        }
        let answered = dialog_rx.recv_timeout(BROWSER_TEST_SAFETY_BOUND);
        // The waiting command would resume registry work only after this
        // answer. Release before asserting so red runs leave no paused lane.
        drop(resume);
        route.close("test complete".into());
        assert!(answered.is_ok(), "dialog waited behind its own blocked command worker");
    }
}

#[test]
fn deferred_registry_overflow_closes_surface_without_losing_exit() {
    let mux = Mux::new("browser-event-lanes-overflow", SurfaceOptions::default());
    let surface = mux.new_browser_tab("https://example.test".into(), None, Some((10, 5))).unwrap();
    let browser = surface.as_browser().unwrap();
    let done = browser.take_worker_done_for_test();
    let (entered_tx, entered_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    assert!(
        browser.enqueue_test_command(BrowserCommand::Hold {
            entered: entered_tx,
            release: release_rx,
        })
    );
    entered_rx.recv_timeout(BROWSER_TEST_SAFETY_BOUND).unwrap();
    // Saturate ordinary admission too: the exit has its own retained slot.
    for _ in 0..BROWSER_COMMAND_QUEUE_CAPACITY {
        assert!(browser.enqueue_test_command(BrowserCommand::WakeLatest));
    }
    let mut retained = Vec::new();
    for _ in 0..BROWSER_COMMAND_QUEUE_CAPACITY {
        let route = Arc::new(SurfaceRoute::new());
        retained.push(Arc::downgrade(&route));
        browser
            .defer_registry_work(
                &Arc::downgrade(&route),
                crate::browser::event_registry::RegistryWork::ClearAttention(
                    "https://a.test".into(),
                ),
            )
            .unwrap();
    }
    let route = Arc::new(SurfaceRoute::new());
    let rejected = browser.defer_registry_work(
        &Arc::downgrade(&route),
        crate::browser::event_registry::RegistryWork::ClearAttention("https://b.test".into()),
    );
    let closed = browser.is_dead();
    drop(release_tx);
    done.recv_timeout(BROWSER_TEST_SAFETY_BOUND).unwrap();
    let removed = mux.surface(surface.id).is_none();
    mux.shutdown();
    assert!(rejected.is_err());
    assert!(closed, "unbounded provider churn must end the surface");
    assert!(removed, "the reserved exit must remove durable topology, even after kill");
    assert!(
        retained.iter().all(|route| route.upgrade().is_none()),
        "worker released every paused route"
    );
}
