use std::ptr;

use ghostty_vt_sys as sys;

use crate::terminal::Terminal;
use crate::{Error, Result, check};

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
    pub const CAPS_LOCK: Mods = Mods(sys::GHOSTTY_MODS_CAPS_LOCK as u16);
    pub const NUM_LOCK: Mods = Mods(sys::GHOSTTY_MODS_NUM_LOCK as u16);

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

fn physical_key_for_char(c: char) -> sys::GhosttyKey {
    match c.to_ascii_lowercase() {
        'a' => sys::GHOSTTY_KEY_A,
        'b' => sys::GHOSTTY_KEY_B,
        'c' => sys::GHOSTTY_KEY_C,
        'd' => sys::GHOSTTY_KEY_D,
        'e' => sys::GHOSTTY_KEY_E,
        'f' => sys::GHOSTTY_KEY_F,
        'g' => sys::GHOSTTY_KEY_G,
        'h' => sys::GHOSTTY_KEY_H,
        'i' => sys::GHOSTTY_KEY_I,
        'j' => sys::GHOSTTY_KEY_J,
        'k' => sys::GHOSTTY_KEY_K,
        'l' => sys::GHOSTTY_KEY_L,
        'm' => sys::GHOSTTY_KEY_M,
        'n' => sys::GHOSTTY_KEY_N,
        'o' => sys::GHOSTTY_KEY_O,
        'p' => sys::GHOSTTY_KEY_P,
        'q' => sys::GHOSTTY_KEY_Q,
        'r' => sys::GHOSTTY_KEY_R,
        's' => sys::GHOSTTY_KEY_S,
        't' => sys::GHOSTTY_KEY_T,
        'u' => sys::GHOSTTY_KEY_U,
        'v' => sys::GHOSTTY_KEY_V,
        'w' => sys::GHOSTTY_KEY_W,
        'x' => sys::GHOSTTY_KEY_X,
        'y' => sys::GHOSTTY_KEY_Y,
        'z' => sys::GHOSTTY_KEY_Z,
        '0' => sys::GHOSTTY_KEY_DIGIT_0,
        '1' => sys::GHOSTTY_KEY_DIGIT_1,
        '2' => sys::GHOSTTY_KEY_DIGIT_2,
        '3' => sys::GHOSTTY_KEY_DIGIT_3,
        '4' => sys::GHOSTTY_KEY_DIGIT_4,
        '5' => sys::GHOSTTY_KEY_DIGIT_5,
        '6' => sys::GHOSTTY_KEY_DIGIT_6,
        '7' => sys::GHOSTTY_KEY_DIGIT_7,
        '8' => sys::GHOSTTY_KEY_DIGIT_8,
        '9' => sys::GHOSTTY_KEY_DIGIT_9,
        ' ' => sys::GHOSTTY_KEY_SPACE,
        '`' => sys::GHOSTTY_KEY_BACKQUOTE,
        '\\' => sys::GHOSTTY_KEY_BACKSLASH,
        '[' => sys::GHOSTTY_KEY_BRACKET_LEFT,
        ']' => sys::GHOSTTY_KEY_BRACKET_RIGHT,
        ',' => sys::GHOSTTY_KEY_COMMA,
        '=' => sys::GHOSTTY_KEY_EQUAL,
        '-' => sys::GHOSTTY_KEY_MINUS,
        '.' => sys::GHOSTTY_KEY_PERIOD,
        '\'' => sys::GHOSTTY_KEY_QUOTE,
        ';' => sys::GHOSTTY_KEY_SEMICOLON,
        '/' => sys::GHOSTTY_KEY_SLASH,
        _ => sys::GHOSTTY_KEY_UNIDENTIFIED,
    }
}

