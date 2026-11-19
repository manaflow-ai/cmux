//! The C ABI the app's stage-0 window calls (include/cmux_launch_shell.h): one disposition per
//! input event while it is up, and whether each held one is replayed at the swap.
use crate::{InputKind, input_disposition};

/// What the stage-0 window does with an event of `kind` (`InputKind`) when `held` events are held:
/// 0 pass to AppKit, 1 hold, 2 hold and swap now.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_launch_shell_input_disposition(kind: u8, held: usize) -> u8 {
    input_disposition(InputKind::from_u8(kind), held) as u8
}

/// Whether a held event of `kind` is replayed to the real window at the swap: keys always;
/// buttons, drags and scrolls only over the saved image (`showed_image`) when the real window drew
/// the same place (`mismatch` false).
#[unsafe(no_mangle)]
pub extern "C" fn cmux_launch_shell_replays(kind: u8, showed_image: bool, mismatch: bool) -> bool {
    crate::replays(InputKind::from_u8(kind), showed_image, mismatch)
}
