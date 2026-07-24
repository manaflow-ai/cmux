//! crossterm key events → ghostty key encoder inputs.

use crossterm::event::{
    EnhancedKeyEvent, KeyCode, KeyEvent, KeyEventKind, KeyEventState, KeyModifiers,
};
use ghostty_vt::sys;
use ghostty_vt::{KeyAction, KeyInput, Mods};

/// Modifiers that keep generated text structured so overlays, browser
/// surfaces, and cmux bindings can process the original shortcut.
pub const SHORTCUT_MODIFIERS: KeyModifiers = KeyModifiers::CONTROL
    .union(KeyModifiers::ALT)
    .union(KeyModifiers::SUPER)
    .union(KeyModifiers::HYPER)
    .union(KeyModifiers::META);

/// A host key event normalized once before cmux routes it through overlays,
/// shortcuts, browser input, or a PTY.
#[derive(Debug, Clone)]
pub struct KeyboardInput {
    key_event: KeyEvent,
    shifted_key: Option<char>,
    base_layout_key: Option<char>,
    associated_text: String,
    consumed_alt: bool,
    enhanced: bool,
}

impl From<KeyEvent> for KeyboardInput {
    fn from(key_event: KeyEvent) -> Self {
        Self {
            key_event,
            shifted_key: None,
            base_layout_key: None,
            associated_text: String::new(),
            consumed_alt: false,
            enhanced: false,
        }
    }
}

impl From<EnhancedKeyEvent> for KeyboardInput {
    fn from(event: EnhancedKeyEvent) -> Self {
        let consumed_alt =
            option_generated_text(&event.key_event, event.shifted_key, event.text.as_str());
        Self {
            key_event: event.key_event,
            shifted_key: event.shifted_key,
            base_layout_key: event.base_layout_key,
            associated_text: event.text,
            consumed_alt,
            enhanced: true,
        }
    }
}

impl KeyboardInput {
    pub fn ui_key(&self) -> KeyEvent {
        let mut key = self.key_event;
        if key.modifiers.contains(KeyModifiers::SHIFT)
            && let Some(shifted_key) = self.shifted_key
        {
            key.code = KeyCode::Char(shifted_key);
        }
        key
    }

    /// Complete generated text that is safe to insert atomically. Shift is
    /// already reflected in the text, and a consumed macOS Option modifier is
    /// no longer an active Alt shortcut.
    pub fn text_for_direct_input(&self) -> Option<&str> {
        let mut modifiers = self.key_event.modifiers & SHORTCUT_MODIFIERS;
        if self.consumed_alt {
            modifiers.remove(KeyModifiers::ALT);
        }
        (modifiers.is_empty() && !self.associated_text.is_empty())
            .then_some(self.associated_text.as_str())
    }

    pub fn base_layout_key(&self) -> Option<char> {
        self.base_layout_key
    }

    pub fn associated_text_bytes(&self) -> usize {
        self.associated_text.len()
    }

    pub fn has_consumed_alt(&self) -> bool {
        self.consumed_alt
    }

    /// Active-layout logical identity first, then the PC-101 physical
    /// fallback. A reported shifted identity has already consumed Shift.
    pub fn shortcut_keys(&self) -> (KeyEvent, Option<KeyEvent>) {
        let mut logical = self.key_event;
        if self.enhanced
            && logical.modifiers.contains(KeyModifiers::SHIFT)
            && let Some(shifted_key) = self.shifted_key
        {
            logical.code = KeyCode::Char(shifted_key);
            logical.modifiers.remove(KeyModifiers::SHIFT);
        }
        if self.consumed_alt {
            logical.modifiers.remove(KeyModifiers::ALT);
        }

        let fallback = self.base_layout_key.and_then(|base_layout_key| {
            let mut base = self.key_event;
            base.code = KeyCode::Char(base_layout_key);
            if self.consumed_alt {
                base.modifiers.remove(KeyModifiers::ALT);
            }
            (base != logical).then_some(base)
        });
        (logical, fallback)
    }

