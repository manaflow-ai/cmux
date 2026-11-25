//! Browser input mapping: modifier bits, key and character codes for the
//! browser, hover forwarding policy, and browser mouse dispatch.

use cmux_tui_core::BrowserStatus;
use crossterm::event::{KeyCode, KeyModifiers};

use crate::browser_input::BrowserKey;

#[derive(Debug, Clone, Copy)]
pub(super) struct BrowserMouseDispatch {
    pub(super) event_type: &'static str,
    pub(super) button: Option<&'static str>,
    pub(super) click_count: Option<u32>,
}

impl BrowserMouseDispatch {
    pub(super) const fn new(
        event_type: &'static str,
        button: Option<&'static str>,
        click_count: Option<u32>,
    ) -> Self {
        Self { event_type, button, click_count }
    }
}

pub(super) fn browser_modifiers(modifiers: KeyModifiers) -> Option<u32> {
    if modifiers.contains(KeyModifiers::HYPER) {
        return None;
    }
    let mut out = 0;
    if modifiers.contains(KeyModifiers::ALT) {
        out |= 1;
    }
    if modifiers.contains(KeyModifiers::CONTROL) {
        out |= 2;
    }
    if modifiers.intersects(KeyModifiers::SUPER | KeyModifiers::META) {
        out |= 4;
    }
    if modifiers.contains(KeyModifiers::SHIFT) {
        out |= 8;
    }
    Some(out)
}

pub(super) fn browser_hover_forward_allowed(
    status: Option<BrowserStatus>,
    editing_same_pane: bool,
) -> bool {
    !editing_same_pane && matches!(status, Some(BrowserStatus::Live))
}

pub(super) fn browser_key_mapping(
    code: KeyCode,
    base_layout_key: Option<char>,
) -> Option<(BrowserKey, &'static str, u32, Option<&'static str>)> {
    match code {
        KeyCode::Char(character) => {
            // Preserve the logical key without claiming a physical DOM code
            // when the host did not report an authoritative base-layout key.
            let (code, vk) = base_layout_key.map(browser_character_code).unwrap_or(("", 0));
            Some((BrowserKey::Character(character), code, vk, None))
        }
        KeyCode::Enter => Some((BrowserKey::Named("Enter"), "Enter", 13, Some("\r"))),
        KeyCode::Backspace => Some((BrowserKey::Named("Backspace"), "Backspace", 8, None)),
        KeyCode::Tab | KeyCode::BackTab => Some((BrowserKey::Named("Tab"), "Tab", 9, None)),
        KeyCode::Esc => Some((BrowserKey::Named("Escape"), "Escape", 27, None)),
        KeyCode::Left => Some((BrowserKey::Named("ArrowLeft"), "ArrowLeft", 37, None)),
        KeyCode::Up => Some((BrowserKey::Named("ArrowUp"), "ArrowUp", 38, None)),
        KeyCode::Right => Some((BrowserKey::Named("ArrowRight"), "ArrowRight", 39, None)),
        KeyCode::Down => Some((BrowserKey::Named("ArrowDown"), "ArrowDown", 40, None)),
        KeyCode::Home => Some((BrowserKey::Named("Home"), "Home", 36, None)),
        KeyCode::End => Some((BrowserKey::Named("End"), "End", 35, None)),
        KeyCode::PageUp => Some((BrowserKey::Named("PageUp"), "PageUp", 33, None)),
        KeyCode::PageDown => Some((BrowserKey::Named("PageDown"), "PageDown", 34, None)),
        KeyCode::Delete => Some((BrowserKey::Named("Delete"), "Delete", 46, None)),
        _ => None,
    }
}

pub(super) const BROWSER_LETTER_CODES: [&str; 26] = [
    "KeyA", "KeyB", "KeyC", "KeyD", "KeyE", "KeyF", "KeyG", "KeyH", "KeyI", "KeyJ", "KeyK", "KeyL",
    "KeyM", "KeyN", "KeyO", "KeyP", "KeyQ", "KeyR", "KeyS", "KeyT", "KeyU", "KeyV", "KeyW", "KeyX",
    "KeyY", "KeyZ",
];

pub(super) const BROWSER_DIGIT_CODES: [&str; 10] = [
    "Digit0", "Digit1", "Digit2", "Digit3", "Digit4", "Digit5", "Digit6", "Digit7", "Digit8",
    "Digit9",
];

pub(super) fn browser_character_code(character: char) -> (&'static str, u32) {
    match character {
        'a'..='z' | 'A'..='Z' => {
            let upper = character.to_ascii_uppercase();
            (BROWSER_LETTER_CODES[(upper as u8 - b'A') as usize], upper as u32)
        }
        '0'..='9' => (BROWSER_DIGIT_CODES[(character as u8 - b'0') as usize], character as u32),
        ' ' => ("Space", 32),
        ';' => ("Semicolon", 186),
        '=' => ("Equal", 187),
        ',' => ("Comma", 188),
        '-' => ("Minus", 189),
        '.' => ("Period", 190),
        '/' => ("Slash", 191),
        '`' => ("Backquote", 192),
        '[' => ("BracketLeft", 219),
        '\\' => ("Backslash", 220),
        ']' => ("BracketRight", 221),
        '\'' => ("Quote", 222),
        _ => ("", 0),
    }
}
