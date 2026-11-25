//! [`Key`] and [`Modifier`] to macOS virtual key codes and CGEvent flags
//! (the ANSI layout's codes, `Events.h` `kVK_*`). Pure, so it is unit tested.

use crate::keys::{Key, Modifier};

pub const FLAG_SHIFT: u64 = 0x0002_0000;
pub const FLAG_CONTROL: u64 = 0x0004_0000;
pub const FLAG_ALTERNATE: u64 = 0x0008_0000;
pub const FLAG_COMMAND: u64 = 0x0010_0000;
pub const FLAG_FN: u64 = 0x0080_0000;

pub const KEY_RETURN: u16 = 36;
/// A key code no chord produces (F21..F24 have no Mac key).
pub const NO_KEY: u16 = 0xFFFF;
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

/// A menu item's key equivalent as AX reports it, made comparable.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct MenuItemKey {
    /// A printable character (letters, digits, punctuation).
    pub printable: Option<char>,
    /// Key codes for a non-character key (Return, Delete, Space, the arrows,
    /// F-keys), from each source that reports one: the character AppKit
    /// uses for it, AXMenuItemCmdVirtualKey and AXMenuItemCmdGlyph. The item
    /// matches a chord when any of them does, so sources that disagree fail
    /// closed.
    pub codes: Vec<u16>,
    /// The item has a key equivalent this table cannot place (a source it
    /// cannot map): the caller treats the walk as incomplete.
    pub unplaceable: bool,
    /// The key's character itself means Shift (backtab, U+0019, is
    /// shift+Tab).
    pub implied_shift: bool,
}

impl MenuItemKey {
    pub fn is_empty(&self) -> bool {
        self.printable.is_none() && self.codes.is_empty() && !self.unplaceable
    }
}

/// Reads a menu item's AXMenuItemCmdChar, AXMenuItemCmdVirtualKey and
/// AXMenuItemCmdGlyph. A printable character is the key (AX also reports
/// the virtual key of a letter's position, which a layout can move, so it
/// is not used then). Otherwise every source that is present is mapped.
pub fn menu_item_key(
    cmd_char: Option<&str>,
    virtual_key: Option<i64>,
    glyph: Option<i64>,
) -> MenuItemKey {
    let mut key = MenuItemKey::default();
    let mut special_char = false;
    if let Some(text) = cmd_char.filter(|c| !c.is_empty()) {
        let mut it = text.chars();
        match (it.next(), it.next()) {
            (Some(c), None) if !is_special_char(c) => {
                key.printable = Some(c);
                return key;
            }
            (Some(c), None) => {
                special_char = true;
                key.implied_shift = c == '\u{19}';
                match special_char_code(c) {
                    Some(code) => key.codes.push(code),
                    None => key.unplaceable = true,
                }
            }
            _ => key.unplaceable = true,
        }
    }
    if let Some(v) = virtual_key {
        match u16::try_from(v) {
            // A virtual key alone (no character) or with a special one.
            Ok(code) if special_char || cmd_char.is_none_or(str::is_empty) => key.codes.push(code),
            Ok(_) => {}
            Err(_) => key.unplaceable = true,
        }
    }
    // Glyph 0 is "no glyph" (kMenuNullGlyph).
    if let Some(g) = glyph.filter(|g| *g != 0) {
        match glyph_key_code(g) {
            Some(code) => key.codes.push(code),
            None => key.unplaceable = true,
        }
    }
    key.codes.sort_unstable();
    key.codes.dedup();
    key
}

