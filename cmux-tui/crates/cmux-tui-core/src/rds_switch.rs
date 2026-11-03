//! The runtime switches of the R-DAEMON-STATE rewrite (handoff/rewrites/R-DAEMON-STATE/DESIGN.md,
//! section 3): one per stage, read once from the daemon's environment when the mux is built, deleted
//! together with the old path when the stage passes. A switch only chooses between the stage's new
//! path and the old one; both stay correct, so an A/B can run either arm in the same build. Each mux
//! owns its switches, so a test that turns one on changes no other test's mux.

use std::sync::atomic::{AtomicBool, Ordering};

/// Stage S1, the input lane: a connection's lines and the person's keys read the published facts of
/// the session's connections and its routing tables, never through a shared lock.
/// `CMUX_TUI_RDS_INPUT=1` turns it on.
pub(crate) struct InputLaneSwitch(AtomicBool);

impl InputLaneSwitch {
    /// The switch as the daemon's environment sets it.
    pub(crate) fn from_env() -> Self {
        Self(AtomicBool::new(!std::env::var("CMUX_TUI_RDS_INPUT").is_ok_and(|value| value == "0")))
    }

    /// Whether stage S1 is on for this mux.
    pub(crate) fn on(&self) -> bool {
        self.0.load(Ordering::Relaxed)
    }

    /// Turns stage S1 on or off for this mux (tests).
    #[cfg(test)]
    pub(crate) fn set_for_test(&self, on: bool) {
        self.0.store(on, Ordering::Relaxed);
    }
}
