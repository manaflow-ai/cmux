//! A held key as the daemon takes it for a terminal whose view is gone (Swift
//! `HeldKeyInput`): `text` is written as typed (`send`), `key` is a chord the
//! daemon encodes with the terminal's own modes (`send-key`). The app reads
//! each `NSEvent` into [`KeyFacts`].

use serde::{Deserialize, Serialize};

/// `NSEvent.ModifierFlags` bits.
pub const SHIFT: u64 = 1 << 17;
pub const CONTROL: u64 = 1 << 18;
pub const OPTION: u64 = 1 << 19;
pub const COMMAND: u64 = 1 << 20;
/// The device bits of the left and right Option keys (IOKit's
/// NX_DEVICELALTKEYMASK and NX_DEVICERALTKEYMASK).
pub const LEFT_OPTION: u64 = 0x20;
pub const RIGHT_OPTION: u64 = 0x40;

/// What the app reads of a key-down.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct KeyFacts {
    pub key_code: u16,
    /// `modifierFlags.rawValue`, device bits included.
    pub flags: u64,
    pub characters: Option<String>,
    pub characters_ignoring_modifiers: Option<String>,
}

/// One input for the daemon's terminal.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum HeldKeyInput {
    Text(String),
    Key(String),
}

/// The daemon's names (`key_input_from_chord`) of keys typed by key code.
pub fn key_name(code: u16) -> Option<&'static str> {
    Some(match code {
        36 | 76 => "enter",
        48 => "tab",
        49 => "space",
        53 => "esc",
        51 => "backspace",
        117 => "delete",
        114 => "insert",
        123 => "left",
        124 => "right",
        125 => "down",
        126 => "up",
        115 => "home",
        119 => "end",
        116 => "pageup",
        121 => "pagedown",
        122 => "f1",
        120 => "f2",
        99 => "f3",
        118 => "f4",
        96 => "f5",
        97 => "f6",
        98 => "f7",
        100 => "f8",
        101 => "f9",
        109 => "f10",
        103 => "f11",
        111 => "f12",
        105 => "f13",
        107 => "f14",
        113 => "f15",
        106 => "f16",
        64 => "f17",
        79 => "f18",
        80 => "f19",
        90 => "f20",
        _ => return None,
    })
}

/// One printable ASCII character (no space): what the daemon names a chord by.
fn one_printable(text: &str) -> bool {
    let mut chars = text.chars();
    matches!((chars.next(), chars.next()), (Some(c), None) if c.is_ascii() && u32::from(c) > 0x20)
}

/// `key` as the daemon takes it: a named key, a chord with Control or
/// Command, or an Option key that `option_as_alt` (Ghostty's
/// `macos-option-as-alt`: `true`, `left`, `right`) makes Alt is a `key`; other
/// typing is `text`. None: a key with no daemon name.
pub fn input(key: &KeyFacts, option_as_alt: Option<&str>) -> Option<HeldKeyInput> {
    let flags = key.flags;
    let side = flags & (LEFT_OPTION | RIGHT_OPTION);
    let has = |bit: u64| flags & bit != 0;
    let alt_key = has(OPTION)
        && (option_as_alt == Some("true")
            || (option_as_alt == Some("left") && side & LEFT_OPTION != 0)
            || (option_as_alt == Some("right") && side & RIGHT_OPTION != 0));
    let mut mods: Vec<&str> = Vec::new();
    for (bit, name) in [(COMMAND, "cmd"), (CONTROL, "ctrl"), (OPTION, "alt"), (SHIFT, "shift")] {
        if has(bit) {
            mods.push(name);
        }
    }
    if let Some(name) = key_name(key.key_code) {
        mods.push(name);
        return Some(HeldKeyInput::Key(mods.join("+")));
    }
    let plain = !has(COMMAND) && !has(CONTROL);
    if plain && alt_key {
        let base =
            key.characters_ignoring_modifiers.as_deref().filter(|base| one_printable(base))?;
        return Some(HeldKeyInput::Key(format!("alt+{base}")));
    }
    if plain {
        let text = key.characters.as_deref().filter(|text| !text.is_empty())?;
        return Some(HeldKeyInput::Text(text.to_owned()));
    }
    let character = key.characters_ignoring_modifiers.as_deref()?.to_lowercase();
    if !one_printable(&character) {
        return None;
    }
    mods.push(&character);
    Some(HeldKeyInput::Key(mods.join("+")))
}