/// Parse a lower-case socket/CLI key chord into a Ghostty encoder input.
pub fn key_input_from_chord(chord: &str) -> Option<KeyInput> {
    let mut mods = Mods::default();
    let mut key_name = None;
    for part in chord.split('+') {
        match part {
            "ctrl" | "control" => mods = mods | Mods::CTRL,
            "alt" | "option" => mods = mods | Mods::ALT,
            "shift" => mods = mods | Mods::SHIFT,
            // Command on macOS: a Kitty-protocol program reads Cmd-C, Cmd-Z, Cmd-A
            // (legacy encoding sends nothing for it, as Ghostty does).
            "super" | "cmd" | "command" => mods = mods | Mods::SUPER,
            "" => return None,
            other => {
                if key_name.is_some() {
                    return None;
                }
                key_name = Some(other);
            }
        }
    }
    let key_name = key_name?;
    let mut input = KeyInput { mods, action: Some(KeyAction::Press), ..Default::default() };
    match key_name {
        "enter" | "return" => input.key = sys::GHOSTTY_KEY_ENTER,
        "tab" => input.key = sys::GHOSTTY_KEY_TAB,
        "backtab" => {
            input.key = sys::GHOSTTY_KEY_TAB;
            input.mods = input.mods | Mods::SHIFT;
        }
        "escape" | "esc" => input.key = sys::GHOSTTY_KEY_ESCAPE,
        "backspace" => input.key = sys::GHOSTTY_KEY_BACKSPACE,
        "delete" => input.key = sys::GHOSTTY_KEY_DELETE,
        "insert" => input.key = sys::GHOSTTY_KEY_INSERT,
        "up" => input.key = sys::GHOSTTY_KEY_ARROW_UP,
        "down" => input.key = sys::GHOSTTY_KEY_ARROW_DOWN,
        "left" => input.key = sys::GHOSTTY_KEY_ARROW_LEFT,
        "right" => input.key = sys::GHOSTTY_KEY_ARROW_RIGHT,
        "home" => input.key = sys::GHOSTTY_KEY_HOME,
        "end" => input.key = sys::GHOSTTY_KEY_END,
        "pageup" => input.key = sys::GHOSTTY_KEY_PAGE_UP,
        "pagedown" => input.key = sys::GHOSTTY_KEY_PAGE_DOWN,
        "space" => {
            input.key = sys::GHOSTTY_KEY_SPACE;
            input.unshifted_codepoint = ' ' as u32;
            if !mods.contains(Mods::CTRL) {
                input.utf8 = " ".to_string();
            }
        }
        name if name.len() == 1 => {
            let c = name.chars().next()?;
            input.key = physical_key_for_char(c);
            if input.key == sys::GHOSTTY_KEY_UNIDENTIFIED {
                return None;
            }
            input.unshifted_codepoint = c.to_ascii_lowercase() as u32;
            if !mods.contains(Mods::CTRL) {
                input.utf8 = c.to_string();
                if mods.contains(Mods::SHIFT) {
                    input.consumed_mods = Mods::SHIFT;
                }
            }
        }
        name if name.starts_with('f') => {
            let n = name.strip_prefix('f')?.parse::<u32>().ok()?;
            if !(1..=24).contains(&n) {
                return None;
            }
            input.key = sys::GHOSTTY_KEY_F1 + (n as sys::GhosttyKey - 1);
        }
        _ => return None,
    }
    Some(input)
}

/// A single key event to encode.
#[derive(Debug, Clone)]
pub struct KeyInput {
    /// W3C-style physical key (GHOSTTY_KEY_*), or GHOSTTY_KEY_UNIDENTIFIED.
    pub key: sys::GhosttyKey,
    pub mods: Mods,
    /// Modifiers already consumed to produce `utf8` (e.g. shift for 'A').
    pub consumed_mods: Mods,
    /// Whether this key is part of an uncommitted composition sequence.
    pub composing: bool,
    /// Text the key produces on the current layout, before Ctrl/Meta
    /// transformations. Must not contain C0 controls.
    pub utf8: String,
    /// Codepoint of the key without shift applied, when known.
    pub unshifted_codepoint: u32,
    /// Shifted logical identity reported by an outer CSI-u terminal.
    pub shifted_codepoint: u32,
    /// Explicit PC-101 base-layout identity reported by an outer CSI-u
    /// terminal, or zero when no identity was reported.
    pub base_layout_codepoint: u32,
    pub action: Option<KeyAction>,
    /// Whether an Alt modifier is a logical terminal modifier. This is false
    /// when macOS Option was consumed to produce `utf8` for this event.
    pub macos_option_as_alt: bool,
}

