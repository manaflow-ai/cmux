use super::*;
use std::sync::atomic::{AtomicBool, Ordering};

struct DropProbe(Arc<AtomicBool>);

impl Drop for DropProbe {
    fn drop(&mut self) {
        self.0.store(true, Ordering::Release);
    }
}

fn move_event(surface: SurfaceId, x: f64) -> BrowserInputEvent {
    BrowserInputEvent {
        surface_id: surface,
        surface: SurfaceHandle::RemoteBrowserUnsupported,
        kind: BrowserInputKind::Mouse {
            event_type: "mouseMoved",
            x,
            y: 0.0,
            button: Some("none"),
            click_count: None,
            frame_seq: 1,
        },
    }
}

fn presentation_event(surface: SurfaceId, frame_seq: u64) -> BrowserInputEvent {
    BrowserInputEvent {
        surface_id: surface,
        surface: SurfaceHandle::RemoteBrowserUnsupported,
        kind: BrowserInputKind::Presented { frame_seq },
    }
}

fn click_event(surface: SurfaceId) -> BrowserInputEvent {
    click_event_with_button(surface, "left")
}

fn click_event_with_button(surface: SurfaceId, button: &'static str) -> BrowserInputEvent {
    BrowserInputEvent {
        surface_id: surface,
        surface: SurfaceHandle::RemoteBrowserUnsupported,
        kind: BrowserInputKind::Mouse {
            event_type: "mousePressed",
            x: 0.0,
            y: 0.0,
            button: Some(button),
            click_count: Some(1),
            frame_seq: 1,
        },
    }
}

fn release_event(surface: SurfaceId) -> BrowserInputEvent {
    release_event_with_button(surface, "left")
}

fn release_event_with_button(surface: SurfaceId, button: &'static str) -> BrowserInputEvent {
    BrowserInputEvent {
        surface_id: surface,
        surface: SurfaceHandle::RemoteBrowserUnsupported,
        kind: BrowserInputKind::Mouse {
            event_type: "mouseReleased",
            x: 0.0,
            y: 0.0,
            button: Some(button),
            click_count: Some(1),
            frame_seq: 1,
        },
    }
}

fn resize_event(surface: SurfaceId, cols: u16) -> BrowserInputEvent {
    BrowserInputEvent {
        surface_id: surface,
        surface: SurfaceHandle::RemoteBrowserUnsupported,
        kind: BrowserInputKind::Resize {
            cols,
            rows: 24,
            reassert: false,
            _claim: None,
            on_result: None,
        },
    }
}

fn resize_event_with_probe(
    surface: SurfaceId,
    cols: u16,
    dropped: Arc<AtomicBool>,
) -> BrowserInputEvent {
    BrowserInputEvent {
        surface_id: surface,
        surface: SurfaceHandle::RemoteBrowserUnsupported,
        kind: BrowserInputKind::Resize {
            cols,
            rows: 24,
            reassert: false,
            _claim: Some(Box::new(DropProbe(dropped))),
            on_result: None,
        },
    }
}

fn sequenced(sequence: u64, event: BrowserInputEvent) -> SequencedBrowserInputEvent {
    let retained_bytes = event.retained_bytes();
    SequencedBrowserInputEvent {
        sequence,
        event,
        lifetime: Arc::new(AtomicBool::new(false)),
        retained_bytes,
    }
}

fn reload_event(surface: SurfaceId) -> BrowserInputEvent {
    BrowserInputEvent {
        surface_id: surface,
        surface: SurfaceHandle::RemoteBrowserUnsupported,
        kind: BrowserInputKind::Reload,
    }
}

fn key_press_event(surface: SurfaceId) -> BrowserInputEvent {
    BrowserInputEvent {
        surface_id: surface,
        surface: SurfaceHandle::RemoteBrowserUnsupported,
        kind: BrowserInputKind::KeyPress {
            key: BrowserKey::Character('j'),
            code: "KeyJ",
            windows_virtual_key_code: 74,
            modifiers: 1,
            text: None,
        },
    }
}