/// The inputs of `keys`, in order, consecutive text merged; the count of keys
/// left out (no daemon name) is the second value.
pub fn inputs(keys: &[KeyFacts], option_as_alt: Option<&str>) -> (Vec<HeldKeyInput>, usize) {
    let mut out: Vec<HeldKeyInput> = Vec::new();
    let mut skipped = 0;
    for key in keys {
        let Some(one) = input(key, option_as_alt) else {
            skipped += 1;
            continue;
        };
        match (one, out.last_mut()) {
            (HeldKeyInput::Text(more), Some(HeldKeyInput::Text(earlier))) => {
                earlier.push_str(&more)
            }
            (one, _) => out.push(one),
        }
    }
    (out, skipped)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(characters: &str, flags: u64, ignoring: Option<&str>, code: u16) -> KeyFacts {
        KeyFacts {
            key_code: code,
            flags,
            characters: Some(characters.to_owned()),
            characters_ignoring_modifiers: Some(ignoring.unwrap_or(characters).to_owned()),
        }
    }

    fn option_a(left: bool) -> KeyFacts {
        key("å", OPTION | if left { LEFT_OPTION } else { RIGHT_OPTION }, Some("a"), 0)
    }

    #[test]
    fn option_is_alt_when_the_setting_says_so() {
        let (left, right) = (option_a(true), option_a(false));
        let alt = Some(HeldKeyInput::Key("alt+a".into()));
        let composed = Some(HeldKeyInput::Text("å".into()));
        assert_eq!(input(&left, Some("true")), alt);
        assert_eq!(input(&right, Some("true")), alt);
        assert_eq!(input(&left, Some("left")), alt);
        assert_eq!(
            input(&right, Some("left")),
            composed,
            "the right Option key composes when only the left one is Alt"
        );
        assert_eq!(input(&right, Some("right")), alt);
        assert_eq!(input(&left, Some("false")), composed);
        assert_eq!(input(&left, None), composed);
    }

    #[test]
    fn control_arrows_and_text_keep_their_order() {
        const FUNCTION: u64 = 1 << 23;
        const NUMERIC_PAD: u64 = 1 << 21;
        let keys = [
            key("l", 0, None, 37),
            key("s", 0, None, 1),
            key("\u{F700}", FUNCTION | NUMERIC_PAD, None, 126),
            key("\u{3}", CONTROL, Some("c"), 8),
            key("\r", 0, None, 36),
        ];
        let (got, skipped) = inputs(&keys, None);
        assert_eq!(
            got,
            vec![
                HeldKeyInput::Text("ls".into()),
                HeldKeyInput::Key("up".into()),
                HeldKeyInput::Key("ctrl+c".into()),
                HeldKeyInput::Key("enter".into()),
            ]
        );
        assert_eq!(skipped, 0);
    }

    #[test]
    fn a_chord_names_its_unshifted_character_and_a_key_with_no_name_is_skipped() {
        assert_eq!(
            input(&key("C", COMMAND | SHIFT, Some("C"), 8), None),
            Some(HeldKeyInput::Key("cmd+shift+c".into()))
        );
        assert_eq!(
            input(&key("\u{0}", CONTROL, Some(" "), 49), None),
            Some(HeldKeyInput::Key("ctrl+space".into()))
        );
        let (got, skipped) =
            inputs(&[key("x", CONTROL, Some("é"), 200), key("", 0, Some(""), 0)], None);
        assert!(got.is_empty());
        assert_eq!(skipped, 2);
    }
}
