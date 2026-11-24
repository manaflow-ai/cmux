use super::*;
use cmux_motion::terminal_selection::{KEY_OPTION, KEY_SHIFT};

#[test]
fn an_option_drag_goes_as_shift_through_the_c_abi() {
    let mut state = CmuxTerminalSelection::default();
    unsafe {
        assert!(cmux_terminal_selection_press_asks_capture(&state, KEY_OPTION));
        assert_eq!(cmux_terminal_selection_press(&mut state, KEY_OPTION, true), KEY_SHIFT);
        assert_eq!(cmux_terminal_selection_following(&state, 0), KEY_SHIFT);
        cmux_terminal_selection_released(&mut state);
        assert_eq!(cmux_terminal_selection_following(&state, KEY_OPTION), KEY_OPTION);
    }
}

#[test]
fn a_null_state_changes_nothing() {
    unsafe {
        assert!(!cmux_terminal_selection_press_asks_capture(std::ptr::null(), KEY_OPTION));
        assert_eq!(
            cmux_terminal_selection_press(std::ptr::null_mut(), KEY_OPTION, true),
            KEY_OPTION
        );
        assert_eq!(cmux_terminal_selection_following(std::ptr::null(), KEY_OPTION), KEY_OPTION);
        assert!(!cmux_terminal_selection_dragged(std::ptr::null_mut()));
        cmux_terminal_selection_released(std::ptr::null_mut());
    }
}
