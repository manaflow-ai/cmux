//! X11 keysyms for KeyEvent (RFC 6143 7.5.4). The same keysyms drive
//! macOS Screen Sharing, Windows servers and X servers.

/// A key, independent of any terminal or UI toolkit.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Key {
    Char(char),
    Backspace,
    Tab,
    Enter,
    Escape,
    Delete,
    Insert,
    Home,
    End,
    PageUp,
    PageDown,
    Left,
    Right,
    Up,
    Down,
    /// F1 to F35.
    F(u8),
    Shift,
    Control,
    /// Option on a Mac guest.
    Alt,
    /// Command on a Mac guest, the Windows key on Windows, Super on Linux.
    Super,
    Meta,
    CapsLock,
    NumLock,
    ScrollLock,
    PrintScreen,
    Pause,
    Menu,
}

/// The keysym of `key`, or `None` for a key with no keysym (F0, F36+).
pub fn keysym(key: Key) -> Option<u32> {
    Some(match key {
        Key::Char(c) => return Some(char_keysym(c)),
        Key::Backspace => 0xFF08,
        Key::Tab => 0xFF09,
        Key::Enter => 0xFF0D,
        Key::Escape => 0xFF1B,
        Key::Delete => 0xFFFF,
        Key::Insert => 0xFF63,
        Key::Home => 0xFF50,
        Key::Left => 0xFF51,
        Key::Up => 0xFF52,
        Key::Right => 0xFF53,
        Key::Down => 0xFF54,
        Key::PageUp => 0xFF55,
        Key::PageDown => 0xFF56,
        Key::End => 0xFF57,
        Key::F(n @ 1..=35) => 0xFFBE + u32::from(n) - 1,
        Key::F(_) => return None,
        Key::Shift => 0xFFE1,
        Key::Control => 0xFFE3,
        Key::Meta => 0xFFE7,
        Key::Alt => 0xFFE9,
        Key::Super => 0xFFEB,
        Key::CapsLock => 0xFFE5,
        Key::NumLock => 0xFF7F,
        Key::ScrollLock => 0xFF14,
        Key::PrintScreen => 0xFF61,
        Key::Pause => 0xFF13,
        Key::Menu => 0xFF67,
    })
}

/// A character's keysym: Latin-1 maps to itself, control characters to
/// their keys, everything else to the Unicode keysym range (0x01000000 +
/// code point), which X, macOS and Windows servers all accept.
pub fn char_keysym(c: char) -> u32 {
    let code = u32::from(c);
    match code {
        0x08 => 0xFF08,
        0x09 => 0xFF09,
        0x0A | 0x0D => 0xFF0D,
        0x1B => 0xFF1B,
        0x7F => 0xFFFF,
        0x20..=0x7E | 0xA0..=0xFF => code,
        _ => 0x0100_0000 + code,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keysyms_match_x11() {
        assert_eq!(keysym(Key::Char('a')), Some(0x61));
        assert_eq!(keysym(Key::Char('é')), Some(0xE9));
        assert_eq!(keysym(Key::Char('€')), Some(0x0100_20AC));
        assert_eq!(keysym(Key::Enter), Some(0xFF0D));
        assert_eq!(keysym(Key::F(1)), Some(0xFFBE));
        assert_eq!(keysym(Key::F(12)), Some(0xFFC9));
        assert_eq!(keysym(Key::F(0)), None);
        assert_eq!(keysym(Key::Super), Some(0xFFEB));
        assert_eq!(char_keysym('\r'), 0xFF0D);
    }
}
