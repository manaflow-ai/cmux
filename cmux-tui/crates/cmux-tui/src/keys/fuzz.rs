//! Fuzz driver for host key decoding (`crate::fuzzing`).
//!
//! Key events come from host bytes through crossterm's parser (fed one byte
//! at a time, as its event reader does) or are built field by field, which
//! reaches layouts, texts and modifier sets no terminal sends. Each event goes
//! through `KeyboardInput` and the ghostty key encoder in a fuzz-chosen
//! keyboard mode, as App routes a key.
//!
//! One terminal and one encoder serve the whole process, as a surface's do in
//! App; each input sets every keyboard mode the encoder reads. Chrome's
//! fuzzers likewise build their environment once per process
//! (testing/libfuzzer/getting_started.md).

use std::cell::RefCell;

use crossterm::event::{MediaKeyCode, ModifierKeyCode};
use ghostty_vt::{Callbacks, KeyEncoder, Terminal};

use super::*;
use crate::fuzzing::FuzzBytes;

const KINDS: [KeyEventKind; 3] = [KeyEventKind::Press, KeyEventKind::Repeat, KeyEventKind::Release];

struct Encoding {
    terminal: Terminal,
    encoder: KeyEncoder,
}

impl Encoding {
    fn new() -> Option<Self> {
        let terminal = Terminal::new(80, 24, 0, Callbacks::default()).ok()?;
        let encoder = KeyEncoder::new().ok()?;
        Some(Self { terminal, encoder })
    }

    /// Sets every keyboard mode the encoder reads from the terminal (Kitty
    /// flags, cursor-key and keypad application modes, modifyOtherKeys) from
    /// `mode`, whatever the previous input left, and syncs the encoder.
    fn set_mode(&mut self, mode: u8) {
        let kitty = format!("\x1b[={};1u", mode & 0x1f);
        self.terminal.vt_write(kitty.as_bytes());
        self.terminal.vt_write(if mode & 0x20 != 0 { b"\x1b[?1h" } else { b"\x1b[?1l" });
        self.terminal.vt_write(if mode & 0x40 != 0 { b"\x1b=" } else { b"\x1b>" });
        self.terminal.vt_write(if mode & 0x80 != 0 { &b"\x1b[>4;2m"[..] } else { b"\x1b[>m" });
        self.encoder.sync_from_terminal(&self.terminal);
    }
}

thread_local! {
    static ENCODING: RefCell<Option<Encoding>> = RefCell::new(Encoding::new());
}

pub(crate) fn one_input(data: &[u8]) {
    let mut input = FuzzBytes::new(data);
    let (Some(mode), Some(source)) = (input.byte(), input.byte()) else {
        return;
    };
    ENCODING.with_borrow_mut(|encoding| {
        let Some(encoding) = encoding else {
            return;
        };
        encoding.set_mode(mode);
        let option_as_alt = source & 0b10 != 0;
        let encoder = &mut encoding.encoder;
        let mut route = |keyboard: KeyboardInput| route_key(keyboard, option_as_alt, encoder);
        if source & 1 == 0 {
            #[cfg(unix)]
            parsed_events(input.rest(), &mut route);
        } else {
            built_events(&mut input, &mut route);
        }
    });
}

/// The event reader's loop (crossterm's unix `Parser::advance`): an
/// incomplete sequence keeps its bytes; an event, a terminal reply or an
/// error ends it.
#[cfg(unix)]
fn parsed_events(bytes: &[u8], route: &mut impl FnMut(KeyboardInput)) {
    use crossterm::event::{Event, ParsedInput, parse_input_from_bytes};

    let mut pending = Vec::new();
    for (index, byte) in bytes.iter().enumerate() {
        pending.push(*byte);
        let more = index + 1 < bytes.len();
        match parse_input_from_bytes(&pending, more) {
            Ok(None) => continue,
            Ok(Some(ParsedInput::Event(Event::Key(key)))) => route(KeyboardInput::from(key)),
            Ok(Some(ParsedInput::Event(Event::EnhancedKey(key)))) => {
                route(KeyboardInput::from_enhanced(key));
            }
            Ok(Some(_)) | Err(_) => {}
        }
        pending.clear();
    }
}

fn built_events(input: &mut FuzzBytes<'_>, route: &mut impl FnMut(KeyboardInput)) -> Option<()> {
    loop {
        let selector = input.byte()?;
        let code = key_code(selector, input)?;
        let modifiers = KeyModifiers::from_bits_truncate(input.byte()?);
        let kind = input.pick(&KINDS)?;
        let state = KeyEventState::from_bits_truncate(input.byte()?);
        let key_event = KeyEvent::new_with_kind_and_state(code, modifiers, kind, state);
        if selector & 0x80 == 0 {
            route(KeyboardInput::from(key_event));
            continue;
        }
        let present = input.byte()?;
        let shifted_key = if present & 1 != 0 { Some(character(input)?) } else { None };
        let base_layout_key = if present & 2 != 0 { Some(character(input)?) } else { None };
        let mut text = String::new();
        for _ in 0..(present >> 2) % 4 {
            text.push(character(input)?);
        }
        route(KeyboardInput::from_enhanced(EnhancedKeyEvent {
            key_event,
            shifted_key,
            base_layout_key,
            text,
        }));
    }
}