impl Default for KeyInput {
    fn default() -> Self {
        Self {
            key: sys::GHOSTTY_KEY_UNIDENTIFIED,
            mods: Mods::default(),
            consumed_mods: Mods::default(),
            composing: false,
            utf8: String::new(),
            unshifted_codepoint: 0,
            shifted_codepoint: 0,
            base_layout_codepoint: 0,
            action: None,
            macos_option_as_alt: true,
        }
    }
}

/// Encodes key events into the byte sequences an application expects,
/// honoring the terminal's current keyboard modes (cursor-key application
/// mode, kitty keyboard protocol, ...).
pub struct KeyEncoder {
    encoder: sys::GhosttyKeyEncoder,
    event: sys::GhosttyKeyEvent,
}

// SAFETY: the encoder and event have no thread affinity (as MouseEncoder's);
// this value owns both and every use takes &mut self.
unsafe impl Send for KeyEncoder {}

impl KeyEncoder {
    pub fn new() -> Result<Self> {
        let mut encoder: sys::GhosttyKeyEncoder = ptr::null_mut();
        // SAFETY: `encoder` is a writable local; a null allocator selects the default.
        check(unsafe { sys::ghostty_key_encoder_new(ptr::null(), &mut encoder) })?;
        let mut event: sys::GhosttyKeyEvent = ptr::null_mut();
        // SAFETY: `event` is a writable local; a null allocator selects the default.
        if let Err(e) = check(unsafe { sys::ghostty_key_event_new(ptr::null(), &mut event) }) {
            // SAFETY: `encoder` came from key_encoder_new above and nothing else owns it.
            unsafe { sys::ghostty_key_encoder_free(encoder) };
            return Err(e);
        }
        Ok(KeyEncoder { encoder, event })
    }

    /// Sync encoder options (DECCKM, kitty flags, ...) from a terminal.
    pub fn sync_from_terminal(&mut self, terminal: &Terminal) {
        // SAFETY: `self.encoder` is this value's live encoder and `terminal.raw()`
        // the live terminal `&Terminal` borrows; the call reads only its modes.
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
        // SAFETY: `self.encoder` and `self.event` are this value's live handles;
        // MACOS_OPTION_AS_ALT reads a GhosttyOptionAsAlt from the live local, and the
        // utf8 pointer is null with length 0 or `input.utf8`, which outlives the encode
        // below (the next encode replaces it before any read).
        unsafe {
            let option_as_alt = if input.macos_option_as_alt {
                sys::GHOSTTY_OPTION_AS_ALT_TRUE
            } else {
                sys::GHOSTTY_OPTION_AS_ALT_FALSE
            };
            sys::ghostty_key_encoder_setopt(
                self.encoder,
                sys::GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT,
                ptr::from_ref(&option_as_alt).cast(),
            );
            sys::ghostty_key_event_set_action(self.event, action);
            sys::ghostty_key_event_set_key(self.event, input.key);
            sys::ghostty_key_event_set_mods(self.event, input.mods.0);
            sys::ghostty_key_event_set_consumed_mods(self.event, input.consumed_mods.0);
            sys::ghostty_key_event_set_composing(self.event, input.composing);
            sys::ghostty_key_event_set_unshifted_codepoint(self.event, input.unshifted_codepoint);
            // The event borrows the utf8 buffer; `input` outlives the
            // encode call below, so the borrow is valid for its lifetime.
            if input.utf8.is_empty() {
                sys::ghostty_key_event_set_utf8(self.event, ptr::null(), 0);
            } else {
                sys::ghostty_key_event_set_utf8(
                    self.event,
                    input.utf8.as_ptr() as *const std::os::raw::c_char,
                    input.utf8.len(),
                );
            }
        }

        let mut buf = [0u8; 256];
        let mut written: usize = 0;
        // SAFETY: both handles are live; `buf` is writable for `buf.len()` bytes and
        // `written` is a writable local.
        let result = unsafe {
            sys::ghostty_key_encoder_encode(
                self.encoder,
                self.event,
                buf.as_mut_ptr() as *mut std::os::raw::c_char,
                buf.len(),
                &mut written,
            )
        };
        if result == sys::GHOSTTY_OUT_OF_SPACE {
            let mut big = vec![0u8; written.max(buf.len() * 2)];
            let mut written2: usize = 0;
            // SAFETY: both handles are live; `big` is writable for `big.len()` bytes and
            // `written2` is a writable local.
            check(unsafe {
                sys::ghostty_key_encoder_encode(
                    self.encoder,
                    self.event,
                    big.as_mut_ptr() as *mut std::os::raw::c_char,
                    big.len(),
                    &mut written2,
                )
            })?;
            // A written length past the buffer breaks the encoder's contract.
            append_encoded_key(input, big.get(..written2).ok_or(Error::OutOfSpace)?, out);
            return Ok(());
        }
        check(result)?;
        append_encoded_key(input, buf.get(..written).ok_or(Error::OutOfSpace)?, out);
        Ok(())
    }
}

