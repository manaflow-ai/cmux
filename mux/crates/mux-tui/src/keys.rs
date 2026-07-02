//! crossterm key events → ghostty key encoder inputs.

use crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use ghostty_vt::sys;
use ghostty_vt::{KeyAction, KeyInput, Mods};

pub fn mods_from(m: KeyModifiers) -> Mods {
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
    mods
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
    let mods = mods_from(event.modifiers);

    let mut input = KeyInput {
        mods,
        action: Some(action),
        ..Default::default()
    };

    match event.code {
        KeyCode::Char(c) => {
            input.key = physical_key_for_char(c);
            input.unshifted_codepoint = c.to_ascii_lowercase() as u32;
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
        _ => return None,
    }
    Some(input)
}
