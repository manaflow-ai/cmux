//! Terminal key events to RFB key events.
//!
//! With the Kitty keyboard protocol the terminal reports presses, repeats
//! and releases (modifier keys included), so keys go down and up as the
//! person holds them. Without it each event is a press only; the key then
//! goes down and up at once, inside the modifiers the event names.
//! Ctrl-] starts a viewer command (the next key) and never reaches the server.

use std::collections::{BTreeSet, HashMap};

use cmux_vnc::keysym::{Key, keysym};
use crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyModifiers, ModifierKeyCode};

/// What a key event asks for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum KeyAction {
    /// RFB key events, in order: (keysym, down).
    Send(Vec<(u32, bool)>),
    Command(Command),
    /// Ctrl-] was pressed; the next key is a command.
    AwaitCommand,
    None,
}

/// Viewer commands after Ctrl-].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Command {
    Quit,
    Reconnect,
    ToggleViewOnly,
    Refresh,
    /// Ctrl-] Ctrl-] sends one Ctrl-] to the server.
    SendEscape,
    /// Any other key cancels.
    Cancel,
}

const SHIFT: u32 = 0xFFE1;
const CONTROL: u32 = 0xFFE3;
const ALT: u32 = 0xFFE9;
const SUPER: u32 = 0xFFEB;

/// The keyboard state of one session.
#[derive(Debug, Default)]
pub(super) struct Keyboard {
    /// The terminal reports releases (Kitty keyboard protocol).
    enhanced: bool,
    awaiting_command: bool,
    /// Keysyms this viewer holds down on the server.
    down: BTreeSet<u32>,
    /// The keysym each held non-modifier key went down as, by its physical
    /// key, so the release matches even when Shift changed in between
    /// (press 1, press Shift, release: the release reports `!`).
    pressed: HashMap<KeyCode, u32>,
    /// Modifiers this viewer pressed on its own (the terminal never reported
    /// them), released after the key that needed them.
    synthetic: BTreeSet<u32>,
}

impl Keyboard {
    pub fn new(enhanced: bool) -> Self {
        Self { enhanced, ..Self::default() }
    }

    /// Translates one terminal key event. `shifted` is the shifted character
    /// the Kitty protocol reports with Shift held.
    pub fn handle(&mut self, event: &KeyEvent, shifted: Option<char>) -> KeyAction {
        let press = matches!(event.kind, KeyEventKind::Press | KeyEventKind::Repeat);
        if self.awaiting_command {
            if !press || modifier(event.code).is_some() {
                return KeyAction::None;
            }
            self.awaiting_command = false;
            return KeyAction::Command(if self.is_escape(event) {
                Command::SendEscape
            } else {
                match event.code {
                    KeyCode::Char('q' | 'Q') => Command::Quit,
                    KeyCode::Char('r' | 'R') => Command::Reconnect,
                    KeyCode::Char('v' | 'V') => Command::ToggleViewOnly,
                    KeyCode::Char('f' | 'F') => Command::Refresh,
                    _ => Command::Cancel,
                }
            });
        }
        if event.kind == KeyEventKind::Press && self.is_escape(event) {
            self.awaiting_command = true;
            return KeyAction::AwaitCommand;
        }

        if let Some(sym) = modifier(event.code) {
            // A real modifier event (Kitty protocol only).
            let mut out = Vec::new();
            self.synthetic.remove(&sym);
            if press {
                self.down.insert(sym);
                out.push((sym, true));
            } else if self.down.remove(&sym) {
                out.push((sym, false));
            }
            return KeyAction::Send(out);
        }

        // Shift-Tab arrives as BackTab, Shift not always named.
        let modifiers = if event.code == KeyCode::BackTab {
            event.modifiers | KeyModifiers::SHIFT
        } else {
            event.modifiers
        };
        let physical = physical_key(event.code);
        let mut out = Vec::new();
        if !press {
            if let Some(sym) = self.pressed.remove(&physical) {
                self.down.remove(&sym);
                out.push((sym, false));
            }
            if self.down.iter().all(|held| is_modifier_sym(*held)) {
                self.release_synthetic(&mut out);
            }
            return KeyAction::Send(out);
        }
        let Some(sym) = key(event.code, modifiers, shifted).and_then(keysym) else {
            return KeyAction::None;
        };
        self.sync_modifiers(event.code, modifiers, &mut out);
        if !self.enhanced {
            out.extend([(sym, true), (sym, false)]);
            self.release_synthetic(&mut out);
            return KeyAction::Send(out);
        }
        // A repeat that now means another keysym (Shift changed) lets go of the old one.
        if let Some(old) = self.pressed.insert(physical, sym)
            && old != sym
            && self.down.remove(&old)
        {
            out.push((old, false));
        }
        self.down.insert(sym);
        out.push((sym, true));
        KeyAction::Send(out)
    }

