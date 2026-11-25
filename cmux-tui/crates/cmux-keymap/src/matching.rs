//! Which strokes a key event means, and whether a stroke matches it, per
//! `app.shortcutLayout` (key-vectors.json's `$shortcutComment`).

use crate::stroke::named_key;
use crate::table::table;
use crate::{KeyEvent, Mods, ShortcutLayout, Stroke};

/// The named keys' physical keys: W3C code, stroke name, macOS kVK code. key-styles.json's
/// `keys` table holds the character keys; these are the non-character keys a stroke can name.
const NAMED_PHYSICAL: [(&str, &str, u16); 9] = [
    ("Enter", "enter", 36),
    ("NumpadEnter", "enter", 76),
    ("Escape", "escape", 53),
    ("PageUp", "pageup", 116),
    ("PageDown", "pagedown", 121),
    ("ArrowLeft", "left", 123),
    ("ArrowRight", "right", 124),
    ("ArrowDown", "down", 125),
    ("ArrowUp", "up", 126),
];

/// The W3C code of a macOS virtual key code (kVK_*), from key-styles.json's `keys` and the
/// named keys (Escape, Enter, the arrows, PageUp, PageDown).
pub fn code_for_mac_key_code(mac: u16) -> Option<&'static str> {
    if let Some(key) = table().keys.iter().find(|k| k.mac == mac) {
        return Some(key.code.as_str());
    }
    NAMED_PHYSICAL.iter().find(|(_, _, m)| *m == mac).map(|(code, _, _)| *code)
}

/// The macOS virtual key code of a W3C code, the inverse of [`code_for_mac_key_code`].
pub fn mac_key_code_for_code(code: &str) -> Option<u16> {
    if let Some(key) = table().keys.iter().find(|k| k.code == code) {
        return Some(key.mac);
    }
    NAMED_PHYSICAL.iter().find(|(c, _, _)| *c == code).map(|(_, _, mac)| *mac)
}

/// What the key at W3C `code` types on the US layout (`KeyZ` is `z`, `BracketLeft` is `[`).
pub fn qwerty_char(code: &str) -> Option<&'static str> {
    table().keys.iter().find(|k| k.code == code).map(|k| k.qwerty.as_str())
}

/// The named key of an event: by its key name (`escape`), else by its code (`ArrowDown`).
fn event_named(event: &KeyEvent<'_>) -> Option<&'static str> {
    if event.key.chars().nth(1).is_some()
        && let Some(named) = named_key(event.key)
    {
        return Some(named);
    }
    let code = event.code?;
    NAMED_PHYSICAL.iter().find(|(c, _, _)| *c == code).map(|(_, name, _)| *name)
}

fn is_dead_or_non_ascii(key: &str) -> bool {
    key.is_empty() || key == "Dead" || !key.is_ascii()
}

/// The longest candidate key, in bytes (a named key such as `pagedown`, or one character).
pub const CANDIDATE_KEY_MAX: usize = 15;
/// At most this many candidates per key: the typed character, the digit, the Shift-consumed one.
pub const CANDIDATES_MAX: usize = 3;

/// One stroke a key-down may mean, held inline (no allocation): `key` is lowercase UTF-8.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Candidate {
    pub mods: Mods,
    bytes: [u8; CANDIDATE_KEY_MAX],
    len: usize,
}

impl Candidate {
    fn new(mods: Mods, key: &str) -> Option<Self> {
        if key.is_empty() || key.len() > CANDIDATE_KEY_MAX {
            return None;
        }
        let mut bytes = [0u8; CANDIDATE_KEY_MAX];
        for (dst, src) in bytes.iter_mut().zip(key.bytes()) {
            *dst = src.to_ascii_lowercase();
        }
        Some(Candidate { mods, bytes, len: key.len() })
    }

    /// The key, lowercase (ASCII letters lowered; other characters as typed).
    pub fn key(&self) -> &str {
        self.bytes.get(..self.len).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or("")
    }

