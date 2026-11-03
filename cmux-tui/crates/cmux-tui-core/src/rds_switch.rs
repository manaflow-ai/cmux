//! The runtime switches of the R-DAEMON-STATE rewrite (handoff/rewrites/R-DAEMON-STATE/DESIGN.md,
//! section 3): one per stage, read once from the daemon's environment, deleted together with the
//! old path when the stage passes. A switch only chooses between the stage's new path and the old
//! one; both stay correct, so an A/B can run either arm in the same build.

use std::sync::atomic::{AtomicU8, Ordering};

const UNREAD: u8 = 0;
const OFF: u8 = 1;
const ON: u8 = 2;

/// Stage S1, the input lane: a connection's lines and the person's keys read the facts of the
/// session's connections from a published snapshot, never through a shared lock.
/// `CMUX_TUI_RDS_INPUT=1` turns it on.
static INPUT_LANE: AtomicU8 = AtomicU8::new(UNREAD);

/// Whether stage S1 (the input lane) is on. The environment is read once; a race of two first
/// reads only reads it twice.
pub(crate) fn input_lane() -> bool {
    match INPUT_LANE.load(Ordering::Relaxed) {
        ON => true,
        OFF => false,
        _ => {
            let on = std::env::var("CMUX_TUI_RDS_INPUT").is_ok_and(|value| value == "1");
            INPUT_LANE.store(if on { ON } else { OFF }, Ordering::Relaxed);
            on
        }
    }
}

/// Turns stage S1 on or off for this test process (nextest runs each test in its own process).
#[cfg(test)]
pub(crate) fn set_input_lane_for_test(on: bool) {
    INPUT_LANE.store(if on { ON } else { OFF }, Ordering::Relaxed);
}
