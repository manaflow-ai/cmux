//! `cmux-screen-sharing __shortcut-tap`: the Mac Screen viewer's "Send System Shortcuts to the
//! Remote Mac" event tap, run in the Screen Sharing helper so the Accessibility grant it needs is
//! the helper's (the one app that holds this Mac's screen sharing grants), never cmux's. The app
//! starts it through `MacScreenHelper` with responsibility disclaimed, while the setting is on and
//! a Mac Screen tab is connected; a grant made while it is off is picked up by the next fresh
//! helper, so nothing is ever restarted to see one. Hidden: people and agents never run it.
//!
//! The app drives it in JSON lines on stdin:
//!   `{"hold":true,"release":{"key_code":53,"modifiers":786432}}`  a remote screen has the keyboard
//!   `{"hold":false}`                                             it does not: every key passes
//! and it answers on stdout: first `{"ready":true}` (the tap exists, disabled until a hold) or
//! `{"error":"..."}` and exit 1 (macOS refused the tap: no Accessibility), then one line per key
//! it took, `{"key_code":48,"modifiers":1048576,"down":true,"repeat":false}`. A taken key never
//! reaches macOS or any app; the app sends it to the other Mac. End of file on stdin ends it.
//!
//! Which keys ([`takes`]): the system list (Cmd-Tab, Cmd-Space, Control-arrows, screenshots,
//! Cmd-Q/W/H/M ...), never the release chord, plus the up (and repeats) of any key whose down it
//! took. Modifiers (`flagsChanged`) and every other key pass through to the app's capture view.
//! The decision is made here, in the tap's callback, without asking the app: a round trip per
//! key would delay every keystroke system-wide and let macOS turn the tap off for slowness.
//! Modifier bits are NSEvent's (the device-independent bits of CGEventFlags): Shift 1<<17,
//! Control 1<<18, Option 1<<19, Command 1<<20.

use serde::{Deserialize, Serialize};
use std::collections::HashSet;

/// The hidden mode word (cmux-next `MacScreenShortcutTap.mode`).
pub const MODE: &str = "__shortcut-tap";

pub const SHIFT: u64 = 1 << 17;
pub const CONTROL: u64 = 1 << 18;
pub const OPTION: u64 = 1 << 19;
pub const COMMAND: u64 = 1 << 20;
/// The four modifiers a chord is made of; any other flag bit (Caps Lock, Fn, side bits) is ignored.
pub const MODIFIERS: u64 = SHIFT | CONTROL | OPTION | COMMAND;

/// Carbon virtual key codes (kVK_*) of the system list.
mod key {
    pub const SPACE: u16 = 0x31;
    pub const TAB: u16 = 0x30;
    pub const GRAVE: u16 = 0x32;
    pub const LEFT: u16 = 0x7B;
    pub const RIGHT: u16 = 0x7C;
    pub const DOWN: u16 = 0x7D;
    pub const UP: u16 = 0x7E;
    pub const THREE: u16 = 0x14;
    pub const FOUR: u16 = 0x15;
    pub const FIVE: u16 = 0x17;
    pub const Q: u16 = 0x0C;
    pub const W: u16 = 0x0D;
    pub const H: u16 = 0x04;
    pub const M: u16 = 0x2E;
    pub const ESCAPE: u16 = 0x35;
}

/// A key and its modifiers (only [`MODIFIERS`] bits count).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Chord {
    pub key_code: u16,
    pub modifiers: u64,
}

impl Chord {
    /// Control-Option-Escape, the app's default release chord.
    pub const DEFAULT_RELEASE: Chord = Chord { key_code: key::ESCAPE, modifiers: CONTROL | OPTION };

    fn matches(&self, key_code: u16, modifiers: u64) -> bool {
        self.key_code == key_code && self.modifiers & MODIFIERS == modifiers & MODIFIERS
    }
}