/// The key code of an `AXMenuItemCmdGlyph` (HIToolbox Menus.h `kMenu*Glyph`).
fn glyph_key_code(glyph: i64) -> Option<u16> {
    Some(match glyph {
        0x02 => KEY_TAB,
        0x04 => 76,
        0x09 => 49,
        0x0A => 117,
        0x0B..=0x0D => KEY_RETURN,
        0x17 => 51,
        0x1B => 53,
        0x1C => 71,
        0x62 => 116,
        0x64 => 123,
        0x65 => 124,
        0x66 => 115,
        0x67 => 114, // Help
        0x68 => 126,
        0x69 => 119,
        0x6A => 125,
        0x6B => 121,
        0x6F..=0x7A => function_key((glyph - 0x6F + 1) as u8)?,
        0x87..=0x89 => function_key((glyph - 0x87 + 13) as u8)?,
        0x8F..=0x92 => function_key((glyph - 0x8F + 16) as u8)?,
        _ => return None,
    })
}

/// Whether a menu item's Option, Control and Command (AXMenuItemCmdModifiers)
/// are the chord's: an item that differs there can never be the chord,
/// whatever its key.
pub fn menu_mods_match(combo: &crate::keys::KeyCombo, menu_mods: i64) -> bool {
    let has = |m: Modifier| combo.modifiers.contains(&m);
    let wanted = (if has(Modifier::Alt) { MENU_OPTION } else { 0 })
        | (if has(Modifier::Control) { MENU_CONTROL } else { 0 })
        | (if has(Modifier::Meta) { 0 } else { MENU_NO_COMMAND });
    menu_mods & (MENU_OPTION | MENU_CONTROL | MENU_NO_COMMAND) == wanted
}

/// Whether a menu item's key equivalent is `combo`. `item` is the item's
/// key from menu_item_key (AppKit reports a letter upper-case, with Shift
/// in the modifiers).
pub fn menu_item_matches(
    combo: &crate::keys::KeyCombo,
    item: &MenuItemKey,
    menu_mods: i64,
) -> bool {
    let has = |m: Modifier| combo.modifiers.contains(&m);
    if !menu_mods_match(combo, menu_mods) {
        return false;
    }
    let menu_shift = menu_mods & MENU_SHIFT != 0 || item.implied_shift;
    match (&combo.key, item.printable) {
        (Key::Char(c), Some(i)) => {
            // Compare the physical key and Shift. AppKit stores Zoom In as "+"
            // with Command only: the character carries the Shift ("+" is
            // shift+=), and letters are reported upper-case without meaning
            // Shift (Shift is then the MENU_SHIFT bit).
            let (Some((item_code, item_char_shift)), Some((key_code_, key_char_shift))) =
                (char_key(i), char_key(*c))
            else {
                return i.to_lowercase().eq(c.to_lowercase()) && menu_shift == has(Modifier::Shift);
            };
            let item_shift = menu_shift || (item_char_shift && !i.is_ascii_alphabetic());
            // The chord's Shift: written, or implied by its character ("T",
            // "+"), as xdotool resolves a keysym that needs Shift.
            let key_shift = has(Modifier::Shift) || key_char_shift;
            item_code == key_code_ && item_shift == key_shift
        }
        (key, None) => match key_code(key) {
            Some((code, _)) => item.codes.contains(&code) && menu_shift == has(Modifier::Shift),
            None => false,
        },
        _ => false,
    }
}

/// Whether AppKit uses `c` for a non-character key in a key equivalent:
/// control characters, Space, and the function-key characters U+F700-F8FF
/// (arrows, F-keys, Home, End, Page Up/Down, Forward Delete, Help).
pub fn is_special_char(c: char) -> bool {
    c.is_control() || c == ' ' || (0xF700..=0xF8FF).contains(&(c as u32))
}