// Regression: a full dispatcher queue (worker wedged inside a blocking
// browser call) must report the drop so control commands can surface
// backpressure to the user, instead of the old `let _ = try_send` that
// swallowed the failure and made a dropped reload/navigate look accepted.
#[test]
fn full_queue_reports_drop_instead_of_swallowing_it() {
    let (lane, _blocked) = SurfaceInputLane::blocked(1, QUEUE_CAPACITY);
    for _ in 0..QUEUE_CAPACITY {
        assert!(lane.enqueue(reload_event(1)), "queue should accept until full");
    }
    assert!(
        !lane.enqueue(reload_event(1)),
        "a full queue must report the drop, not swallow it as accepted"
    );
}

#[test]
fn full_queue_retains_the_release_after_its_accepted_press() {
    let (lane, blocked) = SurfaceInputLane::blocked(7, 1);
    assert!(lane.enqueue(click_event(7)));
    assert!(
        lane.enqueue(release_event(7)),
        "a saturated ordinary lane must retain the release that closes its accepted press"
    );
    assert_eq!(
        blocked.drain_mouse_lifetimes(),
        vec![("mousePressed", false), ("mouseReleased", false)],
        "the retained release must keep its enqueue order behind the accepted press"
    );
}

#[test]
fn full_queue_retains_only_a_matching_accepted_press_release() {
    let (lane, blocked) = SurfaceInputLane::blocked(7, 1);
    assert!(lane.enqueue(click_event(7)));
    assert!(
        !lane.enqueue(click_event_with_button(7, "right")),
        "the saturated ordinary lane must reject a second press"
    );
    assert!(
        !lane.enqueue(release_event_with_button(7, "right")),
        "a release for the dropped press must not enter the fallback lane"
    );
    assert!(
        lane.enqueue(release_event(7)),
        "the release matching the accepted press must retain its reserved fallback"
    );
    assert_eq!(
        blocked.drain_mouse_lifetimes(),
        vec![("mousePressed", false), ("mouseReleased", false)],
        "unmatched releases must leave no fallback backlog"
    );
}

#[test]
fn release_requires_and_consumes_an_accepted_press() {
    let (lane, blocked) = SurfaceInputLane::blocked(7, 1);
    assert!(
        !lane.enqueue(release_event(7)),
        "an unmatched release must not enter an available ordinary lane"
    );
    assert!(blocked.drain_mouse_lifetimes().is_empty());

    assert!(lane.enqueue(click_event(7)));
    assert_eq!(blocked.drain_mouse_lifetimes(), vec![("mousePressed", false)]);
    assert!(lane.enqueue(release_event(7)));
    assert!(
        !lane.enqueue(release_event(7)),
        "one accepted release must consume pointer ownership exactly once"
    );
    assert_eq!(blocked.drain_mouse_lifetimes(), vec![("mouseReleased", false)]);
}

// Regression: a discrete control command that fails inside the worker
// (here: RemoteBrowserUnsupported bails) must report a status event so the
// user learns it did not take effect, instead of the old `let _ = ...` that
// swallowed the inner result even after the outer queue accepted it.
// Disposable input must not report.
#[test]
fn failed_control_command_reports_status_but_input_does_not() {
    let (tx, rx) = sync_channel(1);
    let dispatcher = BrowserInputDispatcher::spawn(
        |_| {},
        move |message| {
            let _ = tx.send(message);
        },
    )
    .unwrap();

    assert!(dispatcher.enqueue(reload_event(1)));
    let message = rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert_eq!(message, "browser panes are not supported over attach yet");

    // Disposable input never reports, so the worker stays quiet for it.
    assert!(dispatcher.enqueue(move_event(1, 1.0)));
    assert!(
        rx.recv_timeout(Duration::from_millis(50)).is_err(),
        "disposable input must not emit status feedback"
    );
}

