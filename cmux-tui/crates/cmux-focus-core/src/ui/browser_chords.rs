//! Chords a browser owns while a page, the address bar or the find bar has
//! the keyboard (Swift `BrowserChordTable`, plans/cmux-next/focus.md section
//! 5). The key router refuses the Ghostty-keybind fallback for every chord in
//! [`chrome_reserved`]; cmux's own bindings resolve before this table.
//!
//! A [`Shortcut`] keeps `Shortcut`'s matching rules: the key lowercased, and
//! only Command, Shift, Option and Control.

use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use std::sync::OnceLock;

use super::held_key::{COMMAND, CONTROL, OPTION, SHIFT};

/// The modifiers that take part in matching.
pub const RELEVANT: u64 = COMMAND | SHIFT | OPTION | CONTROL;
pub const LEFT_ARROW: &str = "\u{F702}";
pub const RIGHT_ARROW: &str = "\u{F703}";
pub const PAGE_UP: &str = "\u{F72C}";
pub const PAGE_DOWN: &str = "\u{F72D}";

/// A key equivalent and its modifiers.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Shortcut {
    pub key: String,
    pub modifiers: u64,
}

impl Shortcut {
    pub fn new(key: &str, modifiers: u64) -> Self {
        Self { key: key.to_lowercase(), modifiers: modifiers & RELEVANT }
    }

    /// The key with Command, as `Shortcut(key)` makes it.
    pub fn command(key: &str) -> Self {
        Self::new(key, COMMAND)
    }
}

/// A key event as the app reads it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TypedKey {
    pub is_key_down: bool,
    /// `charactersIgnoringModifiers` and `characters(byApplyingModifiers: [])`,
    /// in that order, the ones the event has.
    pub keys: Vec<String>,
    /// `modifierFlags.rawValue`.
    pub flags: u64,
}

impl TypedKey {
    /// The key as typed and its unshifted base, as `ActionRegistry.resolveShortcut` reads it.
    pub fn shortcuts(&self) -> Vec<Shortcut> {
        if !self.is_key_down {
            return Vec::new();
        }
        self.keys.iter().map(|key| Shortcut::new(key, self.flags)).collect()
    }
}

/// The standard browser shortcuts on macOS, limited to Command and Control chords.
pub fn chrome_reserved() -> &'static BTreeSet<Shortcut> {
    static SET: OnceLock<BTreeSet<Shortcut>> = OnceLock::new();
    SET.get_or_init(|| {
        let cmd = Shortcut::command;
        let with = Shortcut::new;
        let cs = COMMAND | SHIFT;
        let co = COMMAND | OPTION;
        let mut set: BTreeSet<Shortcut> = [
            // Navigation: Back, Forward.
            cmd("["),
            cmd("]"),
            cmd(LEFT_ARROW),
            cmd(RIGHT_ARROW),
            // Reload, hard reload, stop.
            cmd("r"),
            with("r", cs),
            cmd("."),
            // Address bar, new tab, reopen tab, close tab/window, new window, incognito.
            cmd("l"),
            cmd("t"),
            with("t", cs),
            cmd("w"),
            with("w", cs),
            cmd("n"),
            with("n", cs),
            // Find, find next/previous, use selection for find.
            cmd("f"),
            cmd("g"),
            with("g", cs),
            cmd("e"),
            // Bookmarks.
            cmd("d"),
            with("d", cs),
            with("b", cs),
            with("b", co),
            // History, downloads, print, save, open file, view source, developer tools, JS console.
            cmd("y"),
            with("j", cs),
            cmd("p"),
            cmd("s"),
            cmd("o"),
            with("u", co),
            with("i", co),
            with("j", co),
            with("c", co),
            // Zoom.
            cmd("="),
            cmd("+"),
            cmd("-"),
            cmd("0"),
            // Next/previous tab.
            with(RIGHT_ARROW, co),
            with(LEFT_ARROW, co),
            with("]", cs),
            with("[", cs),
            with("\t", CONTROL),
            with("\t", CONTROL | SHIFT),
            with(PAGE_DOWN, CONTROL),
            with(PAGE_UP, CONTROL),
            // Edit chords a page or the address bar handles.
            cmd("a"),
            cmd("c"),
            cmd("v"),
            cmd("x"),
            cmd("z"),
            with("z", cs),
            with("v", cs),
            with("v", cs | OPTION),
        ]
        .into_iter()
        .collect();
        // Select tab 1-8, last tab.
        for digit in 1..=9 {
            set.insert(cmd(&digit.to_string()));
        }
        set
    })
}

