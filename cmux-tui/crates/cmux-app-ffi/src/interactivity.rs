//! The C ABI of cmux-interactivity for the macOS app (`include/cmux_interactivity.h`, Swift module
//! `CCmuxInteractivityFFI`): the app notes what the person touches (a divider, window or sidebar drag, typing,
//! scroll, focus) and reads the QoS the policy gives a class of work right now, so the Swift side keeps no table
//! of its own. No allocation; never panics on any input.

use cmux_interactivity::{InteractionKind, WorkClass};

/// Bumped on any change to a function in the header.
const ABI_VERSION: u32 = 1;

/// The ABI version of this header.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_interactivity_abi_version() -> u32 {
    ABI_VERSION
}

/// The person did `kind` now: 0 drag, 1 typing, 2 scroll, 3 focus. An unknown kind changes nothing. Cheap (one atomic
/// store): call it on every event of the gesture; the kind stays active for 300-500 ms after the last call.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_interactivity_note(kind: u32) {
    if let Some(kind) = InteractionKind::from_raw(kind) {
        cmux_interactivity::note(kind);
    }
}

/// Whether the person is interacting now (a noted kind is within its decay).
#[unsafe(no_mangle)]
pub extern "C" fn cmux_interactivity_is_interacting() -> bool {
    cmux_interactivity::is_interacting()
}

/// The QoS for a class of work right now, as a macOS `qos_class_t` raw value (0x21 user-interactive, 0x19
/// user-initiated, 0x15 default, 0x11 utility, 0x09 background), or -1 for an unknown class. Classes: 0 input,
/// 1 frame, 2 focused pane, 3 visible pane, 4 background pane, 5 agent output parse, 6 index, 7 sync, 8 maintenance.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_interactivity_qos(class: u32) -> i32 {
    WorkClass::from_raw(class)
        .map_or(-1, |class| i32::try_from(cmux_interactivity::qos_for(class).raw()).unwrap_or(-1))
}

#[cfg(test)]
#[path = "interactivity_tests.rs"]
mod tests;
