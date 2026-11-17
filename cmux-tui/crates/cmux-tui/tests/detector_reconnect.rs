//! The screen detector's reconnect loop, counted with a clock of the test.
//!
//! The detector (`bindings/examples/rust-agent-screen-detection`) is a Cargo
//! workspace of its own, so a test of this workspace cannot link it. Its
//! reconnect loop is in a file with no dependency (`src/reconnect.rs`), which
//! this test compiles as a module: the loop here is the detector's own loop,
//! not a copy.
//!
//! A pass of the loop is one try to connect and scan: 1 to 3 connections to
//! the daemon, because each stream of the detector has a connection of its
//! own. A pass that ends at once (no socket, a refused manifest, a refused
//! wake stream, or an error just after the first read of the terminals)
//! costs the daemon its connections and its requests. The tests count the
//! passes of a simulated span: the clock moves only by the life of each pass
//! and by the waits that the loop asks for, so no test sleeps.

#[path = "../../../bindings/examples/rust-agent-screen-detection/src/reconnect.rs"]
mod detector_reconnect;

use std::cell::Cell;
use std::time::Duration;

use detector_reconnect::{Pass, run_passes};

const FIVE_MINUTES: Duration = Duration::from_secs(300);
const AT_ONCE: Duration = Duration::ZERO;

/// What the loop did in a simulated span.
struct Passes {
    /// The time at which each pass started.
    starts: Vec<Duration>,
    /// The wait in seconds that the loop asked for after each pass.
    waits: Vec<u64>,
}

/// Runs the detector's loop for `span` of simulated time. `outcome` gets the
/// index of a pass and says how that pass ended and how long it lived.
fn passes(span: Duration, outcome: impl Fn(usize) -> (Pass, Duration)) -> Passes {
    let now = Cell::new(Duration::ZERO);
    let mut starts = Vec::new();
    let mut waits = Vec::new();
    run_passes(
        || {
            if now.get() >= span {
                return Pass::Done;
            }
            starts.push(now.get());
            let (pass, lived) = outcome(starts.len() - 1);
            now.set(now.get() + lived);
            pass
        },
        |wait| {
            waits.push(wait.as_secs());
            now.set(now.get() + wait);
        },
        || now.get(),
    );
    Passes { starts, waits }
}

fn seconds(count: u64) -> Duration {
    Duration::from_secs(count)
}

#[test]
fn detector_reconnect_makes_at_most_15_passes_in_5_minutes_with_no_scan() {
    let run = passes(FIVE_MINUTES, |_| (Pass::NotScanned, AT_ONCE));
    assert!(
        run.starts.len() <= 15,
        "a detector that cannot scan made {} passes in 5 minutes",
        run.starts.len()
    );
    let late = run.starts.iter().filter(|start| **start >= seconds(60)).count();
    assert!(late <= 8, "{late} passes in the last 4 minutes: {:?}", run.waits);
}

#[test]
fn detector_reconnect_wait_doubles_from_1_second_to_30_seconds_with_no_scan() {
    let run = passes(FIVE_MINUTES, |_| (Pass::NotScanned, AT_ONCE));
    assert_eq!(run.waits, [1, 2, 4, 8, 16, 30, 30, 30, 30, 30, 30, 30, 30, 30]);
}

#[test]
fn detector_reconnect_makes_at_most_15_passes_in_5_minutes_when_each_pass_scans_and_ends_at_once() {
    let run = passes(FIVE_MINUTES, |_| (Pass::Scanned, AT_ONCE));
    assert!(
        run.starts.len() <= 15,
        "a detector whose passes scan and end at once made {} passes in 5 minutes",
        run.starts.len()
    );
    assert_eq!(run.waits, [1, 2, 4, 8, 16, 30, 30, 30, 30, 30, 30, 30, 30, 30]);
}

#[test]
fn detector_reconnect_wait_doubles_when_each_pass_scans_for_29_seconds() {
    let run = passes(FIVE_MINUTES, |_| (Pass::Scanned, seconds(29)));
    assert_eq!(run.waits, [1, 2, 4, 8, 16, 30, 30, 30]);
    assert_eq!(run.starts.len(), 8);
}

#[test]
fn detector_reconnect_wait_is_1_second_again_after_a_pass_that_scanned_for_30_seconds() {
    // Passes 0 to 5 scan nothing, pass 6 scans for 30 seconds, then no pass scans.
    let run = passes(seconds(150), |pass| {
        if pass == 6 { (Pass::Scanned, seconds(30)) } else { (Pass::NotScanned, AT_ONCE) }
    });
    assert_eq!(run.waits, [1, 2, 4, 8, 16, 30, 1, 2, 4, 8, 16, 30]);
}

#[test]
fn detector_reconnect_wait_stays_30_seconds_after_a_pass_that_scanned_for_29_seconds() {
    // Passes 0 to 5 scan nothing, pass 6 scans for 29 seconds, then no pass scans.
    let run = passes(seconds(150), |pass| {
        if pass == 6 { (Pass::Scanned, seconds(29)) } else { (Pass::NotScanned, AT_ONCE) }
    });
    assert_eq!(run.waits, [1, 2, 4, 8, 16, 30, 30, 30]);
}

#[test]
fn detector_reconnect_wait_stays_1_second_while_each_pass_scans_for_30_seconds() {
    let run = passes(FIVE_MINUTES, |_| (Pass::Scanned, seconds(30)));
    assert_eq!(run.waits, [1; 10]);
    assert_eq!(run.starts.len(), 10);
}
