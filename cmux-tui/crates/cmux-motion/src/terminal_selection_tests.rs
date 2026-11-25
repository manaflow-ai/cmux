use super::*;

#[test]
fn option_drag_in_a_capture_selects_with_the_shift_override() {
    let mut s = TerminalSelection::default();
    assert!(s.press_asks_capture(KEY_OPTION));
    assert_eq!(s.press(KEY_OPTION, true), KEY_SHIFT);
    assert!(s.selection_press);
    assert_eq!(s.following(KEY_OPTION), KEY_SHIFT);
    // Option let go mid-drag: the click still ends as the selection it began as.
    assert_eq!(s.following(0), KEY_SHIFT);
    s.released();
    assert!(!s.selection_press);
    assert_eq!(s.following(KEY_OPTION), KEY_OPTION);
}

#[test]
fn option_drag_without_a_capture_stays_a_rectangle_selection() {
    let mut s = TerminalSelection::default();
    assert_eq!(s.press(KEY_OPTION, false), KEY_OPTION);
    assert!(!s.selection_press);
    assert_eq!(s.following(KEY_OPTION), KEY_OPTION);
}

#[test]
fn other_keys_stay_as_they_are() {
    for keys in [
        0,
        KEY_SHIFT,
        KEY_OPTION | KEY_SHIFT,
        KEY_OPTION | KEY_CONTROL,
        KEY_OPTION | KEY_COMMAND,
        KEY_COMMAND,
        KEY_CONTROL,
        KEY_OPTION | KEY_FUNCTION,
    ] {
        let mut s = TerminalSelection { hint_shown: true, ..Default::default() };
        assert_eq!(s.press(keys, true), keys, "keys {keys:#b}");
        assert_eq!(s.following(keys), keys, "keys {keys:#b}");
    }
}

#[test]
fn the_capture_is_asked_only_for_option_alone_or_a_pending_hint() {
    let s = TerminalSelection::default();
    assert!(s.press_asks_capture(0));
    assert!(!s.press_asks_capture(KEY_SHIFT));
    assert!(!s.press_asks_capture(KEY_COMMAND));
    let shown = TerminalSelection { hint_shown: true, ..Default::default() };
    assert!(!shown.press_asks_capture(0));
    assert!(shown.press_asks_capture(KEY_OPTION));
}

#[test]
fn the_first_plain_drag_in_a_capture_shows_the_hint_once() {
    let mut s = TerminalSelection::default();
    // A drag outside a capture, or with a key held, shows nothing.
    s.press(0, false);
    assert!(!s.dragged());
    s.press(KEY_OPTION, true);
    assert!(!s.dragged());
    s.released();
    // A plain click with no drag shows nothing either.
    s.press(0, true);
    s.released();
    assert!(!s.dragged());
    s.press(0, true);
    assert!(s.dragged());
    assert!(!s.dragged());
    s.released();
    assert!(s.hint_shown);
    s.press(0, true);
    assert!(!s.dragged());
}
