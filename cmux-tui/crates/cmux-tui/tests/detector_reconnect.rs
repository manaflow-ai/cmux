//! The screen detector's reconnect loop, counted with a clock of the test.
//!
//! The detector (`bindings/examples/rust-agent-screen-detection`) is a Cargo
//! workspace of its own, so a test of this workspace cannot link it. Its
//! reconnect loop is in a file with no dependency (`src/reconnect.rs`), which
//! this test compiles as a module: the loop here is the detector's own loop,
//! not a copy.
//!
//! A pass of the loop is one connection to the daemon. A detector that the
//! daemon refuses (no socket, a refused manifest, a refused wake stream) scans
//! nothing, and each of its passes costs the daemon a connection and its
//! requests. The tests count the passes of a simulated span: the clock moves
//! only by the waits that the loop asks for, so no test sleeps.

#[path = "../../../bindings/examples/rust-agent-screen-detection/src/reconnect.rs"]
mod detector_reconnect;

use std::cell::Cell;
use std::time::Duration;

use detector_reconnect::{Pass, run_passes};

const FIVE_MINUTES: Duration = Duration::from_secs(300);

/// Runs the detector's loop for `span` of simulated time and returns the
/// time at which each pass started. `outcome` gets the index of the pass and
/// says how that pass ended.
fn pass_starts(span: Duration, outcome: impl Fn(usize) -> Pass) -> Vec<Duration> {
    let now = Cell::new(Duration::ZERO);
    let mut starts = Vec::new();
    run_passes(
        || {
            if now.get() >= span {
                return Pass::Done;
            }
            starts.push(now.get());
            outcome(starts.len() - 1)
        },
        |wait| now.set(now.get() + wait),
    );
    starts
}

/// The wait in seconds between each pass and the next one.
fn waits(starts: &[Duration]) -> Vec<u64> {
    starts.windows(2).map(|pair| (pair[1] - pair[0]).as_secs()).collect()
}

#[test]
fn detector_reconnect_makes_at_most_15_connections_in_5_minutes_with_no_scan() {
    let starts = pass_starts(FIVE_MINUTES, |_| Pass::NotScanned);
    assert!(
        starts.len() <= 15,
        "a detector that cannot scan connected {} times in 5 minutes",
        starts.len()
    );
    // In each 30 seconds after the first minute there is at most 1 connection.
    let late = starts.iter().filter(|start| **start >= Duration::from_secs(60)).count();
    assert!(late <= 8, "{late} connections in the last 4 minutes: {:?}", waits(&starts));
}

#[test]
fn detector_reconnect_wait_doubles_from_1_second_to_30_seconds_with_no_scan() {
    let starts = pass_starts(FIVE_MINUTES, |_| Pass::NotScanned);
    assert_eq!(waits(&starts), [1, 2, 4, 8, 16, 30, 30, 30, 30, 30, 30, 30, 30]);
}

#[test]
fn detector_reconnect_wait_is_1_second_again_after_a_pass_that_scanned() {
    // Passes 0 to 5 scan nothing, pass 6 scans, then no pass scans.
    let starts = pass_starts(Duration::from_secs(120), |pass| {
        if pass == 6 { Pass::Scanned } else { Pass::NotScanned }
    });
    assert_eq!(waits(&starts), [1, 2, 4, 8, 16, 30, 1, 2, 4, 8, 16]);
}

#[test]
fn detector_reconnect_wait_stays_1_second_while_each_pass_scans() {
    let starts = pass_starts(Duration::from_secs(10), |_| Pass::Scanned);
    assert_eq!(waits(&starts), [1; 9]);
    assert_eq!(starts.len(), 10);
}