/// Whether the tap takes a key down with `modifiers` from macOS: Spotlight and input sources
/// (Cmd-Space, Cmd-Option-Space, Control-Space, Control-Option-Space), app and window switching
/// (Cmd-Tab, Cmd-`, with Shift), Mission Control, App Windows and Spaces (Control-arrows),
/// screenshots (Cmd-Shift-3/4/5, with Control), Lock Screen (Control-Cmd-Q) and the app chords
/// Cmd-Q, Cmd-W, Cmd-H, Cmd-M (with Option, and Cmd-Shift-Q). The list goes to the other Mac
/// even where it is a cmux binding (Cmd-W closes the remote window, not the tab); every other
/// chord stays with the app. The release chord is never taken, even when rebound onto the list.
pub fn takes(key_code: u16, modifiers: u64, release: Chord) -> bool {
    let flags = modifiers & MODIFIERS;
    if release.matches(key_code, flags) {
        return false;
    }
    match key_code {
        key::SPACE => {
            flags == COMMAND
                || flags == COMMAND | OPTION
                || flags == CONTROL
                || flags == CONTROL | OPTION
        }
        key::TAB | key::GRAVE => flags == COMMAND || flags == COMMAND | SHIFT,
        key::LEFT | key::RIGHT | key::UP | key::DOWN => flags == CONTROL,
        key::THREE | key::FOUR | key::FIVE => {
            flags == COMMAND | SHIFT || flags == COMMAND | SHIFT | CONTROL
        }
        key::Q => {
            flags == COMMAND
                || flags == COMMAND | OPTION
                || flags == COMMAND | SHIFT
                || flags == COMMAND | CONTROL
        }
        key::H | key::M | key::W => flags == COMMAND || flags == COMMAND | OPTION,
        _ => false,
    }
}

/// One line from the app.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
pub struct Control {
    /// A remote screen has the keyboard, in a key window of the active app: take the list.
    pub hold: bool,
    /// The viewer's release chord (default Control-Option-Escape).
    #[serde(default)]
    pub release: Option<Chord>,
}

/// A key down or up the tap saw; on stdout, one the tap took.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Key {
    pub key_code: u16,
    pub modifiers: u64,
    pub down: bool,
    pub repeat: bool,
}

/// The tap's state: whether it holds, the release chord, and the keys whose down it took.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Policy {
    holding: bool,
    release: Chord,
    held: HashSet<u16>,
}

impl Default for Policy {
    fn default() -> Self {
        Self { holding: false, release: Chord::DEFAULT_RELEASE, held: HashSet::new() }
    }
}

impl Policy {
    /// Applies one line from the app; returns whether the tap is enabled now. Letting go
    /// forgets the held keys: their ups then reach the app as usual.
    pub fn control(&mut self, control: Control) -> bool {
        self.holding = control.hold;
        if let Some(release) = control.release {
            self.release = release;
        }
        if !self.holding {
            self.held.clear();
        }
        self.holding
    }

    pub fn holding(&self) -> bool {
        self.holding
    }

    /// Whether the tap takes `key` (consumes it and sends it to the app).
    pub fn key(&mut self, key: Key) -> bool {
        if !self.holding {
            return false;
        }
        if !key.down {
            return self.held.remove(&key.key_code);
        }
        if self.held.contains(&key.key_code) {
            return true;
        }
        if takes(key.key_code, key.modifiers, self.release) {
            self.held.insert(key.key_code);
            return true;
        }
        false
    }
}

/// Parses one stdin line; None for a line this helper does not know (a newer app's).
pub fn parse_control(line: &str) -> Option<Control> {
    serde_json::from_str(line.trim()).ok()
}

/// One stdout line for a taken key, newline included.
pub fn key_line(key: Key) -> String {
    let mut line = serde_json::to_string(&key).unwrap_or_default();
    line.push('\n');
    line
}

