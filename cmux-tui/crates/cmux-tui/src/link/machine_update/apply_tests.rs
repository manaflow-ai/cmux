//! The apply step's stop wait (p14-energy-077b).

use std::io;
use std::time::{Duration, Instant};

use super::stopped_by;

fn no_exit_event(_: Duration) -> io::Result<bool> {
    Err(io::Error::from_raw_os_error(libc::ENOSYS))
}

#[test]
fn without_an_exit_event_a_daemon_that_stops_late_still_counts_as_stopped() {
    let sent_term = Instant::now();
    let stopped = stopped_by(Duration::from_secs(30), no_exit_event, || {
        sent_term.elapsed() >= Duration::from_millis(300)
    });
    assert!(stopped, "the daemon stopped 300 ms after SIGTERM, well inside the limit");
    assert!(sent_term.elapsed() < Duration::from_secs(10));
}

#[test]
fn without_an_exit_event_a_daemon_that_keeps_running_is_not_stopped_after_the_limit() {
    let started = Instant::now();
    assert!(!stopped_by(Duration::from_millis(400), no_exit_event, || false));
    assert!(started.elapsed() >= Duration::from_millis(400), "the whole limit is waited");
}

#[test]
fn the_exit_event_answers_when_it_can_be_set_up() {
    let asked = std::cell::Cell::new(false);
    let gone = || {
        asked.set(true);
        true
    };
    assert!(!stopped_by(Duration::from_millis(10), |_| Ok(false), gone));
    assert!(!asked.get(), "no signal-0 check runs beside the exit event");
}