#[test]
fn blocked_surface_does_not_stall_an_unrelated_surface() {
    let dispatcher = BrowserInputDispatcher::spawn(|_| {}, |_| {}).unwrap();
    let (entered_tx, entered_rx) = std::sync::mpsc::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    let (observed_tx, observed_rx) = std::sync::mpsc::channel();

    assert!(dispatcher.enqueue(BrowserInputEvent {
        surface_id: 1,
        surface: SurfaceHandle::RemoteBrowserUnsupported,
        kind: BrowserInputKind::TestBlock { entered: entered_tx, release: release_rx },
    }));
    entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert!(dispatcher.enqueue(BrowserInputEvent {
        surface_id: 1,
        surface: SurfaceHandle::RemoteBrowserUnsupported,
        kind: BrowserInputKind::TestProbe(observed_tx.clone()),
    }));
    assert!(dispatcher.enqueue(BrowserInputEvent {
        surface_id: 2,
        surface: SurfaceHandle::RemoteBrowserUnsupported,
        kind: BrowserInputKind::TestProbe(observed_tx),
    }));

    assert_eq!(
        observed_rx.recv_timeout(Duration::from_millis(250)),
        Ok(2),
        "one blocked surface stalled input for an unrelated surface"
    );
    assert!(observed_rx.try_recv().is_err(), "the blocked surface lost its own command ordering");
    release_tx.send(()).unwrap();
    assert_eq!(observed_rx.recv_timeout(Duration::from_secs(1)), Ok(1));
}

#[test]
fn blocked_surface_does_not_stall_an_unrelated_surface_with_the_same_legacy_shard() {
    let dispatcher = BrowserInputDispatcher::spawn(|_| {}, |_| {}).unwrap();
    let (entered_tx, entered_rx) = std::sync::mpsc::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    let (observed_tx, observed_rx) = std::sync::mpsc::channel();

    assert!(dispatcher.enqueue(BrowserInputEvent {
        surface_id: 1,
        surface: SurfaceHandle::RemoteBrowserUnsupported,
        kind: BrowserInputKind::TestBlock { entered: entered_tx, release: release_rx },
    }));
    entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert!(dispatcher.enqueue(BrowserInputEvent {
        surface_id: 1,
        surface: SurfaceHandle::RemoteBrowserUnsupported,
        kind: BrowserInputKind::TestProbe(observed_tx.clone()),
    }));
    assert!(dispatcher.enqueue(BrowserInputEvent {
        surface_id: 9,
        surface: SurfaceHandle::RemoteBrowserUnsupported,
        kind: BrowserInputKind::TestProbe(observed_tx),
    }));

    assert_eq!(
        observed_rx.recv_timeout(Duration::from_millis(250)),
        Ok(9),
        "a blocked surface stalled an unrelated surface assigned to the same worker"
    );
    assert!(observed_rx.try_recv().is_err(), "the blocked surface lost its own command ordering");
    release_tx.send(()).unwrap();
    assert_eq!(observed_rx.recv_timeout(Duration::from_secs(1)), Ok(1));
}

fn block_all_browser_input_workers(
    dispatcher: &BrowserInputDispatcher,
) -> Vec<std::sync::mpsc::Sender<()>> {
    let (entered_tx, entered_rx) = std::sync::mpsc::channel();
    let mut releases = Vec::new();
    for surface_id in 1..=BROWSER_INPUT_WORKER_COUNT as u64 {
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        assert!(dispatcher.enqueue(BrowserInputEvent {
            surface_id,
            surface: SurfaceHandle::RemoteBrowserUnsupported,
            kind: BrowserInputKind::TestBlock { entered: entered_tx.clone(), release: release_rx },
        }));
        releases.push(release_tx);
    }
    for _ in 0..BROWSER_INPUT_WORKER_COUNT {
        entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    }
    releases
}

