//! Fuzz driver for host key decoding (`crate::fuzzing`).
//!
//! Key events come from host bytes through crossterm's parser (fed one byte
//! at a time, as its event reader does) or are built field by field, which
//! reaches layouts, texts and modifier sets no terminal sends. Each event goes
//! through `KeyboardInput` and the ghostty key encoder in a fuzz-chosen
//! keyboard mode, as App routes a key.

use crossterm::event::{MediaKeyCode, ModifierKeyCode};
use ghostty_vt::{Callbacks, KeyEncoder, Terminal};

use super::*;
use crate::fuzzing::FuzzBytes;

/// crossterm's `parse_event_from_bytes` reads a complete internal event
/// (a cursor report) as `None`, like an incomplete one; past this many
/// bytes the driver drops the pending buffer, as the reader drops an error.
#[cfg(unix)]
const MAX_PENDING_BYTES: usize = 256;

const KINDS: [KeyEventKind; 3] = [KeyEventKind::Press, KeyEventKind::Repeat, KeyEventKind::Release];

pub(crate) fn one_input(data: &[u8]) {
    let mut input = FuzzBytes::new(data);
    let (Some(mode), Some(source)) = (input.byte(), input.byte()) else {
        return;
    };
    let Ok(mut terminal) = Terminal::new(80, 24, 0, Callbacks::default()) else {
        return;
    };
    // The keyboard modes the encoder reads from the terminal: Kitty flags,
    // cursor-key and keypad application modes, modifyOtherKeys.
    terminal.vt_write(format!("\x1b[>{}u", mode & 0x1f).as_bytes());
    if mode & 0x20 != 0 {
        terminal.vt_write(b"\x1b[?1h");
    }
    if mode & 0x40 != 0 {
        terminal.vt_write(b"\x1b=");
    }
    if mode & 0x80 != 0 {
        terminal.vt_write(b"\x1b[>4;2m");
    }
    let Ok(mut encoder) = KeyEncoder::new() else {
        return;
    };
    encoder.sync_from_terminal(&terminal);
    let option_as_alt = source & 0b10 != 0;
    let mut route = |keyboard: KeyboardInput| route_key(keyboard, option_as_alt, &mut encoder);
    if source & 1 == 0 {
        #[cfg(unix)]
        parsed_events(input.rest(), &mut route);
    } else {
        built_events(&mut input, &mut route);
    }
}

#[cfg(unix)]
fn parsed_events(bytes: &[u8], route: &mut impl FnMut(KeyboardInput)) {
    let mut pending = Vec::new();
    for (index, byte) in bytes.iter().enumerate() {
        pending.push(*byte);
        let more = index + 1 < bytes.len();
        match crossterm::event::parse_event_from_bytes(&pending, more) {
            Ok(Some(event)) => {
                pending.clear();
                match event {
                    crossterm::event::Event::Key(key) => route(KeyboardInput::from(key)),
                    crossterm::event::Event::EnhancedKey(key) => {
                        route(KeyboardInput::from_enhanced(key));
                    }
                    _ => {}
                }
            }
            Ok(None) if pending.len() < MAX_PENDING_BYTES => {}
            Ok(None) | Err(_) => pending.clear(),
        }
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
