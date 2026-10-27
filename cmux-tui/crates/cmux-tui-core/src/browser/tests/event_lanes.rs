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