    pub fn terminal_input(&self) -> Option<KeyInput> {
        if self.enhanced {
            key_input_from_parts(
                &self.key_event,
                self.shifted_key,
                self.base_layout_key,
                &self.associated_text,
                self.consumed_alt,
            )
        } else {
            key_input_from(&self.key_event)
        }
    }
}

fn mods_from(m: KeyModifiers) -> Option<Mods> {
    if m.intersects(KeyModifiers::HYPER | KeyModifiers::META) {
        return None;
    }
    let mut mods = Mods::default();
    if m.contains(KeyModifiers::SHIFT) {
        mods = mods | Mods::SHIFT;
    }
    if m.contains(KeyModifiers::CONTROL) {
        mods = mods | Mods::CTRL;
    }
    if m.contains(KeyModifiers::ALT) {
        mods = mods | Mods::ALT;
    }
    if m.contains(KeyModifiers::SUPER) {
        mods = mods | Mods::SUPER;
    }
    Some(mods)
}

fn state_mods(state: KeyEventState) -> Mods {
    let mut mods = Mods::default();
    if state.contains(KeyEventState::CAPS_LOCK) {
        mods = mods | Mods::CAPS_LOCK;
    }
    if state.contains(KeyEventState::NUM_LOCK) {
        mods = mods | Mods::NUM_LOCK;
    }
    mods
}

