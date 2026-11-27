use super::*;
use proptest::prelude::*;

const KEYS: [InputKind; 3] = [InputKind::KeyDown, InputKind::KeyUp, InputKind::FlagsChanged];
const POINTED: [InputKind; 4] =
    [InputKind::MouseDown, InputKind::MouseUp, InputKind::MouseDragged, InputKind::Scroll];

#[test]
fn clicks_replay_over_the_image_when_the_real_window_matches() {
    for kind in KEYS.into_iter().chain(POINTED) {
        assert!(replays(kind, true, false), "{kind:?}");
    }
}

#[test]
fn over_the_plain_shell_keys_replay_and_clicks_drop() {
    for kind in KEYS {
        assert!(replays(kind, false, false), "{kind:?}");
    }
    for kind in POINTED {
        assert!(!replays(kind, false, false), "{kind:?}");
    }
}

#[test]
fn on_a_mismatch_keys_replay_and_clicks_drop() {
    for kind in KEYS {
        assert!(replays(kind, true, true), "{kind:?}");
    }
    for kind in POINTED {
        assert!(!replays(kind, true, true), "{kind:?}");
    }
    assert!(!replays(InputKind::MouseMoved, true, false));
}

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
