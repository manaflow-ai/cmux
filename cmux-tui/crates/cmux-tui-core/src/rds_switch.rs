//! The runtime switches of the R-DAEMON-STATE rewrite (handoff/rewrites/R-DAEMON-STATE/DESIGN.md,
//! section 3): one per stage, read once from the daemon's environment when the mux is built, deleted
//! together with the old path when the stage passes. A switch only chooses between the stage's new
//! path and the old one; both stay correct, so an A/B can run either arm in the same build. Each mux
//! owns its switches, so a test that turns one on changes no other test's mux.

use std::sync::atomic::{AtomicBool, Ordering};

/// Stage S1, the input lane: a connection's lines and the person's keys read the published facts of
/// the session's connections and its routing tables, never through a shared lock.
/// On by default (S1.7); `CMUX_TUI_RDS_INPUT=0` (or `false`, `off`, `no`) keeps the old path, the fallback for one
/// nightly before S1.8 deletes it with this switch.
pub(crate) struct InputLaneSwitch(AtomicBool);

impl InputLaneSwitch {
    /// The switch as the daemon's environment sets it. The first one a process reads is logged, so a daemon's log
    /// says which path its keys take.
    pub(crate) fn from_env() -> Self {
        let value = std::env::var("CMUX_TUI_RDS_INPUT").ok();
        let switch = Self::from_value(value.as_deref());
        static LOGGED: std::sync::Once = std::sync::Once::new();
        LOGGED.call_once(|| {
            let state = if switch.on() { "on" } else { "off (the old path)" };
            match &value {
                Some(value) => {
                    eprintln!("cmux-tui: input lane {state}, CMUX_TUI_RDS_INPUT={value:?}");
                }
                None => eprintln!("cmux-tui: input lane {state}, CMUX_TUI_RDS_INPUT unset"),
            }
        });
        switch
    }

    /// The switch for a value of `CMUX_TUI_RDS_INPUT` (`None`: unset): on unless the value is `0`, `false`, `off` or
    /// `no` (any case, spaces ignored).
    fn from_value(value: Option<&str>) -> Self {
        let off = value.map(str::trim).is_some_and(|value| {
            ["0", "false", "off", "no"].iter().any(|off| value.eq_ignore_ascii_case(off))
        });
        Self(AtomicBool::new(!off))
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

#[cfg(test)]
mod tests {
    use super::InputLaneSwitch;

    /// R-DAEMON-STATE S1.7: the input lane is the default; `CMUX_TUI_RDS_INPUT=0` keeps the old path, the
    /// fallback for one nightly before S1.8 deletes it.
    #[test]
    fn the_input_lane_is_on_unless_the_environment_turns_it_off() {
        assert!(
            InputLaneSwitch::from_value(None).on(),
            "the input lane is off with no CMUX_TUI_RDS_INPUT"
        );
        assert!(
            InputLaneSwitch::from_value(Some("1")).on(),
            "CMUX_TUI_RDS_INPUT=1 did not turn the input lane on"
        );
        assert!(
            !InputLaneSwitch::from_value(Some("0")).on(),
            "CMUX_TUI_RDS_INPUT=0 did not turn the input lane off"
        );
    }

    /// The fallback must not depend on spelling (#35413 review): an operator who writes `false`, `off` or `no` (any
    /// case, with spaces) means off, and a lane left on by such a value would be silent.
    #[test]
    fn false_off_and_no_turn_the_input_lane_off_too() {
        for value in ["false", "OFF", " no ", "False"] {
            assert!(
                !InputLaneSwitch::from_value(Some(value)).on(),
                "CMUX_TUI_RDS_INPUT={value:?} did not turn the input lane off"
            );
        }
        for value in ["1", "true", "on", ""] {
            assert!(
                InputLaneSwitch::from_value(Some(value)).on(),
                "CMUX_TUI_RDS_INPUT={value:?} turned the input lane off"
            );
        }
    }
}