/// Ghostty's public key-event ABI accepts the physical key but not explicitly
/// reported CSI-u shifted or base-layout codepoints. Restore missing
/// alternates only on CSI-u output that already has alternate slots. Decimal
/// rendering stays on the stack and output is appended in one pass.
fn append_encoded_key(input: &KeyInput, encoded: &[u8], out: &mut Vec<u8>) {
    if input.shifted_codepoint == 0 && input.base_layout_codepoint == 0 {
        out.extend_from_slice(encoded);
        return;
    }
    let Some(rest) = encoded.strip_prefix(b"\x1b[").filter(|rest| rest.ends_with(b"u")) else {
        out.extend_from_slice(encoded);
        return;
    };
    // The key field runs to the first `;`, or to the final `u` when the
    // sequence has no modifier field.
    let key_field_len =
        rest.iter().position(|byte| *byte == b';').unwrap_or(rest.len().saturating_sub(1));
    let Some((key_field, tail)) = rest.split_at_checked(key_field_len) else {
        out.extend_from_slice(encoded);
        return;
    };
    let colon_count = key_field.iter().filter(|byte| **byte == b':').count();
    if !(1..=2).contains(&colon_count)
        || !key_field.iter().all(|byte| byte.is_ascii_digit() || *byte == b':')
    {
        out.extend_from_slice(encoded);
        return;
    }

    // `key:shifted` or `key:shifted:base`; colon_count >= 1 above.
    let mut slots = key_field.splitn(3, |byte| *byte == b':');
    let (Some(key_code), Some(reported_shifted)) = (slots.next(), slots.next()) else {
        out.extend_from_slice(encoded);
        return;
    };
    let reported_base = slots.next();
    let mut shifted_decimal = [0u8; 10];
    let shifted_digits = (reported_shifted.is_empty() && input.shifted_codepoint != 0)
        .then(|| decimal_u32(input.shifted_codepoint, &mut shifted_decimal));
    let mut base_decimal = [0u8; 10];
    let base_digits = (reported_base.is_none() && input.base_layout_codepoint != 0)
        .then(|| decimal_u32(input.base_layout_codepoint, &mut base_decimal));
    out.reserve(
        encoded.len()
            + shifted_digits.map_or(0, <[u8]>::len)
            + base_digits.map_or(0, |digits| 1 + digits.len()),
    );
    out.extend_from_slice(b"\x1b[");
    out.extend_from_slice(key_code);
    out.push(b':');
    out.extend_from_slice(shifted_digits.unwrap_or(reported_shifted));
    if let Some(base) = reported_base.or(base_digits) {
        out.push(b':');
        out.extend_from_slice(base);
    }
    out.extend_from_slice(tail);
}

/// Decimal digits of `value` without leading zeros (u32::MAX has 10 digits).
fn decimal_u32(value: u32, buffer: &mut [u8; 10]) -> &[u8] {
    let mut rest = value;
    for slot in buffer.iter_mut().rev() {
        *slot = b'0' + (rest % 10) as u8;
        rest /= 10;
    }
    let mut digits: &[u8] = buffer;
    while let [b'0', tail @ ..] = digits
        && !tail.is_empty()
    {
        digits = tail;
    }
    digits
}

impl Drop for KeyEncoder {
    fn drop(&mut self) {
        // SAFETY: Drop runs once; both handles came from their _new calls in `new`
        // and are owned only by this value.
        unsafe {
            sys::ghostty_key_event_free(self.event);
            sys::ghostty_key_encoder_free(self.encoder);
        }
    }
}
