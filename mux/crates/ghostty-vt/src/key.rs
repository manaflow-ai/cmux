use std::ptr;

use ghostty_vt_sys as sys;

use crate::terminal::Terminal;
use crate::{check, Result};

/// Key press/release/repeat.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyAction {
    Press,
    Release,
    Repeat,
}

/// Modifier bitmask (GHOSTTY_MODS_*).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Mods(pub u16);

impl Mods {
    pub const SHIFT: Mods = Mods(sys::GHOSTTY_MODS_SHIFT as u16);
    pub const CTRL: Mods = Mods(sys::GHOSTTY_MODS_CTRL as u16);
    pub const ALT: Mods = Mods(sys::GHOSTTY_MODS_ALT as u16);
    pub const SUPER: Mods = Mods(sys::GHOSTTY_MODS_SUPER as u16);

    pub fn contains(self, other: Mods) -> bool {
        self.0 & other.0 == other.0
    }
}

impl std::ops::BitOr for Mods {
    type Output = Mods;
    fn bitor(self, rhs: Mods) -> Mods {
        Mods(self.0 | rhs.0)
    }
}

/// A single key event to encode.
#[derive(Debug, Clone, Default)]
pub struct KeyInput {
    /// W3C-style physical key (GHOSTTY_KEY_*), or GHOSTTY_KEY_UNIDENTIFIED.
    pub key: sys::GhosttyKey,
    pub mods: Mods,
    /// Modifiers already consumed to produce `utf8` (e.g. shift for 'A').
    pub consumed_mods: Mods,
    /// Text the key produces on the current layout, before Ctrl/Meta
    /// transformations. Must not contain C0 controls.
    pub utf8: String,
    /// Codepoint of the key without shift applied, when known.
    pub unshifted_codepoint: u32,
    pub action: Option<KeyAction>,
}

/// Encodes key events into the byte sequences an application expects,
/// honoring the terminal's current keyboard modes (cursor-key application
/// mode, kitty keyboard protocol, ...).
pub struct KeyEncoder {
    encoder: sys::GhosttyKeyEncoder,
    event: sys::GhosttyKeyEvent,
}

unsafe impl Send for KeyEncoder {}

impl KeyEncoder {
    pub fn new() -> Result<Self> {
        let mut encoder: sys::GhosttyKeyEncoder = ptr::null_mut();
        check(unsafe { sys::ghostty_key_encoder_new(ptr::null(), &mut encoder) })?;
        let mut event: sys::GhosttyKeyEvent = ptr::null_mut();
        if let Err(e) = check(unsafe { sys::ghostty_key_event_new(ptr::null(), &mut event) }) {
            unsafe { sys::ghostty_key_encoder_free(encoder) };
            return Err(e);
        }
        Ok(KeyEncoder { encoder, event })
    }

    /// Sync encoder options (DECCKM, kitty flags, ...) from a terminal.
    pub fn sync_from_terminal(&mut self, terminal: &Terminal) {
        unsafe {
            sys::ghostty_key_encoder_setopt_from_terminal(self.encoder, terminal.raw());
        }
    }

    /// Encode `input` and append the resulting bytes to `out`.
    pub fn encode(&mut self, input: &KeyInput, out: &mut Vec<u8>) -> Result<()> {
        let action = match input.action.unwrap_or(KeyAction::Press) {
            KeyAction::Press => sys::GHOSTTY_KEY_ACTION_PRESS,
            KeyAction::Release => sys::GHOSTTY_KEY_ACTION_RELEASE,
            KeyAction::Repeat => sys::GHOSTTY_KEY_ACTION_REPEAT,
        };
        unsafe {
            sys::ghostty_key_event_set_action(self.event, action);
            sys::ghostty_key_event_set_key(self.event, input.key);
            sys::ghostty_key_event_set_mods(self.event, input.mods.0);
            sys::ghostty_key_event_set_consumed_mods(self.event, input.consumed_mods.0);
            sys::ghostty_key_event_set_composing(self.event, false);
            sys::ghostty_key_event_set_unshifted_codepoint(self.event, input.unshifted_codepoint);
            // The event borrows the utf8 buffer; `input` outlives the
            // encode call below, so the borrow is valid for its lifetime.
            if input.utf8.is_empty() {
                sys::ghostty_key_event_set_utf8(self.event, ptr::null(), 0);
            } else {
                sys::ghostty_key_event_set_utf8(
                    self.event,
                    input.utf8.as_ptr() as *const i8,
                    input.utf8.len(),
                );
            }
        }

        let mut buf = [0u8; 256];
        let mut written: usize = 0;
        let result = unsafe {
            sys::ghostty_key_encoder_encode(
                self.encoder,
                self.event,
                buf.as_mut_ptr() as *mut i8,
                buf.len(),
                &mut written,
            )
        };
        if result == sys::GHOSTTY_OUT_OF_SPACE {
            let mut big = vec![0u8; written.max(buf.len() * 2)];
            let mut written2: usize = 0;
            check(unsafe {
                sys::ghostty_key_encoder_encode(
                    self.encoder,
                    self.event,
                    big.as_mut_ptr() as *mut i8,
                    big.len(),
                    &mut written2,
                )
            })?;
            out.extend_from_slice(&big[..written2]);
            return Ok(());
        }
        check(result)?;
        out.extend_from_slice(&buf[..written]);
        Ok(())
    }
}

impl Drop for KeyEncoder {
    fn drop(&mut self) {
        unsafe {
            sys::ghostty_key_event_free(self.event);
            sys::ghostty_key_encoder_free(self.encoder);
        }
    }
}

/// Clear the borrowed utf8 pointer after encode? Not needed: the event is
/// only read during `ghostty_key_encoder_encode`, and we always set utf8
/// before each encode call.
#[cfg(test)]
mod tests {
    use super::*;
    use crate::Callbacks;

    #[test]
    fn encodes_ctrl_c() {
        let mut enc = KeyEncoder::new().unwrap();
        let mut out = Vec::new();
        enc.encode(
            &KeyInput {
                key: sys::GHOSTTY_KEY_C,
                mods: Mods::CTRL,
                unshifted_codepoint: 'c' as u32,
                ..Default::default()
            },
            &mut out,
        )
        .unwrap();
        assert_eq!(out, vec![0x03]);
    }

    #[test]
    fn encodes_arrow_application_mode() {
        // DECCKM off: ESC [ A. After enabling application cursor keys via
        // the terminal, syncing makes it ESC O A.
        let mut term = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
        let mut enc = KeyEncoder::new().unwrap();
        let up = KeyInput {
            key: sys::GHOSTTY_KEY_ARROW_UP,
            ..Default::default()
        };

        let mut out = Vec::new();
        enc.sync_from_terminal(&term);
        enc.encode(&up, &mut out).unwrap();
        assert_eq!(out, b"\x1b[A");

        term.vt_write(b"\x1b[?1h");
        enc.sync_from_terminal(&term);
        out.clear();
        enc.encode(&up, &mut out).unwrap();
        assert_eq!(out, b"\x1bOA");
    }
}