pub(crate) fn shifted_ascii_char(c: char) -> char {
    match c {
        'a'..='z' => c.to_ascii_uppercase(),
        '`' => '~',
        '1' => '!',
        '2' => '@',
        '3' => '#',
        '4' => '$',
        '5' => '%',
        '6' => '^',
        '7' => '&',
        '8' => '*',
        '9' => '(',
        '0' => ')',
        '-' => '_',
        '=' => '+',
        '[' => '{',
        ']' => '}',
        '\\' => '|',
        ';' => ':',
        '\'' => '"',
        ',' => '<',
        '.' => '>',
        '/' => '?',
        _ => c,
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

fn keypad_physical_key(code: KeyCode) -> Option<sys::GhosttyKey> {
    Some(match code {
        KeyCode::Char('0') => sys::GHOSTTY_KEY_NUMPAD_0,
        KeyCode::Char('1') => sys::GHOSTTY_KEY_NUMPAD_1,
        KeyCode::Char('2') => sys::GHOSTTY_KEY_NUMPAD_2,
        KeyCode::Char('3') => sys::GHOSTTY_KEY_NUMPAD_3,
        KeyCode::Char('4') => sys::GHOSTTY_KEY_NUMPAD_4,
        KeyCode::Char('5') => sys::GHOSTTY_KEY_NUMPAD_5,
        KeyCode::Char('6') => sys::GHOSTTY_KEY_NUMPAD_6,
        KeyCode::Char('7') => sys::GHOSTTY_KEY_NUMPAD_7,
        KeyCode::Char('8') => sys::GHOSTTY_KEY_NUMPAD_8,
        KeyCode::Char('9') => sys::GHOSTTY_KEY_NUMPAD_9,
        KeyCode::Char('+') => sys::GHOSTTY_KEY_NUMPAD_ADD,
        KeyCode::Backspace => sys::GHOSTTY_KEY_NUMPAD_BACKSPACE,
        KeyCode::Char(',') => sys::GHOSTTY_KEY_NUMPAD_COMMA,
        KeyCode::Char('.') => sys::GHOSTTY_KEY_NUMPAD_DECIMAL,
        KeyCode::Char('/') => sys::GHOSTTY_KEY_NUMPAD_DIVIDE,
        KeyCode::Enter => sys::GHOSTTY_KEY_NUMPAD_ENTER,
        KeyCode::Char('=') => sys::GHOSTTY_KEY_NUMPAD_EQUAL,
        KeyCode::Char('*') => sys::GHOSTTY_KEY_NUMPAD_MULTIPLY,
        KeyCode::Char('-') => sys::GHOSTTY_KEY_NUMPAD_SUBTRACT,
        KeyCode::Up => sys::GHOSTTY_KEY_NUMPAD_UP,
        KeyCode::Down => sys::GHOSTTY_KEY_NUMPAD_DOWN,
        KeyCode::Right => sys::GHOSTTY_KEY_NUMPAD_RIGHT,
        KeyCode::Left => sys::GHOSTTY_KEY_NUMPAD_LEFT,
        KeyCode::KeypadBegin => sys::GHOSTTY_KEY_NUMPAD_BEGIN,
        KeyCode::Home => sys::GHOSTTY_KEY_NUMPAD_HOME,
        KeyCode::End => sys::GHOSTTY_KEY_NUMPAD_END,
        KeyCode::Insert => sys::GHOSTTY_KEY_NUMPAD_INSERT,
        KeyCode::Delete => sys::GHOSTTY_KEY_NUMPAD_DELETE,
        KeyCode::PageUp => sys::GHOSTTY_KEY_NUMPAD_PAGE_UP,
        KeyCode::PageDown => sys::GHOSTTY_KEY_NUMPAD_PAGE_DOWN,
        _ => return None,
    })
}

/// Convert a crossterm key event into an encoder input. Returns `None`
/// for events that produce no terminal bytes (releases, media keys, ...).
pub fn key_input_from(event: &KeyEvent) -> Option<KeyInput> {
    let action = match event.kind {
        KeyEventKind::Press => KeyAction::Press,
        KeyEventKind::Repeat => KeyAction::Repeat,
        // Terminals only forward releases under kitty's report-events
        // flag; passing them through would need release encoding support
        // end to end. Skip for now.
        KeyEventKind::Release => return None,
    };
    let mods = mods_from(event.modifiers)? | state_mods(event.state);

    let mut input = KeyInput { mods, action: Some(action), ..Default::default() };

    match event.code {
        KeyCode::Char(c) => {
            let unshifted = if c.is_ascii_uppercase() { c.to_ascii_lowercase() } else { c };
            input.key = physical_key_for_char(c);
            input.unshifted_codepoint = unshifted as u32;
            // The encoder derives Ctrl-modified bytes from key+mods; text
            // is only the layout-produced character.
            if !mods.contains(Mods::CTRL) {
                input.utf8 = c.to_string();
                if mods.contains(Mods::SHIFT) {
                    input.consumed_mods = Mods::SHIFT;
                }
            }
        }
        KeyCode::Enter => input.key = sys::GHOSTTY_KEY_ENTER,
        KeyCode::Tab => input.key = sys::GHOSTTY_KEY_TAB,
        KeyCode::BackTab => {
            input.key = sys::GHOSTTY_KEY_TAB;
            input.mods = input.mods | Mods::SHIFT;
        }
        KeyCode::Backspace => input.key = sys::GHOSTTY_KEY_BACKSPACE,
        KeyCode::Esc => input.key = sys::GHOSTTY_KEY_ESCAPE,
        KeyCode::Left => input.key = sys::GHOSTTY_KEY_ARROW_LEFT,
        KeyCode::Right => input.key = sys::GHOSTTY_KEY_ARROW_RIGHT,
        KeyCode::Up => input.key = sys::GHOSTTY_KEY_ARROW_UP,
        KeyCode::Down => input.key = sys::GHOSTTY_KEY_ARROW_DOWN,
        KeyCode::Home => input.key = sys::GHOSTTY_KEY_HOME,
        KeyCode::End => input.key = sys::GHOSTTY_KEY_END,
        KeyCode::PageUp => input.key = sys::GHOSTTY_KEY_PAGE_UP,
        KeyCode::PageDown => input.key = sys::GHOSTTY_KEY_PAGE_DOWN,
        KeyCode::Insert => input.key = sys::GHOSTTY_KEY_INSERT,
        KeyCode::Delete => input.key = sys::GHOSTTY_KEY_DELETE,
        KeyCode::F(n @ 1..=20) => {
            input.key = sys::GHOSTTY_KEY_F1 + (n as sys::GhosttyKey - 1);
        }
        KeyCode::KeypadBegin => input.key = sys::GHOSTTY_KEY_NUMPAD_BEGIN,
        _ => return None,
    }
    if event.state.contains(KeyEventState::KEYPAD)
        && let Some(key) = keypad_physical_key(event.code)
    {
        input.key = key;
    }
    Some(input)
}

/// Convert a lossless Kitty CSI-u event into an encoder input without
/// guessing the keyboard layout from US punctuation pairs.
#[cfg(test)]
pub fn key_input_from_enhanced(event: &EnhancedKeyEvent) -> Option<KeyInput> {
    key_input_from_parts(
        &event.key_event,
        event.shifted_key,
        event.base_layout_key,
        &event.text,
        option_generated_text(&event.key_event, event.shifted_key, &event.text),
    )
}

fn key_input_from_parts(
    event: &KeyEvent,
    shifted_key: Option<char>,
    base_layout_key: Option<char>,
    associated_text: &str,
    consumed_alt: bool,
) -> Option<KeyInput> {
    let mut input = key_input_from(event)?;

    if let KeyCode::Char(unshifted) = event.code {
        if !event.state.contains(KeyEventState::KEYPAD)
            && let Some(base_layout_key) = base_layout_key
        {
            input.key = physical_key_for_char(base_layout_key);
        }
        input.unshifted_codepoint = unshifted as u32;
    }

    if !associated_text.is_empty() {
        input.utf8 = associated_text.to_string();
        if input.mods.contains(Mods::SHIFT) {
            input.consumed_mods = input.consumed_mods | Mods::SHIFT;
        }
        if consumed_alt {
            input.consumed_mods = input.consumed_mods | Mods::ALT;
            input.macos_option_as_alt = false;
        }
    } else if let KeyCode::Char(unshifted) = event.code {
        let produced = shifted_key
            .filter(|_| input.mods.contains(Mods::SHIFT))
            .or_else(|| (!input.mods.contains(Mods::CTRL)).then_some(unshifted));
        if let Some(produced) = produced {
            input.utf8 = produced.to_string();
            if input.mods.contains(Mods::SHIFT) {
                input.consumed_mods = input.consumed_mods | Mods::SHIFT;
            }
        }
    }
    Some(input)
}

fn option_generated_text(
    event: &KeyEvent,
    shifted_key: Option<char>,
    associated_text: &str,
) -> bool {
    // Kitty reports pressed modifiers and generated text, but no consumed-modifier
    // mask. Preserve Alt when the text matches the reported layout identity,
    // since real Alt/meta chords may include that associated text.
    if associated_text.is_empty() || !event.modifiers.contains(KeyModifiers::ALT) {
        return false;
    }
    let KeyCode::Char(unshifted) = event.code else {
        return false;
    };
    let expected = if event.modifiers.contains(KeyModifiers::SHIFT) {
        let Some(shifted) = shifted_key else {
            return false;
        };
        shifted
    } else {
        unshifted
    };
    let mut produced = associated_text.chars();
    produced.next() != Some(expected) || produced.next().is_some()
}

#[cfg(test)]
mod tests {
    use super::*;
    use ghostty_vt::{Callbacks, KeyEncoder, Terminal};

    #[test]
    fn ctrl_shift_letter_keeps_shift_in_kitty_forwarding() {
        let event = KeyEvent::new(KeyCode::Char('c'), KeyModifiers::CONTROL | KeyModifiers::SHIFT);
        let input = key_input_from(&event).unwrap();
        assert!(input.mods.contains(Mods::CTRL));
        assert!(input.mods.contains(Mods::SHIFT));

        let mut terminal = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
        terminal.vt_write(b"\x1b[>1u");
        let mut encoder = KeyEncoder::new().unwrap();
        encoder.sync_from_terminal(&terminal);
        let mut encoded = Vec::new();
        encoder.encode(&input, &mut encoded).unwrap();

        assert_eq!(encoded, b"\x1b[99;6u");
    }

    #[test]
    fn enhanced_ctrl_shift_keeps_reported_layout_identity_in_kitty_forwarding() {
        let event = EnhancedKeyEvent {
            key_event: KeyEvent::new(
                KeyCode::Char('\u{447}'),
                KeyModifiers::CONTROL | KeyModifiers::SHIFT,
            ),
            shifted_key: Some('\u{427}'),
            base_layout_key: Some(';'),
            text: String::new(),
        };
        let input = key_input_from_enhanced(&event).unwrap();
        let mut terminal = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
        terminal.vt_write(b"\x1b[>29u");
        let mut encoder = KeyEncoder::new().unwrap();
        encoder.sync_from_terminal(&terminal);
        let mut encoded = Vec::new();

        encoder.encode(&input, &mut encoded).unwrap();

        assert_eq!(encoded, b"\x1b[1095:1063:59;6u");
    }

    #[test]
    fn alt_shift_base_keys_preserve_shifted_text_for_legacy_terminals() {
        let encode = |code, shifted| {
            let event = EnhancedKeyEvent {
                key_event: KeyEvent::new(
                    KeyCode::Char(code),
                    KeyModifiers::ALT | KeyModifiers::SHIFT,
                ),
                shifted_key: Some(shifted),
                base_layout_key: Some(code),
                text: String::new(),
            };
            let input = key_input_from_enhanced(&event).unwrap();
            let mut terminal = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
            terminal.vt_write(b"\x1b[?1036h");
            let mut encoder = KeyEncoder::new().unwrap();
            encoder.sync_from_terminal(&terminal);
            let mut encoded = Vec::new();
            encoder.encode(&input, &mut encoded).unwrap();
            encoded
        };

        for (base, shifted) in [('d', 'D'), ('1', '!')] {
            assert_eq!(
                encode(base, shifted),
                [b"\x1b".as_slice(), shifted.to_string().as_bytes()].concat()
            );
        }
    }

    #[test]
    fn enhanced_key_uses_reported_layout_text_and_physical_identity() {
        let event = EnhancedKeyEvent {
            key_event: KeyEvent::new(KeyCode::Char('&'), KeyModifiers::ALT | KeyModifiers::SHIFT),
            shifted_key: Some('1'),
            base_layout_key: Some('1'),
            text: "1".to_string(),
        };
        let input = key_input_from_enhanced(&event).unwrap();

        assert_eq!(input.key, sys::GHOSTTY_KEY_DIGIT_1);
        assert_eq!(input.unshifted_codepoint, '&' as u32);
        assert_eq!(input.utf8, "1");
        assert!(input.mods.contains(Mods::ALT | Mods::SHIFT));
        assert!(input.consumed_mods.contains(Mods::SHIFT));
    }

    #[test]
    fn shifted_punctuation_does_not_invent_a_us_layout_identity() {
        let event = KeyEvent::new(KeyCode::Char('&'), KeyModifiers::ALT | KeyModifiers::SHIFT);
        let input = key_input_from(&event).unwrap();

        assert_eq!(input.key, sys::GHOSTTY_KEY_UNIDENTIFIED);
        assert_eq!(input.unshifted_codepoint, '&' as u32);
        assert_eq!(input.utf8, "&");
    }

    #[test]
    fn enhanced_function_key_preserves_associated_text() {
        let event = EnhancedKeyEvent {
            key_event: KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE),
            shifted_key: None,
            base_layout_key: None,
            text: "\u{6f22}".to_string(),
        };

        let input = key_input_from_enhanced(&event).unwrap();

        assert_eq!(input.key, sys::GHOSTTY_KEY_ENTER);
        assert_eq!(input.utf8, "\u{6f22}");
    }

    #[test]
    fn unsupported_kitty_modifiers_fail_closed_for_terminal_input() {
        for modifier in [KeyModifiers::HYPER, KeyModifiers::META] {
            let event = EnhancedKeyEvent {
                key_event: KeyEvent::new(KeyCode::Char('x'), modifier),
                shifted_key: None,
                base_layout_key: Some('x'),
                text: "x".to_string(),
            };

            assert!(
                key_input_from_enhanced(&event).is_none(),
                "{modifier:?} must not be downgraded to an unmodified key"
            );
        }
    }

    #[test]
    fn option_generated_text_keeps_associated_text_in_kitty_mode() {
        let event = EnhancedKeyEvent {
            key_event: KeyEvent::new(KeyCode::Char('w'), KeyModifiers::ALT),
            shifted_key: None,
            base_layout_key: Some('w'),
            text: "\u{2211}".to_string(),
        };
        let input = key_input_from_enhanced(&event).unwrap();
        let mut terminal = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
        terminal.vt_write(b"\x1b[>29u");
        let mut encoder = KeyEncoder::new().unwrap();
        encoder.sync_from_terminal(&terminal);
        let mut encoded = Vec::new();

        encoder.encode(&input, &mut encoded).unwrap();

        assert_eq!(encoded, b"\x1b[119;3;8721u");
    }

    #[test]
    fn enhanced_keypad_identity_and_lock_state_reach_the_ghostty_encoder() {
        let state = KeyEventState::KEYPAD | KeyEventState::CAPS_LOCK | KeyEventState::NUM_LOCK;
        let event = EnhancedKeyEvent {
            key_event: KeyEvent::new_with_kind_and_state(
                KeyCode::Char('1'),
                KeyModifiers::NONE,
                KeyEventKind::Press,
                state,
            ),
            shifted_key: None,
            base_layout_key: None,
            text: String::new(),
        };

        let input = key_input_from_enhanced(&event).unwrap();

        assert_eq!(input.key, sys::GHOSTTY_KEY_NUMPAD_1);
        assert_ne!(input.mods.0 & sys::GHOSTTY_MODS_CAPS_LOCK as u16, 0);
        assert_ne!(input.mods.0 & sys::GHOSTTY_MODS_NUM_LOCK as u16, 0);
    }

    #[test]
    fn enhanced_keypad_navigation_keeps_its_physical_identity() {
        let state = KeyEventState::KEYPAD;
        for (code, expected) in [
            (KeyCode::Enter, sys::GHOSTTY_KEY_NUMPAD_ENTER),
            (KeyCode::Up, sys::GHOSTTY_KEY_NUMPAD_UP),
            (KeyCode::PageDown, sys::GHOSTTY_KEY_NUMPAD_PAGE_DOWN),
            (KeyCode::KeypadBegin, sys::GHOSTTY_KEY_NUMPAD_BEGIN),
        ] {
            let event = EnhancedKeyEvent {
                key_event: KeyEvent::new_with_kind_and_state(
                    code,
                    KeyModifiers::NONE,
                    KeyEventKind::Press,
                    state,
                ),
                shifted_key: None,
                base_layout_key: None,
                text: String::new(),
            };

            assert_eq!(key_input_from_enhanced(&event).unwrap().key, expected);
        }
    }

    #[test]
    fn shifted_option_generated_text_is_forwarded_as_text() {
        let event = EnhancedKeyEvent {
            key_event: KeyEvent::new(KeyCode::Char('2'), KeyModifiers::ALT | KeyModifiers::SHIFT),
            shifted_key: Some('@'),
            base_layout_key: Some('2'),
            text: "\u{20ac}".to_string(),
        };
        let input = key_input_from_enhanced(&event).unwrap();
        let terminal = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
        let mut encoder = KeyEncoder::new().unwrap();
        encoder.sync_from_terminal(&terminal);
        let mut encoded = Vec::new();

        encoder.encode(&input, &mut encoded).unwrap();

        assert!(input.consumed_mods.contains(Mods::ALT));
        assert_eq!(encoded, "\u{20ac}".as_bytes());
    }
}
