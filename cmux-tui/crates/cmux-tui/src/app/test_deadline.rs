//! Deadline guard for `app::tests`.
//!
//! libtest cannot stop one hung test thread, so a deadlocked app test held the
//! hosted Linux job until its 40-minute timeout and hid every other result
//! (runs 42697795746 and 42711895482). Each test `App` carries this guard: a
//! test that outlives the deadline ends the test binary at once, with the
//! test's name and the process's threads on stderr. This is only a guard; a
//! hang it reports is a defect to fix at its cause.

use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::time::Duration;

/// How long one app test may own its `App`. App tests finish in well under a
/// second; the margin is for a loaded runner.
const APP_TEST_DEADLINE: Duration = Duration::from_secs(180);

/// Ends the test process if the test that armed it runs past the deadline.
/// Dropping it (with the test's `App`) disarms it.
pub(super) struct TestDeadline {
    _disarm: Sender<()>,
}

impl TestDeadline {
    /// Arm the guard for the calling test thread (libtest names it after the test).
    pub(super) fn arm() -> Self {
        let (disarm, disarmed) = mpsc::channel::<()>();
        let test = std::thread::current().name().unwrap_or("<unnamed test>").to_owned();
        let watched = test.clone();
        let spawned =
            std::thread::Builder::new().name("app-test-deadline".into()).spawn(move || {
                // The sender never sends: dropping it disconnects and disarms.
                if disarmed.recv_timeout(APP_TEST_DEADLINE) == Err(RecvTimeoutError::Timeout) {
                    eprintln!(
                        "app test `{watched}` ran past its {} s deadline; ending the test binary \
                         so the job does not wait for its timeout",
                        APP_TEST_DEADLINE.as_secs()
                    );
                    report_threads();
                    std::process::exit(101);
                }
            });
        if let Err(error) = spawned {
            eprintln!("app test `{test}` runs without a deadline guard: {error}");
        }
        Self { _disarm: disarm }
    }
}

/// Name every thread of the process and the kernel wait it sleeps in.
#[cfg(target_os = "linux")]
fn report_threads() {
    let Ok(tasks) = std::fs::read_dir("/proc/self/task") else { return };
    for task in tasks.flatten() {
        let path = task.path();
        let read = |name: &str| std::fs::read_to_string(path.join(name)).unwrap_or_default();
        eprintln!(
            "  thread {} {:?}: {}",
            task.file_name().to_string_lossy(),
            read("comm").trim(),
            read("wchan").trim()
        );
    }
}

#[cfg(not(target_os = "linux"))]
fn report_threads() {}
