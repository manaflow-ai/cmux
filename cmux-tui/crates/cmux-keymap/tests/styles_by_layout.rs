//! Every app.keyStyle in every app.shortcutLayout, with synthetic Dvorak and AZERTY key
//! events (the characters come from key-vectors.json's `layouts`): followLayout follows the
//! letters the layout types, qwertyPositions the US key positions.

use cmux_keymap::{KeyEvent, KeyStyle, ListKeys, Mods, Outcome, ShortcutLayout};
use serde_json::Value;
use std::sync::OnceLock;

fn layouts() -> &'static Value {
    static LAYOUTS: OnceLock<Value> = OnceLock::new();
    LAYOUTS.get_or_init(|| {
        let vectors: Value =
            serde_json::from_str(include_str!("../../../../schemas/keymap/key-vectors.json"))
                .expect("key-vectors.json parses");
        vectors["layouts"].clone()
    })
}

fn key(layout: &str, code: &'static str, mods: Mods) -> KeyEvent<'static> {
    let chars = layouts()[layout][code].as_array().expect("the layout has the key");
    KeyEvent {
        code: Some(code),
        key: chars[0].as_str().expect("a key"),
        shifted_key: chars[1].as_str(),
        mods,
    }
}

const NONE: Mods = Mods::NONE;
const SHIFT: Mods = Mods { shift: true, ..Mods::NONE };
const CTRL: Mods = Mods { ctrl: true, ..Mods::NONE };

fn run(
    style: KeyStyle,
    layout: ShortcutLayout,
    keyboard: &str,
    strokes: &[(&'static str, Mods)],
) -> Vec<String> {
    let mut keys = ListKeys::new(style, layout);
    strokes
        .iter()
        .map(|(code, mods)| match keys.feed(&key(keyboard, code, *mods), false) {
            Outcome::Command(command) => command.id().to_owned(),
            Outcome::Pending => "pending".to_owned(),
            Outcome::Pass => "pass".to_owned(),
        })
        .collect()
}

fn check(
    style: KeyStyle,
    layout: ShortcutLayout,
    keyboard: &str,
    strokes: &[(&'static str, Mods)],
    want: &[&str],
) {
    let got = run(style, layout, keyboard, strokes);
    assert_eq!(
        got,
        want,
        "{} / {} on {keyboard}: strokes {strokes:?}",
        style.as_setting(),
        layout.as_setting()
    );
}

use KeyStyle::{Emacs, Standard, Vim};
use ShortcutLayout::{FollowLayout, QwertyPositions};

#[test]
fn standard_passes_every_key_in_both_layouts() {
    for layout in ShortcutLayout::ALL {
        for keyboard in ["dvorak", "azerty"] {
            check(
                Standard,
                layout,
                keyboard,
                &[("KeyJ", NONE), ("KeyC", NONE), ("KeyG", NONE), ("KeyN", CTRL), ("KeyA", CTRL)],
                &["pass"; 5],
            );
        }
    }
}

#[test]
fn vim_follow_layout_on_dvorak_and_azerty() {
    // Dvorak: j is US C, k is US V, g is US U, h is US J, l is US P.
    check(
        Vim,
        FollowLayout,
        "dvorak",
        &[
            ("KeyC", NONE),
            ("KeyV", NONE),
            ("KeyU", NONE),
            ("KeyU", NONE),
            ("KeyU", SHIFT),
            ("KeyJ", NONE),
            ("KeyP", NONE),
        ],
        &[
            "list.next",
            "list.previous",
            "pending",
            "list.first",
            "list.last",
            "list.back",
            "list.open",
        ],
    );
    // Dvorak's US J types h: by character it is back, not next.
    check(Vim, FollowLayout, "dvorak", &[("KeyJ", NONE)], &["list.back"]);
    // AZERTY types j, k, g, h, l on their US keys; / is Shift-: (US Period).
    check(
        Vim,
        FollowLayout,
        "azerty",
        &[
            ("KeyJ", NONE),
            ("KeyK", NONE),
            ("KeyG", NONE),
            ("KeyG", NONE),
            ("Period", SHIFT),
            ("KeyD", CTRL),
        ],
        &["list.next", "list.previous", "pending", "list.first", "list.search", "list.pageDown"],
    );
}

#[test]
fn vim_qwerty_positions_on_dvorak_and_azerty() {
    // By position: US J/K/G whatever Dvorak types there (h, t, i).
    check(
        Vim,
        QwertyPositions,
        "dvorak",
        &[
            ("KeyJ", NONE),
            ("KeyK", NONE),
            ("KeyG", NONE),
            ("KeyG", NONE),
            ("KeyG", SHIFT),
            ("Slash", NONE),
        ],
        &["list.next", "list.previous", "pending", "list.first", "list.last", "list.search"],
    );
    // Dvorak's US C types j, but by position it is c: nothing.
    check(Vim, QwertyPositions, "dvorak", &[("KeyC", NONE)], &["pass"]);
    // AZERTY by position: US Slash (types =) searches; Shift-: (US Period) does not.
    check(
        Vim,
        QwertyPositions,
        "azerty",
        &[("Slash", NONE), ("Period", SHIFT), ("KeyJ", NONE), ("KeyU", CTRL)],
        &["list.search", "pass", "list.next", "list.pageUp"],
    );
}

#[test]
fn emacs_follow_layout_on_dvorak_and_azerty() {
    // Dvorak: n is US L, p is US R, a is US A, e is US D, f is US Y, b is US N.
    check(
        Emacs,
        FollowLayout,
        "dvorak",
        &[
            ("KeyL", CTRL),
            ("KeyR", CTRL),
            ("KeyA", CTRL),
            ("KeyD", CTRL),
            ("KeyY", CTRL),
            ("KeyN", CTRL),
        ],
        &["list.next", "list.previous", "list.first", "list.last", "list.open", "list.back"],
    );
    // AZERTY: a is US Q; US A types q, which is nothing.
    check(
        Emacs,
        FollowLayout,
        "azerty",
        &[("KeyQ", CTRL), ("KeyA", CTRL)],
        &["list.first", "pass"],
    );
}

#[test]
fn emacs_qwerty_positions_on_dvorak_and_azerty() {
    check(
        Emacs,
        QwertyPositions,
        "dvorak",
        &[("KeyN", CTRL), ("KeyP", CTRL), ("KeyL", CTRL), ("KeyV", CTRL)],
        &["list.next", "list.previous", "pass", "list.pageDown"],
    );
    check(
        Emacs,
        QwertyPositions,
        "azerty",
        &[("KeyA", CTRL), ("KeyQ", CTRL)],
        &["list.first", "pass"],
    );
}

#[test]
fn a_key_that_breaks_a_sequence_is_judged_alone_and_reset_drops_it() {
    let mut keys = ListKeys::new(Vim, FollowLayout);
    assert_eq!(keys.feed(&key("qwerty", "KeyG", NONE), false), Outcome::Pending);
    assert!(keys.is_pending());
    keys.reset();
    assert!(!keys.is_pending());
    assert_eq!(keys.feed(&key("qwerty", "KeyG", NONE), false), Outcome::Pending);
    assert_eq!(keys.feed(&key("qwerty", "KeyX", NONE), false), Outcome::Pass);
    assert!(!keys.is_pending());
    // In a text field the g is typing, so nothing is pending.
    assert_eq!(keys.feed(&key("qwerty", "KeyG", NONE), true), Outcome::Pass);
    assert!(!keys.is_pending());
}

#[test]
fn settings_values_round_trip_and_unknown_is_the_default() {
    for style in KeyStyle::ALL {
        assert_eq!(KeyStyle::from_setting(style.as_setting()), style);
    }
    for layout in ShortcutLayout::ALL {
        assert_eq!(ShortcutLayout::from_setting(layout.as_setting()), layout);
    }
    assert_eq!(KeyStyle::from_setting("helix"), Standard);
    assert_eq!(ShortcutLayout::from_setting(""), FollowLayout);
}
