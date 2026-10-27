//! p08-startup-094: the headless owner's held background work starts once,
//! on the owner thread, when the first-client gate fires, and never when the
//! owner stops first.

use std::sync::mpsc;
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use cmux_threads::{ThreadInfo, ThreadQos};
use cmux_tui_core::{Mux, MuxEvent};

use crate::owner_start::{
    FIRST_CLIENT_THREAD, FirstClientGate, OwnerBackground, OwnerWork, OwnerWorkPlan,
    lock_thread_rows,
};

const WAIT: Duration = Duration::from_secs(10);

/// Set by [`gate_fired`], the gate's wake in these tests.
static FIRED: (Mutex<bool>, Condvar) = (Mutex::new(false), Condvar::new());

/// Records that the gate marked the work due, then wakes the owner loop as
/// the daemon's wake does.
fn gate_fired() {
    let (lock, fired) = &FIRED;
    *lock.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = true;
    fired.notify_all();
    super::wake_headless();
}

fn wait_for_gate() {
    let (lock, fired) = &FIRED;
    let guard = lock.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let (mut guard, _) = fired
        .wait_timeout_while(guard, WAIT, |fired| !*fired)
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    assert!(std::mem::take(&mut *guard), "the attach marks the work due");
}

fn row(name: &str) -> Option<ThreadInfo> {
    cmux_threads::snapshot().into_iter().find(|row| row.name == name)
}

/// The row of `name` once its thread has registered (it does so as its
/// first step, on its own thread).
fn registered(name: &str) -> ThreadInfo {
    let deadline = Instant::now() + WAIT;
    loop {
        if let Some(row) = row(name) {
            return row;
        }
        assert!(Instant::now() < deadline, "{name} never registered");
        std::thread::sleep(Duration::from_millis(2));
    }
}

/// A plan whose start shows: an interactive plan with no checks still
/// starts the journal plugin supervisor and the idle reaper.
fn plan(dir: &tempfile::TempDir) -> OwnerWorkPlan {
    OwnerWorkPlan { checks: None, journal_socket: dir.path().join("cmux.sock"), headless: false }
}

fn held(mux: &Arc<Mux>, dir: &tempfile::TempDir) -> OwnerBackground {
    let gate = FirstClientGate::start(mux, gate_fired);
    assert!(gate.is_ok(), "the gate thread starts");
    OwnerBackground::after_first_client(mux, plan(dir), gate)
}

fn stop(work: OwnerWork) {
    if let Some(reaper) = work.idle_terminal_reaper {
        reaper.stop();
    }
    #[cfg(unix)]
    if let Some(poller) = work.machine_usage_poller {
        poller.stop();
    }
}

#[test]
fn the_held_work_starts_on_the_owner_thread_once_the_first_client_attaches() {
    let _rows = lock_thread_rows();
    let dir = tempfile::tempdir().unwrap();
    let mux = Mux::new("owner-background-attach", Default::default());
    let background = held(&mux, &dir);
    assert!(row(cmux_tui_core::IDLE_CLOSE_THREAD).is_none(), "nothing starts before the gate");
    assert!(row(cmux_tui_core::JOURNAL_PLUGIN_THREAD).is_none());

    mux.emit(MuxEvent::ClientAttached {
        client: 1,
        transport: "unix".into(),
        name: None,
        kind: None,
    });
    wait_for_gate();
    // The owner loop runs on its own thread (it registers as `main`). It
    // sees the due mark on its first pass and starts the work there; the
    // second check of `stopped` ends it. A loop that never starts the work
    // waits on its condvar and the receive below times out.
    let (done, returned) = mpsc::channel();
    std::thread::spawn(move || {
        let mut background = background;
        let checks = std::cell::Cell::new(0);
        super::wait_for_stop(
            || {
                checks.set(checks.get() + 1);
                checks.get() > 1
            },
            &mut background,
        );
        let _ = done.send(background);
    });
    let background = returned.recv_timeout(WAIT).expect("the owner loop starts the due work");
    assert!(row(FIRST_CLIENT_THREAD).is_none(), "starting the work joins the gate thread");

    let work = background.into_work();
    assert!(work.idle_terminal_reaper.is_some(), "the idle reaper started");
    let reaper = registered(cmux_tui_core::IDLE_CLOSE_THREAD);
    assert_eq!(reaper.declared, cmux_tui_core::IDLE_CLOSE_QOS);
    assert_eq!(reaper.declared, ThreadQos::Utility);
    let journal = registered(cmux_tui_core::JOURNAL_PLUGIN_THREAD);
    assert_eq!(journal.declared, cmux_tui_core::JOURNAL_PLUGIN_QOS);
    assert_eq!(journal.declared, ThreadQos::UserInitiated, "a nice-0 parent for the plugin");
    stop(work);
    assert!(row(cmux_tui_core::IDLE_CLOSE_THREAD).is_none(), "stop joins the reaper");
    mux.shutdown();
}

#[test]
fn an_owner_that_stops_before_its_first_client_starts_nothing() {
    let _rows = lock_thread_rows();
    let dir = tempfile::tempdir().unwrap();
    let mux = Mux::new("owner-background-stop", Default::default());
    let background = held(&mux, &dir);
    let work = background.into_work();
    assert!(work.idle_terminal_reaper.is_none(), "no idle reaper");
    #[cfg(unix)]
    assert!(work.machine_usage_poller.is_none(), "no usage poller");
    assert!(row(FIRST_CLIENT_THREAD).is_none(), "into_work joins the gate thread");
    assert!(row(cmux_tui_core::IDLE_CLOSE_THREAD).is_none());
    assert!(row(cmux_tui_core::JOURNAL_PLUGIN_THREAD).is_none());
    // An attach after the stop starts nothing either.
    mux.emit(MuxEvent::ClientAttached {
        client: 1,
        transport: "unix".into(),
        name: None,
        kind: None,
    });
    assert!(row(cmux_tui_core::IDLE_CLOSE_THREAD).is_none());
    mux.shutdown();
}