#[test]
fn scheduler_turn_dispatches_at_most_one_blocking_request() {
    let dispatcher = BrowserInputDispatcher::spawn(|_| {}, |_| {}).unwrap();
    let (first_entered_tx, first_entered_rx) = std::sync::mpsc::channel();
    let (second_entered_tx, _second_entered_rx) = std::sync::mpsc::channel();
    let mut first_releases = Vec::new();
    let mut second_releases = Vec::new();

    for surface_id in 1..=BROWSER_INPUT_WORKER_COUNT as u64 {
        let (first_release_tx, first_release_rx) = std::sync::mpsc::channel();
        let (second_release_tx, second_release_rx) = std::sync::mpsc::channel();
        assert!(dispatcher.enqueue(BrowserInputEvent {
            surface_id,
            surface: SurfaceHandle::RemoteBrowserUnsupported,
            kind: BrowserInputKind::TestBlock {
                entered: first_entered_tx.clone(),
                release: first_release_rx,
            },
        }));
        assert!(dispatcher.enqueue(BrowserInputEvent {
            surface_id,
            surface: SurfaceHandle::RemoteBrowserUnsupported,
            kind: BrowserInputKind::TestBlock {
                entered: second_entered_tx.clone(),
                release: second_release_rx,
            },
        }));
        first_releases.push(first_release_tx);
        second_releases.push(second_release_tx);
    }
    for _ in 0..BROWSER_INPUT_WORKER_COUNT {
        first_entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    }

    let (observed_tx, observed_rx) = std::sync::mpsc::channel();
    assert!(dispatcher.enqueue(BrowserInputEvent {
        surface_id: 99,
        surface: SurfaceHandle::RemoteBrowserUnsupported,
        kind: BrowserInputKind::TestProbe(observed_tx),
    }));
    first_releases[0].send(()).unwrap();

    assert_eq!(
        observed_rx.recv_timeout(Duration::from_millis(250)),
        Ok(99),
        "one surface dispatched a second blocking request before yielding its worker"
    );

    for release in first_releases.into_iter().skip(1).chain(second_releases) {
        let _ = release.send(());
    }
}

#[test]
fn scheduler_bounds_aggregate_surface_admission() {
    let dispatcher = BrowserInputDispatcher::spawn(|_| {}, |_| {}).unwrap();
    let releases = block_all_browser_input_workers(&dispatcher);
    let (observed_tx, _observed_rx) = std::sync::mpsc::channel();
    let mut accepted = 0;

    for surface_id in 1_000..1_300 {
        accepted += usize::from(dispatcher.enqueue(BrowserInputEvent {
            surface_id,
            surface: SurfaceHandle::RemoteBrowserUnsupported,
            kind: BrowserInputKind::TestProbe(observed_tx.clone()),
        }));
    }

    assert!(
        accepted < 300,
        "blocked workers admitted an unbounded set of retained per-surface queues"
    );
    for release in releases {
        let _ = release.send(());
    }
}

#[test]
fn synthetic_key_press_uses_one_global_admission() {
    let dispatcher = BrowserInputDispatcher::spawn(|_| {}, |_| {}).unwrap();
    let releases = block_all_browser_input_workers(&dispatcher);
    let (observed_tx, _observed_rx) = std::sync::mpsc::channel();
    for index in BROWSER_INPUT_WORKER_COUNT..GLOBAL_QUEUE_CAPACITY - 1 {
        let surface_id = index as u64 % BROWSER_INPUT_WORKER_COUNT as u64 + 1;
        assert!(dispatcher.enqueue(BrowserInputEvent {
            surface_id,
            surface: SurfaceHandle::RemoteBrowserUnsupported,
            kind: BrowserInputKind::TestProbe(observed_tx.clone()),
        }));
    }
    let lane = dispatcher.lanes.lock().unwrap().get(&1).unwrap().clone();
    let queued_before = lane.lane.queued_count.load(Ordering::Acquire);

    assert!(
        dispatcher.enqueue(key_press_event(1)),
        "one synthesized key press did not fit the scheduler's last event slot"
    );
    assert_eq!(
        lane.lane.queued_count.load(Ordering::Acquire),
        queued_before + 1,
        "one synthesized key press consumed multiple global admissions"
    );
    assert!(
        !dispatcher.enqueue(reload_event(1)),
        "the single key-press command did not consume the last global slot"
    );
    for release in releases {
        let _ = release.send(());
    }
}

#[test]
fn synthetic_key_press_respects_the_surface_lane_capacity() {
    let dispatcher = BrowserInputDispatcher::spawn(|_| {}, |_| {}).unwrap();
    let releases = block_all_browser_input_workers(&dispatcher);

    for _ in 0..QUEUE_CAPACITY {
        assert!(
            dispatcher.enqueue(key_press_event(1)),
            "a surface lane rejected a key press before reaching its capacity"
        );
    }
    assert!(
        !dispatcher.enqueue(key_press_event(1)),
        "one stalled surface bypassed its lane capacity with synthesized key presses"
    );
    for release in releases {
        let _ = release.send(());
    }
}