    /// The key's UTF-8 bytes.
    pub fn key_bytes(&self) -> &[u8] {
        self.bytes.get(..self.len).unwrap_or(&[])
    }

    pub fn matches(&self, stroke: &Stroke) -> bool {
        self.mods == stroke.mods && self.key() == stroke.key
    }

    pub fn to_stroke(&self) -> Stroke {
        Stroke { mods: self.mods, key: self.key().to_owned() }
    }
}

/// The candidates of one key-down, in priority order, without duplicates.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Candidates {
    items: [Option<Candidate>; CANDIDATES_MAX],
}

impl Candidates {
    fn push(&mut self, candidate: Option<Candidate>) {
        let Some(candidate) = candidate else { return };
        for slot in &mut self.items {
            match slot {
                Some(existing) if *existing == candidate => return,
                Some(_) => {}
                None => {
                    *slot = Some(candidate);
                    return;
                }
            }
        }
    }

    pub fn iter(&self) -> impl Iterator<Item = &Candidate> {
        self.items.iter().flatten()
    }

    pub fn len(&self) -> usize {
        self.iter().count()
    }

    pub fn is_empty(&self) -> bool {
        self.items.iter().all(Option::is_none)
    }

    pub fn contains(&self, stroke: &Stroke) -> bool {
        self.iter().any(|c| c.matches(stroke))
    }
}

/// The strokes a key-down may mean in the `layout` mode, in priority order and deduplicated,
/// each with its own modifiers, with no allocation (a surface looks each one up in its
/// binding index). [`stroke_matches`] is "the candidates contain the binding".
///
/// - A named key (by key name or W3C code): that name, with the event's modifiers.
/// - qwertyPositions with a known physical key: the US character of that key.
/// - followLayout (and qwertyPositions without a physical key): the character the layout
///   types (a dead key or a non-ASCII character counts as its US position), then a digit-row
///   key's digit, then a character the layout types only with Shift, with Shift taken out of
///   the modifiers (never a letter's capital).
pub fn key_candidates(layout: ShortcutLayout, event: &KeyEvent<'_>) -> Candidates {
    let mut out = Candidates::default();
    if let Some(named) = event_named(event) {
        out.push(Candidate::new(event.mods, named));
        return out;
    }
    if layout == ShortcutLayout::QwertyPositions
        && let Some(us) = event.code.and_then(qwerty_char)
    {
        out.push(Candidate::new(event.mods, us));
        return out;
    }
    let typed = if is_dead_or_non_ascii(event.key) {
        event.code.and_then(qwerty_char)
    } else {
        Some(event.key)
    };
    out.push(typed.and_then(|key| Candidate::new(event.mods, key)));
    if let Some(digit) = event.code.and_then(|c| c.strip_prefix("Digit"))
        && digit.len() == 1
        && digit.bytes().all(|b| b.is_ascii_digit())
    {
        out.push(Candidate::new(event.mods, digit));
    }
    if event.mods.shift
        && let Some(shifted) = event.shifted_key
        && shifted.is_ascii()
        && !shifted.chars().any(char::is_alphabetic)
    {
        out.push(Candidate::new(event.mods.without_shift(), shifted));
    }
    out
}

/// [`key_candidates`] as owned strokes.
pub fn candidates(layout: ShortcutLayout, event: &KeyEvent<'_>) -> Vec<Stroke> {
    key_candidates(layout, event).iter().map(Candidate::to_stroke).collect()
}

/// Whether `stroke` matches `event` in the `layout` mode: whether it is one of the key's
/// [`key_candidates`]. Modifiers always match exactly, Shift included, except for a character
/// the layout types only with Shift (followLayout).
pub fn stroke_matches(layout: ShortcutLayout, stroke: &Stroke, event: &KeyEvent<'_>) -> bool {
    key_candidates(layout, event).contains(stroke)
}
