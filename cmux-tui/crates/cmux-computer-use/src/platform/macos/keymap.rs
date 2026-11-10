//! [`Key`] and [`Modifier`] to macOS virtual key codes and CGEvent flags
//! (the ANSI layout's codes, `Events.h` `kVK_*`). Pure, so it is unit tested.

use crate::keys::{Key, Modifier};

pub const FLAG_SHIFT: u64 = 0x0002_0000;
pub const FLAG_CONTROL: u64 = 0x0004_0000;
pub const FLAG_ALTERNATE: u64 = 0x0008_0000;
pub const FLAG_COMMAND: u64 = 0x0010_0000;
pub const FLAG_FN: u64 = 0x0080_0000;

pub const KEY_RETURN: u16 = 36;
pub const KEY_TAB: u16 = 48;

/// The CGEventFlags for a set of modifiers.
pub fn flags(modifiers: &[Modifier]) -> u64 {
    modifiers.iter().fold(0, |acc, m| {
        acc | match m {
            Modifier::Shift => FLAG_SHIFT,
            Modifier::Control => FLAG_CONTROL,
            Modifier::Alt => FLAG_ALTERNATE,
            Modifier::Meta => FLAG_COMMAND,
            Modifier::Fn => FLAG_FN,
        }
    })
}

/// The ANSI key that types `c` and whether it needs Shift. `None` for a
/// character that has no key on the US layout (it is typed as a Unicode
/// string instead).
pub fn char_key(c: char) -> Option<(u16, bool)> {
    let lower = c.to_ascii_lowercase();
    let shifted = c.is_ascii_uppercase();
    let plain = |code| Some((code, shifted));
    match lower {
        'a' => plain(0),
        's' => plain(1),
        'd' => plain(2),
        'f' => plain(3),
        'h' => plain(4),
        'g' => plain(5),
        'z' => plain(6),
        'x' => plain(7),
        'c' => plain(8),
        'v' => plain(9),
        'b' => plain(11),
        'q' => plain(12),
        'w' => plain(13),
        'e' => plain(14),
        'r' => plain(15),
        'y' => plain(16),
        't' => plain(17),
        'o' => plain(31),
        'u' => plain(32),
        'i' => plain(34),
        'p' => plain(35),
        'l' => plain(37),
        'j' => plain(38),
        'k' => plain(40),
        'n' => plain(45),
        'm' => plain(46),
        _ => punctuation(c),
    }
}

fn punctuation(c: char) -> Option<(u16, bool)> {
    Some(match c {
        '1' => (18, false),
        '!' => (18, true),
        '2' => (19, false),
        '@' => (19, true),
        '3' => (20, false),
        '#' => (20, true),
        '4' => (21, false),
        '$' => (21, true),
        '6' => (22, false),
        '^' => (22, true),
        '5' => (23, false),
        '%' => (23, true),
        '=' => (24, false),
        '+' => (24, true),
        '9' => (25, false),
        '(' => (25, true),
        '7' => (26, false),
        '&' => (26, true),
        '-' => (27, false),
        '_' => (27, true),
        '8' => (28, false),
        '*' => (28, true),
        '0' => (29, false),
        ')' => (29, true),
        ']' => (30, false),
        '}' => (30, true),
        '[' => (33, false),
        '{' => (33, true),
        '\'' => (39, false),
        '"' => (39, true),
        ';' => (41, false),
        ':' => (41, true),
        '\\' => (42, false),
        '|' => (42, true),
        ',' => (43, false),
        '<' => (43, true),
        '/' => (44, false),
        '?' => (44, true),
        '.' => (47, false),
        '>' => (47, true),
        '`' => (50, false),
        '~' => (50, true),
        ' ' => (49, false),
        '\n' | '\r' => (KEY_RETURN, false),
        '\t' => (KEY_TAB, false),
        _ => return None,
    })
}

fn function_key(n: u8) -> Option<u16> {
    Some(match n {
        1 => 122,
        2 => 120,
        3 => 99,
        4 => 118,
        5 => 96,
        6 => 97,
        7 => 98,
        8 => 100,
        9 => 101,
        10 => 109,
        11 => 103,
        12 => 111,
        13 => 105,
        14 => 107,
        15 => 113,
        16 => 106,
        17 => 64,
        18 => 79,
        19 => 80,
        20 => 90,
        _ => return None,
    })
}

/// A combo's key: the virtual key code and whether the key itself implies
/// Shift (`"cmd+?"` is cmd+shift+/).
pub fn key_code(key: &Key) -> Option<(u16, bool)> {
    Some(match key {
        Key::Char(c) => return char_key(*c),
        Key::Return => (KEY_RETURN, false),
        Key::Tab => (KEY_TAB, false),
        Key::Space => (49, false),
        Key::Backspace => (51, false),
        Key::Escape => (53, false),
        Key::Delete => (117, false),
        Key::Home => (115, false),
        Key::PageUp => (116, false),
        Key::End => (119, false),
        Key::PageDown => (121, false),
        Key::Left => (123, false),
        Key::Right => (124, false),
        Key::Down => (125, false),
        Key::Up => (126, false),
        Key::F(n) => (function_key(*n)?, false),
    })
}

/// Whether a key event for `key` should carry the character as its Unicode
/// string. Only a printable character with no command-style modifier: with
/// Control, Option or Command the app reads the key code (and the layout),
/// and a string would turn ctrl+c into a literal "c".
pub fn carries_text(key: &Key, flags: u64) -> Option<char> {
    match key {
        Key::Char(c)
            if flags & (FLAG_CONTROL | FLAG_COMMAND | FLAG_ALTERNATE) == 0 && !c.is_control() =>
        {
            Some(*c)
        }
        _ => None,
    }
}

/// `AXMenuItemCmdModifiers` bits (HIToolbox `kMenu*Modifier`): Command is
/// implied unless `MENU_NO_COMMAND` is set.
pub const MENU_SHIFT: i64 = 1;
pub const MENU_OPTION: i64 = 2;
pub const MENU_CONTROL: i64 = 4;
pub const MENU_NO_COMMAND: i64 = 8;

/// Whether a menu item's key equivalent is `combo`. `cmd_char` is
/// `AXMenuItemCmdChar` (AppKit reports it upper-case, with Shift in the
/// modifiers), `virtual_key` is `AXMenuItemCmdVirtualKey` for items whose
/// equivalent is a non-character key (arrows, Delete, F-keys).
pub fn menu_item_matches(
    combo: &crate::keys::KeyCombo,
    cmd_char: Option<&str>,
    virtual_key: Option<i64>,
    menu_mods: i64,
) -> bool {
    let has = |m: Modifier| combo.modifiers.contains(&m);
    let wanted = (if has(Modifier::Shift) { MENU_SHIFT } else { 0 })
        | (if has(Modifier::Alt) { MENU_OPTION } else { 0 })
        | (if has(Modifier::Control) { MENU_CONTROL } else { 0 })
        | (if has(Modifier::Meta) { 0 } else { MENU_NO_COMMAND });
    if menu_mods & 0x0f != wanted {
        return false;
    }
    match (&combo.key, cmd_char.filter(|c| !c.is_empty())) {
        (Key::Char(c), Some(item)) => {
            let mut chars = item.chars();
            matches!((chars.next(), chars.next()), (Some(i), None) if i.to_lowercase().eq(c.to_lowercase()))
        }
        (key, None) => match (key_code(key), virtual_key) {
            (Some((code, _)), Some(v)) => i64::from(code) == v,
            _ => false,
        },
        _ => false,
    }
}