#[test]
fn idle_surface_lanes_do_not_exhaust_scheduler_admission() {
    let dispatcher = BrowserInputDispatcher::spawn(|_| {}, |_| {}).unwrap();
    let (observed_tx, observed_rx) = std::sync::mpsc::channel();

    for surface_id in 1..=MAX_BROWSER_INPUT_SURFACES as u64 {
        assert!(dispatcher.enqueue(BrowserInputEvent {
            surface_id,
            surface: SurfaceHandle::RemoteBrowserUnsupported,
            kind: BrowserInputKind::TestProbe(observed_tx.clone()),
        }));
    }
    for _ in 0..MAX_BROWSER_INPUT_SURFACES {
        observed_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    }
    let idle_deadline = Instant::now() + Duration::from_secs(1);
    while Instant::now() < idle_deadline
        && dispatcher
            .lanes
            .lock()
            .unwrap()
            .values()
            .any(|lane| lane.scheduled.load(Ordering::Acquire) || lane.has_pending())
    {
        std::thread::yield_now();
    }

    let next_surface = MAX_BROWSER_INPUT_SURFACES as u64 + 1;
    assert!(
        dispatcher.enqueue(BrowserInputEvent {
            surface_id: next_surface,
            surface: SurfaceHandle::RemoteBrowserUnsupported,
            kind: BrowserInputKind::TestProbe(observed_tx),
        }),
        "drained lanes permanently disabled input for a later live browser surface"
    );
    assert_eq!(
        observed_rx.recv_timeout(Duration::from_secs(1)),
        Ok(next_surface),
        "the later browser surface was admitted but never dispatched"
    );
    assert!(
        dispatcher.lanes.lock().unwrap().len() <= MAX_BROWSER_INPUT_SURFACES,
        "evicting an idle lane exceeded the scheduler's surface-state bound"
    );
}

#[test]
fn scheduler_examines_each_backlog_event_once() {
    const BACKLOG: usize = 128;
    let lane = ScheduledSurfaceInputLane::new(7, BACKLOG);
    for _ in 0..BACKLOG {
        assert!(lane.lane.enqueue(reload_event(7)));
    }

    for _ in 0..BACKLOG {
        let (event, discarded) = lane.take_next();
        assert!(event.is_some());
        assert!(discarded.is_empty());
    }

    assert_eq!(lane.lane.queued_count.load(Ordering::Acquire), 0);
    assert!(
        lane.examined_events.load(Ordering::Relaxed) <= BACKLOG * 2,
        "dispatch repeatedly rescanned the retained backlog"
    );
}

#[test]
fn scheduler_rejects_an_event_over_the_global_byte_budget() {
    let dispatcher = BrowserInputDispatcher::spawn(|_| {}, |_| {}).unwrap();

    assert!(
        !dispatcher.enqueue(BrowserInputEvent {
            surface_id: 99,
            surface: SurfaceHandle::RemoteBrowserUnsupported,
            kind: BrowserInputKind::InsertText("x".repeat(GLOBAL_QUEUE_MAX_BYTES + 1)),
        }),
        "one oversized event bypassed the scheduler's retained-byte bound"
    );
    assert!(
        dispatcher.lanes.lock().unwrap().is_empty(),
        "a rejected oversized event left an empty retained surface lane"
    );
}

#[test]
fn forgetting_a_ready_surface_purges_its_retained_lane() {
    let dispatcher = BrowserInputDispatcher::spawn(|_| {}, |_| {}).unwrap();
    let releases = block_all_browser_input_workers(&dispatcher);
    let dropped = Arc::new(AtomicBool::new(false));
    assert!(dispatcher.enqueue(resize_event_with_probe(99, 80, dropped.clone())));

    dispatcher.forget_surface(99);

    assert!(
        dropped.load(Ordering::Acquire),
        "forgetting a ready surface retained its canceled queued event"
    );
    assert!(
        !dispatcher
            .scheduler
            .as_ref()
            .unwrap()
            .ready
            .lock()
            .unwrap()
            .lanes
            .iter()
            .any(|lane| lane.lane.expected_surface_id == Some(99)),
        "forgetting a ready surface left its lane in the global scheduler"
    );
    assert_eq!(
        dispatcher.scheduler.as_ref().unwrap().admission.lock().unwrap().queued_events,
        BROWSER_INPUT_WORKER_COUNT,
        "purging the retired lane did not release its global event admission"
    );
    for release in releases {
        let _ = release.send(());
    }
}

