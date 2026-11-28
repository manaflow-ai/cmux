//! Go to Last Location (`focusHistoryLast`) jumps back to the session (tab or pane) focused
//! before this one, and a second press returns: the palette row and a default key, Opt-Cmd-/,
//! beside Go Back's Opt-Cmd-, and Go Forward's Opt-Cmd-. on the same row of keys.
//! `default_keymap_conflicts.rs` checks the key against macOS, Ghostty and the menu bar.
use cmux_action_catalog::{CMD, KEYBOARD, OPT, PALETTE, find};

#[test]
fn go_to_last_location_is_a_palette_row_with_its_own_key() {
    let action = find("focusHistoryLast").expect("focusHistoryLast is in the catalog");
    assert!(action.surfaces & PALETTE != 0, "Go to Last Location is a palette row");
    assert!(action.surfaces & KEYBOARD != 0, "Go to Last Location takes a key");
    let shortcut = action.default_shortcut.expect("Go to Last Location has a default key");
    assert_eq!((shortcut.key, shortcut.modifiers), ("/", OPT | CMD));
    assert!(action.requires.is_empty(), "it runs from every pane, as Go Back and Go Forward do");
    for word in ["previous", "session", "recent", "last"] {
        assert!(action.keywords.contains(&word), "the palette finds it by {word:?}");
    }
    for (id, key) in [("focusHistoryBack", ","), ("focusHistoryForward", ".")] {
        let neighbor =
            find(id).and_then(|a| a.default_shortcut).unwrap_or_else(|| panic!("{id} key"));
        assert_eq!((neighbor.key, neighbor.modifiers), (key, OPT | CMD), "{id}");
    }
}
