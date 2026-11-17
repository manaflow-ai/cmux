//! The stage-0 launch window's decisions (docs/design/launch-shell-first.md, "Decision: stage 0 is
//! its own window"): what it shows (`plan`: the saved image, the plain shell, the bare launch, or no
//! window) and which input it holds for the real window (every key, button, drag and scroll, in
//! arrival order, never dropped). The record's format is cmux-launch-record's; the app draws and
//! replays; nothing here touches AppKit.

pub mod ffi;
pub mod plan;

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

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    #[test]
    fn every_key_and_button_is_held_in_order_and_hover_passes() {
        use InputKind::*;
        for kind in [KeyDown, KeyUp, FlagsChanged, MouseDown, MouseUp, MouseDragged, Scroll] {
            assert_eq!(input_disposition(kind, 0), Disposition::Hold, "{kind:?}");
        }
        assert_eq!(input_disposition(MouseMoved, 0), Disposition::Pass);
        assert_eq!(input_disposition(Other, 0), Disposition::Pass);
        assert_eq!(input_disposition(KeyDown, INPUT_SWAP_AT - 2), Disposition::Hold);
        assert_eq!(input_disposition(KeyDown, INPUT_SWAP_AT - 1), Disposition::HoldAndSwap);
        assert_eq!(InputKind::from_u8(200), Other);
    }

    proptest! {
        /// No event a person meant for the content is ever passed through or dropped, at any count.
        #[test]
        fn nothing_meant_for_the_content_is_dropped(kind in 1u8..=7, held in 0usize..100_000) {
            prop_assert_ne!(input_disposition(InputKind::from_u8(kind), held), Disposition::Pass);
        }
    }
}
