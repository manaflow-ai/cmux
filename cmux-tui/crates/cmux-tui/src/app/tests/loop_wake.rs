//! Tests: what wakes the idle event loop, which waits with no timeout:
//! its deadlines and every shutdown its condition reads.

use super::*;
use crate::app::run::wake_loop_on_shutdown;
use crate::config::SidebarView;

/// A wake the loop missed shows as a wait this long: the fallback below
/// ends the wait then, so a broken wake fails its time bound, not by hanging.
const MISSED_WAKE_FALLBACK: Duration = Duration::from_secs(3);
const WAKE_BOUND: Duration = Duration::from_secs(2);

/// Sends a harmless event after `MISSED_WAKE_FALLBACK`.
fn wake_after_fallback(events: &crossbeam_channel::Sender<AppEvent>) {
    let events = events.clone();
    std::thread::spawn(move || {
        std::thread::sleep(MISSED_WAKE_FALLBACK);
        let _ = events.send(AppEvent::HostInputReady);
    });
}

#[test]
fn a_passed_deadline_wakes_the_loop_at_once_until_a_turn_serves_it() {
    let mux = Mux::new("loop-wake-deadline-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.sidebar_visible = false;
    let now = Instant::now();
    assert_eq!(app.next_idle_wake(None, now), None, "nothing is due without an event");

    let toast_at = now + Duration::from_millis(1500);
    let retry_at = now + Duration::from_secs(5);
    app.toast = Some(Toast { text: "saved".to_string(), deadline: toast_at });
    app.sidebar_plugin_retry_at = Some(retry_at);
    assert_eq!(app.next_idle_wake(Some(now), now), Some(toast_at), "the soonest deadline");

    // The toast's deadline passed after the last turn's consumers ran (a
    // busy turn's render): nothing served it, so the wait ends at once.
    let later = toast_at + Duration::from_millis(10);
    assert_eq!(app.next_idle_wake(Some(now), later), Some(later));
    assert_eq!(app.next_idle_wake(None, later), Some(later));

    // Consumers that ran after it saw it as passed: it is not waited for again.
    assert_eq!(app.next_idle_wake(Some(toast_at), later), Some(retry_at));
}

#[test]
fn a_passed_files_refresh_wakes_the_loop_however_recent_the_last_turn() {
    let mux = Mux::new("loop-wake-files-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.config.sidebar.plugin = None;
    app.sidebar_view = SidebarView::Files;
    app.sidebar_visible = true;
    // Only an idle wake refreshes the files view, so a turn never serves it.
    let refresh_at = app.sidebar_files.next_refresh_at();
    let after = refresh_at + Duration::from_millis(1);
    assert_eq!(app.next_idle_wake(Some(after), after), Some(after));

    app.sidebar_visible = false;
    assert_eq!(app.next_idle_wake(Some(after), after), None, "a hidden view has no refresh");
}

#[test]
fn idle_event_loop_expires_a_passed_toast_without_another_event() {
    let mux = Mux::new("loop-wake-toast-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.sidebar_visible = false;
    app.toast = Some(Toast { text: "saved".to_string(), deadline: Instant::now() });
    app.timeout_drain_hook = Some(Box::new(|app| app.quit = true));
    let (events, receiver) = crossbeam_channel::unbounded::<AppEvent>();
    // The only sender: dropping it ends a loop that never woke for the toast.
    std::thread::spawn(move || {
        std::thread::sleep(MISSED_WAKE_FALLBACK);
        drop(events);
    });
    let mut terminal = Terminal::new(TestBackend::new(100, 20)).unwrap();

    let started = Instant::now();
    app.event_loop(&mut terminal, receiver).unwrap();

    assert!(app.toast.is_none(), "the loop slept past the toast's end");
    assert!(started.elapsed() < WAKE_BOUND, "{:?}", started.elapsed());
}

#[test]
fn idle_event_loop_waits_for_the_next_event_without_a_timer() {
    let mux = Mux::new("loop-wake-idle-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.sidebar_visible = false;
    let timed_out = Arc::new(AtomicBool::new(false));
    let timed_out_in_hook = timed_out.clone();
    app.timeout_drain_hook =
        Some(Box::new(move |_| timed_out_in_hook.store(true, Ordering::Relaxed)));
    let (events, receiver) = crossbeam_channel::unbounded::<AppEvent>();
    // Longer than the old 250 ms idle timeout: the loop must still be
    // waiting for the channel, not woken by a timer.
    let closer = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(600));
        drop(events);
    });
    let mut terminal = Terminal::new(TestBackend::new(100, 20)).unwrap();

    app.event_loop(&mut terminal, receiver).unwrap();
    closer.join().unwrap();

    assert!(!timed_out.load(Ordering::Relaxed), "an idle loop woke on a timer");
}

/// Runs an idle loop wired as `run` wires it, has `request` ask for a
/// shutdown after the loop is waiting, and returns how long the loop ran.
fn idle_loop_run_time(
    app: &mut App,
    local: Arc<Mux>,
    request: impl FnOnce() + Send + 'static,
) -> Duration {
    app.sidebar_visible = false;
    let (events, receiver) = crossbeam_channel::unbounded::<AppEvent>();
    wake_loop_on_shutdown(&Session::Local(local), app.owner_mux.as_deref(), &events);
    wake_after_fallback(&events);
    let requester = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(100));
        request();
    });
    let mut terminal = Terminal::new(TestBackend::new(100, 20)).unwrap();

    let started = Instant::now();
    app.event_loop(&mut terminal, receiver).unwrap();
    let ran = started.elapsed();
    requester.join().unwrap();
    ran
}

