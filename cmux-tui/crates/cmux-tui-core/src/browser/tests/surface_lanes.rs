//! p01-process-206: a browser surface's events and commands run as lanes on
//! the mux's browser pool, never on threads of the surface's own.

use super::*;
use crate::browser::lanes::BASE_WORKERS;

const _: () = assert!(BASE_WORKERS <= 2, "20 browser surfaces may add at most 2 threads");

fn mux_surface(mux: &Arc<Mux>, id: u64) -> Arc<Surface> {
    new_surface(
        id,
        "https://example.test".into(),
        (10, 5),
        (8, 16),
        &SurfaceOptions::default(),
        Arc::downgrade(mux),
    )
    .unwrap()
}

/// Waits until `check` holds (test-only polling of the pool's counter).
fn eventually(check: impl Fn() -> bool) -> bool {
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        if check() {
            return true;
        }
        thread::sleep(Duration::from_millis(2));
    }
    check()
}

/// Twenty surfaces that each ran a command leave at most the pool's base
/// workers alive, and idle surfaces start none.
#[test]
fn twenty_browser_surfaces_add_at_most_two_threads() {
    let mux = Mux::new("browser-lanes-twenty", SurfaceOptions::default());
    let lanes = mux.browser_lanes();
    let surfaces = (1..=20).map(|id| mux_surface(&mux, id)).collect::<Vec<_>>();
    assert_eq!(lanes.live_workers(), 0, "idle browser surfaces started workers");

    let mut ran = Vec::new();
    for surface in &surfaces {
        let browser = surface.as_browser().unwrap();
        let (entered, started) = mpsc::channel();
        let (release, held) = mpsc::channel();
        release.send(()).unwrap();
        assert!(browser.enqueue_test_command(BrowserCommand::Hold { entered, release: held }));
        ran.push(started);
    }
    for started in ran {
        started.recv_timeout(Duration::from_secs(5)).expect("a surface's command ran");
    }
    assert!(
        eventually(|| lanes.live_workers() <= BASE_WORKERS),
        "20 browser surfaces kept {} lane workers",
        lanes.live_workers()
    );
    for surface in &surfaces {
        surface.as_browser().unwrap().kill();
    }
}

/// A surface whose command is stuck (a CDP call to a wedged page) never
/// delays another surface's command, as its own thread never did.
#[test]
fn a_stuck_surface_command_never_delays_another_surface() {
    let mux = Mux::new("browser-lanes-stuck", SurfaceOptions::default());
    let stuck = (1..=BASE_WORKERS as u64 + 1).map(|id| mux_surface(&mux, id)).collect::<Vec<_>>();
    let mut releases = Vec::new();
    for surface in &stuck {
        let (entered, started) = mpsc::channel();
        let (release, held) = mpsc::channel();
        assert!(
            surface
                .as_browser()
                .unwrap()
                .enqueue_test_command(BrowserCommand::Hold { entered, release: held })
        );
        started.recv_timeout(Duration::from_secs(5)).expect("a stuck surface delayed another");
        releases.push(release);
    }
    let other = mux_surface(&mux, 99);
    let (entered, started) = mpsc::channel();
    let (release, held) = mpsc::channel();
    release.send(()).unwrap();
    assert!(
        other
            .as_browser()
            .unwrap()
            .enqueue_test_command(BrowserCommand::Hold { entered, release: held })
    );
    started.recv_timeout(Duration::from_secs(5)).expect("a stuck surface delayed another");
    for release in releases {
        release.send(()).unwrap();
    }
}

/// A route's events queued before the event lane binds run once it binds,
/// in order, and its close ends the lane.
#[test]
fn an_event_lane_runs_events_queued_before_it_bound() {
    let surface = test_surface();
    let browser = surface.as_browser().unwrap();
    let route = Arc::new(crate::browser::SurfaceRoute::new());
    assert!(!route.deliver(cmux_tui_cdp::CdpEvent::TargetInfoChanged(cmux_tui_cdp::TargetInfo {
        target_id: "target-1".into(),
        session_id: None,
        title: "Queued title".into(),
        url: "https://queued.test/".into(),
    })));
    start_surface_events(surface.clone(), route.clone(), Weak::new(), Weak::new(), "s".into())
        .unwrap();
    assert!(eventually(|| browser.title() == "Queued title"));
    route.close("test close".into());
    assert!(eventually(|| browser.is_dead()));
}