#[test]
fn many_surfaces_use_a_bounded_worker_count() {
    const MAX_BROWSER_INPUT_WORKERS: usize = 8;
    let dispatcher = BrowserInputDispatcher::spawn(|_| {}, |_| {}).unwrap();
    let (observed_tx, observed_rx) = std::sync::mpsc::channel();

    for surface_id in 1..=32 {
        assert!(dispatcher.enqueue(BrowserInputEvent {
            surface_id,
            surface: SurfaceHandle::RemoteBrowserUnsupported,
            kind: BrowserInputKind::TestProbe(observed_tx.clone()),
        }));
    }
    for _ in 1..=32 {
        observed_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    }

    assert!(
        dispatcher.worker_count() <= MAX_BROWSER_INPUT_WORKERS,
        "visiting browser surfaces must not create an unbounded OS-thread-per-surface pool"
    );
}

fn positions(batch: &[BrowserInputEvent]) -> Vec<(&'static str, SurfaceId)> {
    batch
        .iter()
        .map(|event| match event.kind {
            BrowserInputKind::Mouse { event_type, .. } => (event_type, event.surface_id),
            _ => ("other", event.surface_id),
        })
        .collect()
}

#[test]
fn consecutive_moves_on_same_surface_keep_latest_only() {
    let mut batch = vec![move_event(1, 1.0), move_event(1, 2.0), move_event(1, 3.0)];
    coalesce_browser_events(&mut batch);
    assert_eq!(batch.len(), 1);
    match batch[0].kind {
        BrowserInputKind::Mouse { x, .. } => assert_eq!(x, 3.0),
        _ => panic!("expected mouse event"),
    }
}

#[test]
fn consecutive_presentations_on_same_surface_keep_latest_only() {
    let mut batch =
        vec![presentation_event(1, 7), presentation_event(1, 8), presentation_event(1, 9)];
    coalesce_browser_events(&mut batch);

    assert_eq!(batch.len(), 1);
    assert!(matches!(batch[0].kind, BrowserInputKind::Presented { frame_seq: 9 }));
}

#[test]
fn clicks_break_coalescing_and_keep_order() {
    let mut batch = vec![move_event(1, 1.0), click_event(1), move_event(1, 2.0)];
    coalesce_browser_events(&mut batch);
    assert_eq!(positions(&batch), vec![("mouseMoved", 1), ("mousePressed", 1), ("mouseMoved", 1)]);
}

#[test]
fn moves_on_different_surfaces_are_kept() {
    let mut batch = vec![move_event(1, 1.0), move_event(2, 1.0)];
    coalesce_browser_events(&mut batch);
    assert_eq!(batch.len(), 2);
}

#[test]
fn consecutive_resizes_keep_latest_without_crossing_clicks() {
    let mut batch = vec![resize_event(1, 80), resize_event(1, 100), click_event(1)];
    coalesce_browser_events(&mut batch);
    assert_eq!(batch.len(), 2);
    match batch[0].kind {
        BrowserInputKind::Resize { cols, .. } => assert_eq!(cols, 100),
        _ => panic!("expected resize event"),
    }
    assert!(matches!(batch[1].kind, BrowserInputKind::Mouse { .. }));
}

#[test]
fn resize_coalescing_stops_at_non_resize_input() {
    let mut batch = vec![resize_event(1, 80), click_event(1), resize_event(1, 100)];

    coalesce_browser_events(&mut batch);

    assert_eq!(batch.len(), 3);
    assert!(matches!(batch[0].kind, BrowserInputKind::Resize { cols: 80, .. }));
    assert!(matches!(batch[1].kind, BrowserInputKind::Mouse { .. }));
    assert!(matches!(batch[2].kind, BrowserInputKind::Resize { cols: 100, .. }));
}