#[test]
fn idle_event_loop_ends_on_a_local_daemon_shutdown_request() {
    let mux = Mux::new("loop-wake-local-shutdown-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux.clone()));

    let requested = mux.clone();
    let ran = idle_loop_run_time(&mut app, mux, move || requested.request_daemon_shutdown());

    assert!(ran < WAKE_BOUND, "the idle loop missed the daemon shutdown: {ran:?}");
}

#[test]
fn idle_event_loop_ends_on_an_owner_daemon_shutdown_request() {
    let local = Mux::new("loop-wake-owner-local-test", SurfaceOptions::default());
    let owner = Mux::new("loop-wake-owner-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(local.clone()));
    app.owner_mux = Some(owner.clone());

    let ran = idle_loop_run_time(&mut app, local, move || owner.request_daemon_shutdown());

    assert!(ran < WAKE_BOUND, "the idle loop missed the owner's shutdown: {ran:?}");
}

/// The signal handler and its flag are process-wide, so the signal runs in
/// a child process of this test binary.
#[cfg(unix)]
#[test]
fn idle_event_loop_ends_on_a_termination_signal() {
    use wait_timeout::ChildExt;

    const CHILD_ENV: &str = "CMUX_LOOP_WAKE_SIGNAL_CHILD";
    if std::env::var_os(CHILD_ENV).is_some() {
        crate::install_signal_handlers().unwrap();
        let mux = Mux::new("loop-wake-signal-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux.clone()));
        let ran = idle_loop_run_time(&mut app, mux, || {
            // SAFETY: kill(2) with this process's own id and a signal whose
            // handler is installed above.
            assert_eq!(unsafe { libc::kill(libc::getpid(), libc::SIGTERM) }, 0);
        });
        assert!(crate::shutdown_requested());
        assert!(ran < WAKE_BOUND, "the idle loop missed the signal: {ran:?}");
        return;
    }

    let mut child = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "app::tests::loop_wake::idle_event_loop_ends_on_a_termination_signal",
            "--exact",
            "--nocapture",
        ])
        .env(CHILD_ENV, "1")
        .spawn()
        .unwrap();
    let Some(status) = child.wait_timeout(Duration::from_secs(60)).unwrap() else {
        let _ = child.kill();
        let _ = child.wait();
        panic!("the signal child did not finish");
    };
    assert!(status.success(), "the signal child failed: {status}");
}
