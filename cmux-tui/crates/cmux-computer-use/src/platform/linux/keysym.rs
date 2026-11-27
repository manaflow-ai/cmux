//! X keysyms: the one key vocabulary of X11, xkbcommon (Wayland virtual
//! keyboards) and the RemoteDesktop portal (`NotifyKeyboardKeysym`).

use crate::keys::{Key, Modifier};

pub const SHIFT_L: u32 = 0xffe1;
pub const CONTROL_L: u32 = 0xffe3;
pub const ALT_L: u32 = 0xffe9;
pub const SUPER_L: u32 = 0xffeb;
pub const RETURN: u32 = 0xff0d;
pub const TAB: u32 = 0xff09;

/// Linux input event codes for the pointer buttons (portal, virtual pointer).
pub const BTN_LEFT: u32 = 0x110;
pub const BTN_RIGHT: u32 = 0x111;
pub const BTN_MIDDLE: u32 = 0x112;

/// The keysym of one character.
pub fn of_char(c: char) -> u32 {
    match c {
        '\n' | '\r' => RETURN,
        '\t' => TAB,
        '\u{8}' => 0xff08,
        c => {
            let cp = c as u32;
            if (0x20..=0x7e).contains(&cp) || (0xa0..=0xff).contains(&cp) {
                cp
            } else {
                0x0100_0000 | cp
            }
        }
    }
}

/// The keysym of a named key or a character.
pub fn of_key(key: &Key) -> u32 {
    match key {
        Key::Char(c) => of_char(*c),
        Key::Return => RETURN,
        Key::Tab => TAB,
        Key::Space => 0x20,
        Key::Backspace => 0xff08,
        Key::Delete => 0xffff,
        Key::Escape => 0xff1b,
        Key::Left => 0xff51,
        Key::Up => 0xff52,
        Key::Right => 0xff53,
        Key::Down => 0xff54,
        Key::Home => 0xff50,
        Key::End => 0xff57,
        Key::PageUp => 0xff55,
        Key::PageDown => 0xff56,
        Key::F(n) => 0xffbe + u32::from(n.saturating_sub(1)),
    }
}

/// The keysym of a modifier key; `Fn` has none on Linux.
pub fn of_modifier(m: Modifier) -> Option<u32> {
    match m {
        Modifier::Shift => Some(SHIFT_L),
        Modifier::Control => Some(CONTROL_L),
        Modifier::Alt => Some(ALT_L),
        Modifier::Meta => Some(SUPER_L),
        Modifier::Fn => None,
    }
}

/// The core X modifier mask bit of a modifier (Shift, Control, Mod1, Mod4),
/// as the standard xkb "complete" compat assigns them.
pub fn mask_of(m: Modifier) -> u32 {
    match m {
        Modifier::Shift => 1,
        Modifier::Control => 4,
        Modifier::Alt => 8,
        Modifier::Meta => 64,
        Modifier::Fn => 0,
    }
}

/// The xkb name of a keysym for a generated keymap (`0x1000041` form works
/// for every keysym in xkbcommon).
pub fn xkb_name(keysym: u32) -> String {
    match keysym {
        SHIFT_L => "Shift_L".into(),
        CONTROL_L => "Control_L".into(),
        ALT_L => "Alt_L".into(),
        SUPER_L => "Super_L".into(),
        k => format!("0x{k:08x}"),
    }
}

/// An xkb keymap with one key per keysym in `syms`, keycode `9 + index`
/// (evdev code `1 + index`, see [`evdev_code`]), and the four modifiers on their usual mods.
/// Virtual keyboards upload it, so any character types with one key and no
/// dependence on the person's layout.
pub fn keymap_for(syms: &[u32]) -> String {
    let mut keycodes = String::new();
    let mut symbols = String::new();
    let mut mods = String::new();
    for (i, sym) in syms.iter().enumerate() {
        let code = 9 + i;
        keycodes.push_str(&format!("    <K{code}> = {code};\n"));
        symbols.push_str(&format!("    key <K{code}> {{ [ {} ] }};\n", xkb_name(*sym)));
        let modname = match *sym {
            SHIFT_L => Some("Shift"),
            CONTROL_L => Some("Control"),
            ALT_L => Some("Mod1"),
            SUPER_L => Some("Mod4"),
            _ => None,
        };
        if let Some(m) = modname {
            mods.push_str(&format!("    modifier_map {m} {{ <K{code}> }};\n"));
        }
    }
    let max = (9 + syms.len()).max(10);
    format!(
        "xkb_keymap {{\n  xkb_keycodes \"cmux\" {{\n    minimum = 8;\n    maximum = {max};\n{keycodes}  }};\n  xkb_types \"cmux\" {{ include \"complete\" }};\n  xkb_compat \"cmux\" {{ include \"complete\" }};\n  xkb_symbols \"cmux\" {{\n{symbols}{mods}  }};\n}};\n"
    )
}

/// The evdev code a virtual keyboard sends for `syms[index]` of
/// [`keymap_for`] (xkb keycode minus 8).
pub fn evdev_code(index: usize) -> u32 {
    1 + index as u32
}
