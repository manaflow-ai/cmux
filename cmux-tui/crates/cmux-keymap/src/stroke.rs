//! One stroke of the keybindings.json syntax: modifiers, then one key.

use crate::Mods;

/// The named keys a stroke may end with (key-styles.json's `$comment`).
pub(crate) const NAMED_KEYS: [&str; 8] =
    ["escape", "enter", "up", "down", "left", "right", "pageup", "pagedown"];

/// A named key's canonical name, accepting a few common spellings (`esc`, `return`,
/// `arrowdown`, `page_up`).
pub(crate) fn named_key(name: &str) -> Option<&'static str> {
    let lower = name.to_ascii_lowercase();
    let canonical = match lower.as_str() {
        "esc" => "escape",
        "return" => "enter",
        "arrowup" => "up",
        "arrowdown" => "down",
        "arrowleft" => "left",
        "arrowright" => "right",
        "page_up" => "pageup",
        "page_down" => "pagedown",
        other => other,
    };
    NAMED_KEYS.into_iter().find(|k| *k == canonical)
}

/// A parsed stroke: `cmd+shift+]` is cmd and shift, key `]`.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Stroke {
    pub mods: Mods,
    /// One character (ASCII letters lowercased) or a named key (`escape`, `pagedown`).
    pub key: String,
}

impl Stroke {
    /// Parses `ctrl+alt+shift+cmd+KEY` (any modifier order). The key may be `+` itself
    /// (`cmd++`). Returns None for an empty stroke, an unknown modifier, or a key that is
    /// neither one character nor a named key.
    pub fn parse(text: &str) -> Option<Stroke> {
        let text = text.trim();
        let (mod_part, key) = if text == "+" {
            ("", "+")
        } else if let Some(rest) = text.strip_suffix("++") {
            (rest, "+")
        } else {
            match text.rsplit_once('+') {
                Some((mods, key)) => (mods, key),
                None => ("", text),
            }
        };
        let mut mods = Mods::NONE;
        if !mod_part.is_empty() {
            for name in mod_part.split('+') {
                mods = mods.with_name(name.trim())?;
            }
        }
        let key = key.trim();
        let mut chars = key.chars();
        let key = match (chars.next(), chars.next()) {
            (Some(c), None) => c.to_lowercase().collect(),
            (Some(_), Some(_)) => named_key(key)?.to_owned(),
            (None, _) => return None,
        };
        Some(Stroke { mods, key })
    }

    pub fn is_named(&self) -> bool {
        NAMED_KEYS.contains(&self.key.as_str())
    }
}