/// Whether `key` is a chord in [`chrome_reserved`].
pub fn is_chrome_chord(key: &TypedKey) -> bool {
    let reserved = chrome_reserved();
    key.shortcuts().iter().any(|shortcut| reserved.contains(shortcut))
}

/// The actions whose chords act only in a browser context.
pub const BROWSER_ONLY_ACTIONS: [&str; 2] = ["browserBack", "browserForward"];

/// The effective chords of the browser-only actions (the app reads them from its registry).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct BrowserOnlyChords {
    pub back: Option<Shortcut>,
    pub forward: Option<Shortcut>,
}

/// Whether `key` is the effective chord of a browser-only action.
pub fn is_browser_only_chord(key: &TypedKey, chords: &BrowserOnlyChords) -> bool {
    let typed = key.shortcuts();
    [&chords.back, &chords.forward].into_iter().flatten().any(|chord| typed.contains(chord))
}

/// The page-history action of a browser-only chord, for a page with its own
/// history (history.md 4.2b).
pub fn page_history_action(key: &TypedKey, chords: &BrowserOnlyChords) -> Option<&'static str> {
    let typed = key.shortcuts();
    [(&chords.back, "focusHistoryBack"), (&chords.forward, "focusHistoryForward")]
        .into_iter()
        .find(|(chord, _)| chord.as_ref().is_some_and(|chord| typed.contains(chord)))
        .map(|(_, action)| action)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn typed(keys: &[&str], flags: u64) -> TypedKey {
        TypedKey { is_key_down: true, keys: keys.iter().map(|k| (*k).to_owned()).collect(), flags }
    }

    #[test]
    fn the_browser_chords_are_reserved_and_others_are_not() {
        assert!(is_chrome_chord(&typed(&["["], COMMAND)));
        assert!(is_chrome_chord(&typed(&["{", "["], COMMAND | SHIFT)), "Cmd-Shift-[ arrives as {{");
        assert!(is_chrome_chord(&typed(&["\t"], CONTROL)));
        assert!(is_chrome_chord(&typed(&["9"], COMMAND)));
        assert!(is_chrome_chord(&typed(&["L"], COMMAND)), "the key is lowercased");
        assert!(!is_chrome_chord(&typed(&["k"], COMMAND)));
        assert!(!is_chrome_chord(&typed(&["["], CONTROL)));
        assert!(!is_chrome_chord(&TypedKey { is_key_down: false, ..typed(&["["], COMMAND) }));
        assert_eq!(chrome_reserved().len(), 60);
    }

    #[test]
    fn device_and_function_bits_do_not_count() {
        assert!(is_chrome_chord(&typed(&[LEFT_ARROW], COMMAND | (1 << 23) | (1 << 21) | 0x8)));
    }

    #[test]
    fn a_browser_only_chord_maps_to_its_page_history_action() {
        let chords = BrowserOnlyChords {
            back: Some(Shortcut::command("[")),
            forward: Some(Shortcut::command("]")),
        };
        assert!(is_browser_only_chord(&typed(&["["], COMMAND), &chords));
        assert_eq!(
            page_history_action(&typed(&["]"], COMMAND), &chords),
            Some("focusHistoryForward")
        );
        assert_eq!(page_history_action(&typed(&["["], COMMAND), &chords), Some("focusHistoryBack"));
        assert_eq!(page_history_action(&typed(&["r"], COMMAND), &chords), None);
        assert!(!is_browser_only_chord(&typed(&["["], COMMAND), &BrowserOnlyChords::default()));
    }
}
