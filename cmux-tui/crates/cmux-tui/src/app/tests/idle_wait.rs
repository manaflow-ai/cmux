//! The idle loop blocks until an event when no timed work waits, and wakes
//! at the earliest deadline of the timed work it runs when some does.

use super::*;
use crate::app::idle_wait::IDLE_RETRY_FLOOR;
use crate::config::SidebarView;

fn idle_app(name: &str) -> App {
    let mut app = test_app(Session::Local(Mux::new(name, SurfaceOptions::default())));
    // The file sidebar refreshes on a timer while it shows.
    app.sidebar_visible = false;
    app
}

#[test]
fn an_idle_app_waits_for_an_event_with_no_timeout() {
    let app = idle_app("idle-wait-none-test");
    assert_eq!(app.idle_wait(Instant::now()), None);
}

#[test]
fn the_idle_wait_ends_at_the_earliest_timed_work() {
    let mut app = idle_app("idle-wait-deadline-test");
    let now = Instant::now();
    app.background_refresh_retry_at = Some(now + Duration::from_secs(8));
    assert_eq!(app.idle_wait(now), Some(Duration::from_secs(8)));
    app.sidebar_plugin_retry_at = Some(now + Duration::from_secs(3));
    assert_eq!(app.idle_wait(now), Some(Duration::from_secs(3)));

    // The file sidebar's refresh, only while it shows.
    app.sidebar_visible = true;
    app.sidebar_view = SidebarView::Files;
    let refresh = app.sidebar_files.next_refresh_at();
    assert_eq!(
        app.idle_wait(now),
        Some(
            refresh.saturating_duration_since(now).clamp(IDLE_RETRY_FLOOR, Duration::from_secs(3))
        )
    );
}

/// A deadline that passed while its work still waits on something else
/// wakes the loop at the old cadence, never in a spin.
#[test]
fn a_passed_deadline_waits_the_floor_not_zero() {
    let mut app = idle_app("idle-wait-floor-test");
    let now = Instant::now();
    app.machine_provider_reconnect_retry_at = Some(now - Duration::from_secs(1));
    assert_eq!(app.idle_wait(now), Some(IDLE_RETRY_FLOOR));
    // A reconnect already in flight wakes the loop with its completion.
    app.machine_action_in_flight = true;
    assert_eq!(app.idle_wait(now), None);
}

/// Input that waits for its surface to attach keeps retrying on the floor.
#[test]
fn waiting_input_keeps_the_retry_cadence() {
    let mut app = idle_app("idle-wait-input-test");
    app.defer_input(Event::Key(KeyEvent::new(KeyCode::Char('a'), KeyModifiers::NONE)));
    assert_eq!(app.idle_wait(Instant::now()), Some(IDLE_RETRY_FLOOR));
}

/// The loop itself: idle, it sleeps past the old 250 ms tick and leaves only
/// when its channel ends. Before, it woke every 250 ms to poll.
#[test]
fn the_idle_event_loop_does_not_wake_on_a_timer() {
    let mut app = idle_app("idle-loop-no-tick-test");
    let timed_out = Arc::new(AtomicBool::new(false));
    let timed_out_in_hook = timed_out.clone();
    app.timeout_drain_hook = Some(Box::new(move |_| {
        timed_out_in_hook.store(true, Ordering::Release);
    }));
    let (events, receiver) = crossbeam_channel::unbounded::<AppEvent>();
    let sender = std::thread::spawn(move || {
        std::thread::sleep(IDLE_RETRY_FLOOR * 3);
        drop(events);
    });
    let mut terminal = Terminal::new(TestBackend::new(100, 12)).unwrap();

    let started = Instant::now();
    app.event_loop(&mut terminal, receiver).unwrap();
    let ran = started.elapsed();
    sender.join().unwrap();

    // The loop must have waited for its channel to end, or it proved nothing.
    assert!(ran >= IDLE_RETRY_FLOOR * 3, "the loop ended before its channel did: {ran:?}");

    assert!(!timed_out.load(Ordering::Acquire), "the idle loop woke on a timer with nothing due");
}

/// A wake carries no work: the loop goes back to its wait.
#[test]
fn a_wake_event_is_handled_as_no_work() {
    let mut app = idle_app("idle-wake-event-test");
    assert_eq!(app.handle(AppEvent::Wake).unwrap(), RenderAction::None);
}