/// The key code of a non-character key by the character AppKit uses for it
/// in key equivalents (NSEvent's function-key characters), or None.
pub fn special_char_code(c: char) -> Option<u16> {
    Some(match c as u32 {
        0x7F | 0x08 => 51,                                            // Delete (backspace)
        0x1B => 53,                                                   // Escape
        0x03 => 76,                                                   // Enter (keypad)
        0x0D => KEY_RETURN,                                           // Return
        0x09 | 0x19 => KEY_TAB,                                       // Tab, backtab (shift+Tab)
        0x20 => 49,                                                   // Space
        0xF700 => 126,                                                // Up
        0xF701 => 125,                                                // Down
        0xF702 => 123,                                                // Left
        0xF703 => 124,                                                // Right
        0xF728 => 117,                                                // Forward Delete
        0xF729 => 115,                                                // Home
        0xF72B => 119,                                                // End
        0xF72C => 116,                                                // Page Up
        0xF72D => 121,                                                // Page Down
        0xF746 => 114,                                                // Help
        n @ 0xF704..=0xF717 => function_key((n - 0xF704 + 1) as u8)?, // F1..F20
        _ => return None,
    })
}

/// A Services key equivalent as (key code, CGEvent flags), on the ANSI
/// layout. Marks: "$" Shift, "^" Control, "~" Option, "@" Command. A
/// service's own NSKeyEquivalent implies Command (`implied_command`); the
/// person's assignments in System Settings spell it as "@". A key no posted
/// chord can produce is placed at NO_KEY; None only when the text is not one
/// key with marks (the caller then treats the whole list as unread).
pub fn service_shortcut(equivalent: &str, implied_command: bool) -> Option<(u16, u64)> {
    let mut flags = if implied_command { FLAG_COMMAND } else { 0 };
    let mut key = None;
    // Every character a mark ("@$"): the last one is the key.
    let all_marks = equivalent.chars().all(|c| matches!(c, '$' | '^' | '~' | '@'));
    let (marks, last) = match (all_marks, equivalent.char_indices().last()) {
        (true, Some((i, c))) => (&equivalent[..i], Some(c)),
        _ => (equivalent, None),
    };
    if let Some(c) = last {
        key = Some(c);
    }
    for c in marks.chars() {
        match c {
            '$' => flags |= FLAG_SHIFT,
            '^' => flags |= FLAG_CONTROL,
            '~' => flags |= FLAG_ALTERNATE,
            '@' => flags |= FLAG_COMMAND,
            other => {
                if key.is_some() {
                    return None;
                }
                key = Some(other);
            }
        }
    }
    let key = key?;
    // Non-character keys, by the characters AppKit uses for them.
    if (key as u32) >= 0xF718 && (key as u32) <= 0xF71B {
        // F21..F24 have no key on a Mac keyboard: no posted chord can be one.
        return Some((NO_KEY, flags));
    }
    if let Some(code) = special_char_code(key) {
        if key == '\u{19}' {
            flags |= FLAG_SHIFT; // backtab is shift+Tab
        }
        return Some((code, flags));
    }
    // Other function-key characters (Help, Insert, ...): no posted chord.
    if (0xF700..=0xF8FF).contains(&(key as u32)) {
        return Some((NO_KEY, flags));
    }
    // A key this table cannot place (a non-ANSI letter, Insert, a control
    // character with no key): no chord cmux posts can produce it, since
    // press_keys posts only from these same tables, so it cannot collide with
    // one. (A menu item's key the walk cannot place is different: it fails
    // closed there, since the walk cannot tell which chord it is.)
    let Some((code, shift)) = char_key(key) else { return Some((NO_KEY, flags)) };
    if shift || key.is_ascii_uppercase() {
        // A capital or shifted character means Shift (services write "B" for ⇧⌘B).
        flags |= FLAG_SHIFT;
    }
    Some((code, flags))
}

/// Whether a chord (key code and flags, Shift folded in) is one of the
/// registered Services shortcuts.
pub fn is_service_shortcut(code: u16, flags: u64, services: &[(u16, u64)]) -> bool {
    let mask = FLAG_SHIFT | FLAG_CONTROL | FLAG_ALTERNATE | FLAG_COMMAND;
    services.iter().any(|(c, f)| *c == code && (*f & mask) == (flags & mask))
}
