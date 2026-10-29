use std::sync::mpsc::{Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use cmux_panic_log::{Failure, FailureSink, FatalReason, FatalReport, Supervisor};

use super::{Fatal, ShutdownBehavior, spawn_on};

/// Records fatal reports instead of ending the test process.
struct Recording {
    reports: Mutex<Sender<FatalReport>>,
}

impl FailureSink for Recording {
    fn fatal(&self, report: &FatalReport) {
        let _ = self.reports.lock().unwrap().send(report.clone());
    }
}

fn recording() -> (Supervisor, std::sync::mpsc::Receiver<FatalReport>) {
    let (sender, reports) = channel();
    (Supervisor::new(Arc::new(Recording { reports: Mutex::new(sender) })), reports)
}

#[test]
fn a_panicking_worker_is_fatal_and_named() {
    let (supervisor, reports) = recording();
    let thread = spawn_on(
        &supervisor,
        "supervised-panic-test".into(),
        None,
        Fatal,
        ShutdownBehavior::Continue,
        || -> () { panic!("injected worker failure") },
    )
    .expect("thread starts");
    assert!(thread.join().is_err(), "a failed body has no result");
    let report = reports.recv_timeout(Duration::from_secs(10)).expect("the failure is reported");
    assert_eq!(report.worker, "supervised-panic-test");
    assert_eq!(
        report.reason,
        FatalReason::Failed(Failure::Panicked { message: "injected worker failure".into() })
    );
}

#[test]
fn join_returns_the_body_value_and_the_row_is_gone() {
    let (supervisor, reports) = recording();
    let name = "supervised-row-test";
    let thread = spawn_on(
        &supervisor,
        name.into(),
        Some(super::Registered::at(cmux_threads::ThreadQos::Utility)),
        Fatal,
        ShutdownBehavior::Continue,
        move || cmux_threads::snapshot().iter().any(|row| row.name == name),
    )
    .expect("thread starts");
    assert_eq!(thread.name(), name);
    assert!(!thread.is_current());
    assert_eq!(thread.join().ok(), Some(true), "the body ran registered at its QoS");
    assert!(
        cmux_threads::snapshot().iter().all(|row| row.name != name),
        "the row is gone once join returns"
    );
    assert!(reports.try_recv().is_err(), "a body that returns is no failure");
}

#[test]
fn an_unpark_before_the_thread_begins_wakes_its_first_park() {
    let (supervisor, _reports) = recording();
    let (go, wait) = channel::<()>();
    let thread = spawn_on(
        &supervisor,
        "supervised-unpark-test".into(),
        None,
        Fatal,
        ShutdownBehavior::Continue,
        move || {
            // Holds the thread before its body parks, so the unpark below can
            // land first; a lost unpark leaves join waiting for ever.
            let _ = wait.recv();
            std::thread::park();
        },
    )
    .expect("thread starts");
    thread.unparker().unpark();
    let _ = go.send(());
    assert!(thread.join().is_ok());
}

#[test]
fn is_finished_turns_true_when_the_body_returns() {
    let (supervisor, _reports) = recording();
    let (go, wait) = channel::<()>();
    let thread = spawn_on(
        &supervisor,
        "supervised-finished-test".into(),
        None,
        Fatal,
        ShutdownBehavior::Continue,
        move || {
            let _ = wait.recv();
        },
    )
    .expect("thread starts");
    assert!(!thread.is_finished());
    drop(go);
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while !thread.is_finished() {
        assert!(std::time::Instant::now() < deadline, "the body returned");
        std::thread::yield_now();
    }
    assert!(thread.join().is_ok());
}
