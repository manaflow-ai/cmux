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
