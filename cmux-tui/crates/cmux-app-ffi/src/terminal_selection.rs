//! The C ABI of cmux-motion's terminal selection rule for the macOS app
//! (`include/cmux_motion_ffi.h`, the "Terminal selection" functions; Swift
//! module `CCmuxMotionFFI`): Option-drag selects text while a program has the
//! mouse, and the first plain drag a program takes shows a hint once
//! (`cmux_motion::terminal_selection`). The app's `TerminalSurfaceView` keeps
//! one `CmuxTerminalSelection` per view, converts the event's keys to the
//! `KEY_*` bits (Command 1, Shift 2, Option 4, Control 8, Fn 16), asks
//! whether the program has the mouse, draws the hint and runs its timer; the
//! rule lives once, in cmux-motion.
//!
//! Per pointer event, in process, no allocation and no JSON. These functions
//! only check pointers; none panics on any input.

use cmux_motion::terminal_selection::CmuxTerminalSelection;

/// Whether a left press with `keys` needs to know if the program has the
/// mouse: Option alone, or no key while the hint has yet to show. False for a
/// null `state`.
///
/// # Safety
/// `state` is null or points to a readable `CmuxTerminalSelection`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_selection_press_asks_capture(
    state: *const CmuxTerminalSelection,
    keys: u32,
) -> bool {
    // SAFETY: `state` is null or readable per the contract above.
    unsafe { state.as_ref() }.is_some_and(|s| s.press_asks_capture(keys))
}

/// A left press with `keys`; `captured` is whether the program has the mouse.
/// Updates `state` and returns the keys Ghostty gets with the press (`keys`
/// for a null `state`).
///
/// # Safety
/// `state` is null or points to a writable `CmuxTerminalSelection`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_selection_press(
    state: *mut CmuxTerminalSelection,
    keys: u32,
    captured: bool,
) -> u32 {
    // SAFETY: `state` is null or writable per the contract above.
    match unsafe { state.as_mut() } {
        Some(s) => s.press(keys, captured),
        None => keys,
    }
}

/// The keys Ghostty gets with a drag or the release of the press held now
/// (`keys` for a null `state`).
///
/// # Safety
/// `state` is null or points to a readable `CmuxTerminalSelection`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_selection_following(
    state: *const CmuxTerminalSelection,
    keys: u32,
) -> u32 {
    // SAFETY: `state` is null or readable per the contract above.
    unsafe { state.as_ref() }.map_or(keys, |s| s.following(keys))
}

/// A drag of the left press. True once per terminal, when the app shows the
/// hint. False for a null `state`.
///
/// # Safety
/// `state` is null or points to a writable `CmuxTerminalSelection`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_selection_dragged(
    state: *mut CmuxTerminalSelection,
) -> bool {
    // SAFETY: `state` is null or writable per the contract above.
    unsafe { state.as_mut() }.is_some_and(|s| s.dragged())
}

/// The left button's release, after its keys went out. Does nothing for a
/// null `state`.
///
/// # Safety
/// `state` is null or points to a writable `CmuxTerminalSelection`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_selection_released(state: *mut CmuxTerminalSelection) {
    // SAFETY: `state` is null or writable per the contract above.
    if let Some(s) = unsafe { state.as_mut() } {
        s.released();
    }
}

#[cfg(test)]
mod tests {
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
}