/// Mostly ASCII, sometimes any scalar value.
fn character(input: &mut FuzzBytes<'_>) -> Option<char> {
    let byte = input.byte()?;
    if byte < 0xc0 {
        return Some(char::from(byte & 0x7f));
    }
    let value = u32::from_le_bytes([input.byte()?, input.byte()?, input.byte()? % 0x11, 0]);
    Some(char::from_u32(value).unwrap_or(char::REPLACEMENT_CHARACTER))
}

fn key_code(selector: u8, input: &mut FuzzBytes<'_>) -> Option<KeyCode> {
    Some(match selector % 32 {
        0..=11 => KeyCode::Char(character(input)?),
        12 => KeyCode::Backspace,
        13 => KeyCode::Enter,
        14 => KeyCode::Left,
        15 => KeyCode::Right,
        16 => KeyCode::Up,
        17 => KeyCode::Down,
        18 => KeyCode::Home,
        19 => KeyCode::End,
        20 => KeyCode::PageUp,
        21 => KeyCode::PageDown,
        22 => KeyCode::Tab,
        23 => KeyCode::BackTab,
        24 => KeyCode::Delete,
        25 => KeyCode::Insert,
        26 => KeyCode::F(input.byte()?),
        27 => KeyCode::Esc,
        28 => KeyCode::KeypadBegin,
        29 => KeyCode::Null,
        30 => KeyCode::Modifier(ModifierKeyCode::LeftShift),
        _ => KeyCode::Media(MediaKeyCode::Play),
    })
}

/// What App does with one key: shortcut identities, direct text, then the
/// terminal encoding. Checks the contracts the router relies on.
fn route_key(mut keyboard: KeyboardInput, option_as_alt: bool, encoder: &mut KeyEncoder) {
    keyboard.resolve_macos_option_as_alt(option_as_alt);
    let _ = keyboard.ui_key();
    let _ = (keyboard.is_modifier_only(), keyboard.is_composing(), keyboard.base_layout_key());
    let (logical, fallback) = keyboard.shortcut_keys();
    assert!(fallback != Some(logical), "the physical fallback repeats the logical key");
    if keyboard.suppresses_alt_shortcut() {
        assert!(
            !logical.modifiers.contains(KeyModifiers::ALT),
            "a consumed Option still reads as an Alt shortcut"
        );
    }
    if let Some(text) = keyboard.text_for_direct_input() {
        assert!(!text.is_empty(), "direct input offered empty text");
        assert_eq!(text.len(), keyboard.associated_text_bytes());
        let mut taken = keyboard.clone();
        assert_eq!(taken.take_text_for_direct_input().as_deref(), Some(text));
        assert_eq!(taken.associated_text_bytes(), 0, "taken text stayed on the event");
    }
    let release = keyboard.is_release();
    if let Some(key_input) = keyboard.into_terminal_input() {
        assert!(!release, "a key release produced terminal input");
        let mut encoded = Vec::new();
        let _ = encoder.encode(&key_input, &mut encoded);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn encodings(encoder: &mut KeyEncoder) -> Vec<Vec<u8>> {
        let keys = [
            KeyEvent::new(KeyCode::Char('a'), KeyModifiers::CONTROL),
            KeyEvent::new(KeyCode::Char('i'), KeyModifiers::CONTROL | KeyModifiers::SHIFT),
            KeyEvent::new(KeyCode::Up, KeyModifiers::NONE),
            KeyEvent::new(KeyCode::Enter, KeyModifiers::ALT),
            KeyEvent::new(KeyCode::Esc, KeyModifiers::NONE),
            KeyEvent::new(KeyCode::Home, KeyModifiers::NONE),
        ];
        keys.iter()
            .map(|key| {
                let mut out = Vec::new();
                let input = KeyboardInput::from(*key).into_terminal_input().expect("a press");
                encoder.encode(&input, &mut out).expect("encodes");
                out
            })
            .collect()
    }

    /// The shared terminal encodes every mode as a terminal that only ever
    /// had that mode, whatever mode the input before it left.
    #[test]
    fn a_reused_encoding_matches_a_fresh_terminal_in_every_mode() {
        let mut shared = Encoding::new().expect("terminal and encoder");
        for mode in 0..=u8::MAX {
            let mut fresh = Encoding::new().expect("terminal and encoder");
            fresh.terminal.vt_write(format!("\x1b[>{}u", mode & 0x1f).as_bytes());
            if mode & 0x20 != 0 {
                fresh.terminal.vt_write(b"\x1b[?1h");
            }
            if mode & 0x40 != 0 {
                fresh.terminal.vt_write(b"\x1b=");
            }
            if mode & 0x80 != 0 {
                fresh.terminal.vt_write(b"\x1b[>4;2m");
            }
            fresh.encoder.sync_from_terminal(&fresh.terminal);
            shared.set_mode(!mode);
            shared.set_mode(mode);
            assert_eq!(
                encodings(&mut shared.encoder),
                encodings(&mut fresh.encoder),
                "mode {mode:#x}"
            );
        }
    }

    /// A terminal reply ends its sequence, as in the event reader: the key
    /// after a cursor position report is decoded on its own.
    #[cfg(unix)]
    #[test]
    fn a_key_after_a_terminal_reply_is_decoded() {
        let mut keys = Vec::new();
        parsed_events(b"\x1b[5;5Ra\x1b[?1ub", &mut |keyboard: KeyboardInput| {
            keys.push(keyboard.ui_key().code);
        });
        assert_eq!(keys, [KeyCode::Char('a'), KeyCode::Char('b')]);
    }
}