#[test]
fn only_full_resizes_are_saved_for_fallback_delivery() {
    let (lane, blocked) = SurfaceInputLane::blocked(1, 1);
    let latest_resizes = lane.latest_resizes.clone();

    let _ = lane.enqueue(click_event(1));
    let _ = lane.enqueue(resize_event(1, 132));
    assert!(matches!(blocked.rx.recv().unwrap().event.kind, BrowserInputKind::Mouse { .. }));
    assert!(matches!(
        latest_resizes.lock().unwrap().get(&(1, 1)).map(|event| &event.event.kind),
        Some(BrowserInputKind::Resize { cols: 132, .. })
    ));

    latest_resizes.lock().unwrap().clear();
    let _ = lane.enqueue(resize_event(1, 144));
    assert!(latest_resizes.lock().unwrap().is_empty());
    assert!(matches!(
        blocked.rx.recv().unwrap().event.kind,
        BrowserInputKind::Resize { cols: 144, .. }
    ));

    drop(blocked);
    let _ = lane.enqueue(resize_event(1, 156));
    assert!(latest_resizes.lock().unwrap().is_empty());
}

#[test]
fn resize_claim_lives_through_queue_fallback_replacement_and_disconnect() {
    let (lane, blocked) = SurfaceInputLane::blocked(1, 1);
    let latest_resizes = lane.latest_resizes.clone();
    let accepted = Arc::new(AtomicBool::new(false));
    let _ = lane.enqueue(resize_event_with_probe(1, 80, accepted.clone()));
    assert!(!accepted.load(Ordering::Acquire));
    drop(blocked.rx.recv().unwrap());
    assert!(accepted.load(Ordering::Acquire));

    let _ = lane.enqueue(click_event(1));
    let replaced = Arc::new(AtomicBool::new(false));
    let retained = Arc::new(AtomicBool::new(false));
    let _ = lane.enqueue(resize_event_with_probe(1, 100, replaced.clone()));
    let _ = lane.enqueue(resize_event_with_probe(1, 120, retained.clone()));
    assert!(replaced.load(Ordering::Acquire));
    assert!(!retained.load(Ordering::Acquire));
    latest_resizes.lock().unwrap().clear();
    assert!(retained.load(Ordering::Acquire));

    drop(blocked);
    let disconnected = Arc::new(AtomicBool::new(false));
    let _ = lane.enqueue(resize_event_with_probe(1, 140, disconnected.clone()));
    assert!(disconnected.load(Ordering::Acquire));
}

#[test]
fn resize_claim_drops_after_dispatch_failure() {
    let dropped = Arc::new(AtomicBool::new(false));
    let event = resize_event_with_probe(1, 80, dropped.clone());
    assert!(dispatch(&event).is_err());
    assert!(!dropped.load(Ordering::Acquire));
    drop(event);
    assert!(dropped.load(Ordering::Acquire));
}

#[test]
fn failed_resize_is_reported_and_same_geometry_is_suppressed() {
    let (failure_tx, failure_rx) = std::sync::mpsc::channel();
    let dispatcher = BrowserInputDispatcher::spawn(
        move |failure| {
            failure_tx.send(failure).unwrap();
        },
        |_| {},
    )
    .unwrap();

    let callback_called = Arc::new(AtomicBool::new(false));
    let accepted = Arc::new(AtomicBool::new(true));
    let mut first = resize_event(7, 100);
    if let BrowserInputKind::Resize { on_result, .. } = &mut first.kind {
        let callback_called = callback_called.clone();
        let accepted_result = accepted.clone();
        *on_result = Some(Box::new(move |reservation_id| {
            accepted_result.store(reservation_id.is_some(), Ordering::Release);
            callback_called.store(true, Ordering::Release);
        }));
    }
    let _ = dispatcher.enqueue(first);
    let failure = failure_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert!(callback_called.load(Ordering::Acquire));
    assert!(!accepted.load(Ordering::Acquire));
    assert_eq!((failure.surface_id, failure.cols, failure.rows), (7, 100, 24));
    assert!(dispatcher.resize_failed(7, (100, 24)));

    let dropped = Arc::new(AtomicBool::new(false));
    let _ = dispatcher.enqueue(resize_event_with_probe(7, 100, dropped.clone()));
    assert!(dropped.load(Ordering::Acquire));
    assert!(failure_rx.try_recv().is_err());

    dispatcher.failed_resizes.lock().unwrap().get_mut(&7).unwrap().retry_after =
        Some(Instant::now() - Duration::from_millis(1));
    assert!(dispatcher.resize_retry_due());
    assert!(!dispatcher.visible_resize_retry_due(&HashSet::new()));
    assert!(!dispatcher.resize_retry_due());
    dispatcher.failed_resizes.lock().unwrap().insert(
        7,
        FailedBrowserResize {
            desired: (100, 24),
            attempts: 1,
            retry_after: Some(Instant::now() - Duration::from_millis(1)),
        },
    );
    assert!(dispatcher.visible_resize_retry_due(&HashSet::from([7])));
    let _ = dispatcher.enqueue(resize_event(7, 100));
    failure_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert_eq!(dispatcher.failed_resizes.lock().unwrap().get(&7).unwrap().attempts, 2);

    dispatcher.forget_surface(7);
    assert!(!dispatcher.resize_failed(7, (100, 24)));
}