    /// Ctrl-] (0x1D). Legacy terminals report it as Ctrl-5; with the Kitty
    /// protocol Ctrl-5 is its own key and goes to the server.
    fn is_escape(&self, event: &KeyEvent) -> bool {
        event.modifiers.contains(KeyModifiers::CONTROL)
            && match event.code {
                KeyCode::Char(']') => true,
                KeyCode::Char('5') => !self.enhanced,
                _ => false,
            }
    }

    /// Presses the modifiers `modifiers` names that are not down, and lets
    /// go of synthetic ones it no longer names. Shift is not synthesized for
    /// a character: the character's keysym already says what Shift made.
    fn sync_modifiers(
        &mut self,
        code: KeyCode,
        modifiers: KeyModifiers,
        out: &mut Vec<(u32, bool)>,
    ) {
        let char_key = matches!(code, KeyCode::Char(_));
        for (flag, sym) in [
            (KeyModifiers::CONTROL, CONTROL),
            (KeyModifiers::ALT, ALT),
            (KeyModifiers::SUPER, SUPER),
            (KeyModifiers::SHIFT, SHIFT),
        ] {
            let wanted = modifiers.contains(flag) && !(sym == SHIFT && char_key);
            if wanted && !self.down.contains(&sym) {
                self.down.insert(sym);
                self.synthetic.insert(sym);
                out.push((sym, true));
            } else if !wanted && self.synthetic.remove(&sym) {
                self.down.remove(&sym);
                out.push((sym, false));
            }
        }
    }

    fn release_synthetic(&mut self, out: &mut Vec<(u32, bool)>) {
        for sym in std::mem::take(&mut self.synthetic).into_iter().rev() {
            self.down.remove(&sym);
            out.push((sym, false));
        }
    }

    /// Releases every key this viewer holds (focus lost, reconnect, exit).
    pub fn release_all(&mut self) -> Vec<(u32, bool)> {
        self.synthetic.clear();
        self.pressed.clear();
        self.awaiting_command = false;
        std::mem::take(&mut self.down).into_iter().rev().map(|sym| (sym, false)).collect()
    }
}

/// The physical key behind a code: letters fold to lowercase (Shift may
/// or may not be applied to the reported code), Shift-Tab is Tab.
fn physical_key(code: KeyCode) -> KeyCode {
    match code {
        KeyCode::Char(c) => KeyCode::Char(c.to_ascii_lowercase()),
        KeyCode::BackTab => KeyCode::Tab,
        other => other,
    }
}

fn is_modifier_sym(sym: u32) -> bool {
    (0xFFE1..=0xFFEE).contains(&sym)
}

fn modifier(code: KeyCode) -> Option<u32> {
    let KeyCode::Modifier(modifier) = code else { return None };
    Some(match modifier {
        ModifierKeyCode::LeftShift => SHIFT,
        ModifierKeyCode::RightShift => 0xFFE2,
        ModifierKeyCode::LeftControl => CONTROL,
        ModifierKeyCode::RightControl => 0xFFE4,
        ModifierKeyCode::LeftAlt => ALT,
        ModifierKeyCode::RightAlt => 0xFFEA,
        ModifierKeyCode::LeftSuper | ModifierKeyCode::LeftHyper => SUPER,
        ModifierKeyCode::RightSuper | ModifierKeyCode::RightHyper => 0xFFEC,
        ModifierKeyCode::LeftMeta => 0xFFE7,
        ModifierKeyCode::RightMeta => 0xFFE8,
        ModifierKeyCode::IsoLevel3Shift => 0xFE03,
        ModifierKeyCode::IsoLevel5Shift => 0xFE11,
    })
}

fn key(code: KeyCode, modifiers: KeyModifiers, shifted: Option<char>) -> Option<Key> {
    Some(match code {
        KeyCode::Char(c) => match shifted {
            Some(shifted) if modifiers.contains(KeyModifiers::SHIFT) => Key::Char(shifted),
            _ => Key::Char(c),
        },
        KeyCode::Backspace => Key::Backspace,
        KeyCode::Enter => Key::Enter,
        KeyCode::Tab | KeyCode::BackTab => Key::Tab,
        KeyCode::Esc => Key::Escape,
        KeyCode::Delete => Key::Delete,
        KeyCode::Insert => Key::Insert,
        KeyCode::Home => Key::Home,
        KeyCode::End => Key::End,
        KeyCode::PageUp => Key::PageUp,
        KeyCode::PageDown => Key::PageDown,
        KeyCode::Left => Key::Left,
        KeyCode::Right => Key::Right,
        KeyCode::Up => Key::Up,
        KeyCode::Down => Key::Down,
        KeyCode::F(n) => Key::F(n),
        KeyCode::CapsLock => Key::CapsLock,
        KeyCode::NumLock => Key::NumLock,
        KeyCode::ScrollLock => Key::ScrollLock,
        KeyCode::PrintScreen => Key::PrintScreen,
        KeyCode::Pause => Key::Pause,
        KeyCode::Menu => Key::Menu,
        _ => return None,
    })
}
