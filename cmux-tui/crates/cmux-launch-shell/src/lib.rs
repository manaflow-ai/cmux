//! The stage-0 launch window's decisions (docs/design/launch-shell-first.md, "Decision: stage 0 is
//! its own window"): what it shows (`plan`: the saved image, the plain shell, the bare launch, or no
//! window) and which input it holds for the real window (every key, button, drag and scroll, in
//! arrival order, never dropped). The record's format is cmux-launch-record's; the app draws and
//! replays; nothing here touches AppKit.

pub mod ffi;
pub mod plan;
pub mod relaunch_cover;
pub mod relaunch_cover_ffi;

pub use plan::{
    Appearance, Display, Frame, ImageKey, Now, Plan, Reason, SavedWindow, plan, png_size,
};

/// Held events past which the window swaps at once. Typing never reaches it; nothing is dropped.
pub const INPUT_SWAP_AT: usize = 4096;

/// An input event's kind, as the stage-0 window sees it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum InputKind {
    Other = 0,
    KeyDown = 1,
    KeyUp = 2,
    FlagsChanged = 3,
    MouseDown = 4,
    MouseUp = 5,
    MouseDragged = 6,
    Scroll = 7,
    MouseMoved = 8,
}

impl InputKind {
    pub fn from_u8(v: u8) -> Self {
        match v {
            1 => Self::KeyDown,
            2 => Self::KeyUp,
            3 => Self::FlagsChanged,
            4 => Self::MouseDown,
            5 => Self::MouseUp,
            6 => Self::MouseDragged,
            7 => Self::Scroll,
            8 => Self::MouseMoved,
            _ => Self::Other,
        }
    }
}

/// What the stage-0 window does with one event.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum Disposition {
    /// AppKit handles it as usual (hover, system events): nothing a person meant for the content.
    Pass = 0,
    /// Held, to be replayed to the real window in arrival order.
    Hold = 1,
    /// Held, and the window swaps now: `INPUT_SWAP_AT` events are waiting.
    HoldAndSwap = 2,
}

/// The disposition of an event arriving after `held` events were held. Every key and every
/// button, drag and scroll is held; none is ever dropped.
pub fn input_disposition(kind: InputKind, held: usize) -> Disposition {
    match kind {
        InputKind::Other | InputKind::MouseMoved => Disposition::Pass,
        _ if held + 1 >= INPUT_SWAP_AT => Disposition::HoldAndSwap,
        _ => Disposition::Hold,
    }
}

/// Whether a held event is replayed to the real window at the swap. Keys always are, in order:
/// typing lands wherever focus lands. A button, drag or scroll aimed at a point is replayed only
/// when stage 0 showed the saved image and the real window drew the same place (`mismatch`
/// false); over the plain shell, or a real window that drew otherwise, that point meant nothing.
pub fn replays(kind: InputKind, showed_image: bool, mismatch: bool) -> bool {
    match kind {
        InputKind::KeyDown | InputKind::KeyUp | InputKind::FlagsChanged => true,
        InputKind::MouseDown | InputKind::MouseUp | InputKind::MouseDragged | InputKind::Scroll => {
            showed_image && !mismatch
        }
        InputKind::Other | InputKind::MouseMoved => false,
    }
}

#[cfg(test)]
#[path = "tests.rs"]
mod tests;