#[test]
fn forgetting_surface_cancels_queued_resize_and_clears_fallback() {
    let (lane, blocked) = SurfaceInputLane::blocked(7, 1);
    let latest_resizes = lane.latest_resizes.clone();
    let queued = Arc::new(AtomicBool::new(false));
    let fallback = Arc::new(AtomicBool::new(false));
    let _ = lane.enqueue(resize_event_with_probe(7, 80, queued.clone()));
    let _ = lane.enqueue(resize_event_with_probe(7, 100, fallback.clone()));

    let _ = lane.cancel_surface(7);

    assert!(!queued.load(Ordering::Acquire));
    assert!(fallback.load(Ordering::Acquire));
    assert!(latest_resizes.lock().unwrap().is_empty());
    let queued_event = blocked.rx.recv().unwrap();
    assert!(queued_event.lifetime.load(Ordering::Acquire));
    drop(queued_event);
    assert!(queued.load(Ordering::Acquire));
}

#[test]
fn persistent_resize_failure_requires_geometry_or_lifecycle_recovery() {
    let mut failure = None;
    for _ in 0..6 {
        failure = Some(next_failed_browser_resize(failure, (100, 24)));
    }
    let failure = failure.unwrap();

    assert_eq!(failure.attempts, 6);
    assert!(failure.retry_after.is_none());
    assert!(failed_browser_resize_blocks(failure, (100, 24)));
    assert!(!failed_browser_resize_blocks(failure, (120, 24)));
}

#[test]
fn dropped_resize_slot_delivers_latest_geometry_after_queued_input() {
    let mut batch = vec![sequenced(0, click_event(1))];
    let latest = HashMap::from([((1, 0), sequenced(1, resize_event(1, 132)))]);

    merge_fallback_events(&mut batch, latest, Vec::new());

    assert_eq!(batch.len(), 2);
    assert!(matches!(batch[0].event.kind, BrowserInputKind::Mouse { .. }));
    assert!(matches!(batch[1].event.kind, BrowserInputKind::Resize { cols: 132, .. }));
}

#[test]
fn rejected_resize_stays_before_later_accepted_input() {
    let (lane, blocked) = SurfaceInputLane::blocked(1, 1);
    let latest_resizes = lane.latest_resizes.clone();

    let _ = lane.enqueue(click_event(1));
    let _ = lane.enqueue(resize_event(1, 132));
    let first = blocked.rx.recv().unwrap();
    let _ = lane.enqueue(click_event(1));
    let _ = lane.enqueue(resize_event(1, 144));
    let mut batch = vec![first];
    finish_ordered_batch(
        &blocked.rx,
        &lane.order,
        &latest_resizes,
        &lane.retained_releases,
        &mut batch,
    );

    assert_eq!(batch.iter().map(|event| event.sequence).collect::<Vec<_>>(), vec![0, 1, 2, 3]);
    assert!(matches!(batch[0].event.kind, BrowserInputKind::Mouse { .. }));
    assert!(matches!(batch[1].event.kind, BrowserInputKind::Resize { cols: 132, .. }));
    assert!(matches!(batch[2].event.kind, BrowserInputKind::Mouse { .. }));
    assert!(matches!(batch[3].event.kind, BrowserInputKind::Resize { cols: 144, .. }));
}