/// Runs the tap on stdin and stdout; the process exit code.
pub fn run(args: &[String]) -> i32 {
    if !args.is_empty() {
        eprintln!("usage: cmux-screen-sharing {MODE}");
        return 2;
    }
    #[cfg(target_os = "macos")]
    {
        crate::mac::shortcut_tap::run()
    }
    #[cfg(not(target_os = "macos"))]
    {
        eprintln!("cmux-screen-sharing {MODE}: macOS only");
        1
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const RELEASE: Chord = Chord::DEFAULT_RELEASE;

    fn system_chords() -> Vec<(u16, u64)> {
        vec![
            (key::SPACE, COMMAND),
            (key::SPACE, COMMAND | OPTION),
            (key::SPACE, CONTROL),
            (key::SPACE, CONTROL | OPTION),
            (key::TAB, COMMAND),
            (key::TAB, COMMAND | SHIFT),
            (key::GRAVE, COMMAND),
            (key::UP, CONTROL),
            (key::DOWN, CONTROL),
            (key::LEFT, CONTROL),
            (key::RIGHT, CONTROL),
            (key::THREE, COMMAND | SHIFT),
            (key::FOUR, COMMAND | SHIFT),
            (key::FIVE, COMMAND | SHIFT),
            (key::FOUR, COMMAND | SHIFT | CONTROL),
            (key::Q, CONTROL | COMMAND),
            (key::Q, COMMAND),
            (key::Q, COMMAND | SHIFT),
            (key::W, COMMAND),
            (key::H, COMMAND),
            (key::M, COMMAND),
            (key::M, COMMAND | OPTION),
        ]
    }

    #[test]
    fn takes_the_system_list() {
        for (code, modifiers) in system_chords() {
            assert!(takes(code, modifiers, RELEASE), "{code:#x} {modifiers:#x}");
        }
    }

    #[test]
    fn passes_typing_and_cmux_chords() {
        let a = 0x00;
        let c = 0x08;
        let t = 0x11;
        let return_key = 0x24;
        for (code, modifiers) in [
            (a, 0),
            (a, SHIFT),
            (key::SPACE, 0),
            (key::TAB, 0),
            (return_key, 0),
            (key::UP, 0),
            (c, COMMAND),
            (t, COMMAND),
            (t, COMMAND | SHIFT),
            (key::ESCAPE, CONTROL | OPTION),
        ] {
            assert!(!takes(code, modifiers, RELEASE), "{code:#x} {modifiers:#x}");
        }
    }

    #[test]
    fn caps_lock_and_other_flag_bits_do_not_change_a_chord() {
        let caps_lock = 1 << 16;
        let numeric_pad = 1 << 21;
        let left_command_side_bit = 0x8;
        let flags = COMMAND | caps_lock | numeric_pad | left_command_side_bit;
        assert!(takes(key::TAB, flags, RELEASE));
    }

    #[test]
    fn never_takes_the_release_chord_even_rebound_onto_the_list() {
        let rebound = Chord { key_code: key::UP, modifiers: CONTROL };
        assert!(!takes(key::UP, CONTROL, rebound));
        assert!(takes(key::DOWN, CONTROL, rebound));
    }

    fn down(key_code: u16, modifiers: u64) -> Key {
        Key { key_code, modifiers, down: true, repeat: false }
    }

    fn up(key_code: u16, modifiers: u64) -> Key {
        Key { key_code, modifiers, down: false, repeat: false }
    }

    #[test]
    fn takes_nothing_until_the_app_holds() {
        let mut policy = Policy::default();
        assert!(!policy.key(down(key::TAB, COMMAND)));
        assert!(policy.control(Control { hold: true, release: None }));
        assert!(policy.key(down(key::TAB, COMMAND)));
    }

    #[test]
    fn a_taken_down_takes_its_repeats_and_its_up_even_after_command_went_up() {
        let mut policy = Policy::default();
        policy.control(Control { hold: true, release: None });
        assert!(policy.key(down(key::SPACE, COMMAND)));
        assert!(policy.key(Key {
            key_code: key::SPACE,
            modifiers: COMMAND,
            down: true,
            repeat: true
        }));
        assert!(policy.key(up(key::SPACE, 0)));
        // The up was its last: a plain Space now passes.
        assert!(!policy.key(down(key::SPACE, 0)));
        assert!(!policy.key(up(key::SPACE, 0)));
    }

    #[test]
    fn letting_go_passes_the_ups_of_held_keys_to_the_app() {
        let mut policy = Policy::default();
        policy.control(Control { hold: true, release: None });
        assert!(policy.key(down(key::TAB, COMMAND)));
        assert!(!policy.control(Control { hold: false, release: None }));
        assert!(!policy.key(up(key::TAB, COMMAND)));
        assert!(!policy.key(down(key::TAB, COMMAND)));
    }

    #[test]
    fn the_app_sets_the_release_chord() {
        let mut policy = Policy::default();
        let release = Chord { key_code: key::TAB, modifiers: COMMAND };
        policy.control(Control { hold: true, release: Some(release) });
        assert!(!policy.key(down(key::TAB, COMMAND)));
        assert!(policy.key(down(key::SPACE, COMMAND)));
        // A later hold without one keeps it.
        policy.control(Control { hold: true, release: None });
        assert!(!policy.key(down(key::TAB, COMMAND)));
    }

    #[test]
    fn reads_the_apps_lines_and_ignores_unknown_ones() {
        assert_eq!(
            parse_control(r#"{"hold":true,"release":{"key_code":53,"modifiers":786432}}"#),
            Some(Control { hold: true, release: Some(Chord::DEFAULT_RELEASE) })
        );
        assert_eq!(
            parse_control("{\"hold\":false}\n"),
            Some(Control { hold: false, release: None })
        );
        assert_eq!(parse_control(r#"{"stop":true}"#), None);
        assert_eq!(parse_control("not json"), None);
    }

    #[test]
    fn writes_one_line_per_taken_key() {
        let line = key_line(Key { key_code: 48, modifiers: COMMAND, down: true, repeat: false });
        assert_eq!(
            line,
            "{\"key_code\":48,\"modifiers\":1048576,\"down\":true,\"repeat\":false}\n"
        );
    }

    #[test]
    fn extra_arguments_are_refused_before_any_tap_exists() {
        assert_eq!(run(&["--x".into()]), 2);
    }
}
