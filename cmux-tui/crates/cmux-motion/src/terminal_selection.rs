//! Selecting text in a terminal while its program has the mouse (cmux NEXT
//! `design/terminal.md`, "Selecting text while a program has the mouse").
//!
//! A full-screen TUI that reads the mouse (Claude Code fullscreen, Codex, vim
//! with `mouse=a`) takes every click and drag. Ghostty lets Shift override
//! that capture; other Mac terminals use Option. Here an Option-drag in a
//! capture goes to Ghostty as that Shift override in place of Option, and so
//! do its drags and its release, also once Option is let go (a release that
//! reached the program would clear the selection). Without a capture Option
//! stays Ghostty's rectangle selection, and Option-Shift stays that in a
//! capture. The first plain drag a program takes in a terminal shows a hint
//! once (`hint_shown`).
//!
//! The host keeps one [`TerminalSelection`] per terminal view (a value, no
//! handle) and passes it per pointer event, with the held keys as
//! `KEY_*` bits. It asks whether the program has the mouse (the terminal's
//! lock) only when [`TerminalSelection::press_asks_capture`] says so: at a
//! press with Option alone, or with no key while the hint has yet to show.

/// Command.
pub const KEY_COMMAND: u32 = 1 << 0;
/// Shift.
pub const KEY_SHIFT: u32 = 1 << 1;
/// Option.
pub const KEY_OPTION: u32 = 1 << 2;
/// Control.
pub const KEY_CONTROL: u32 = 1 << 3;
/// Fn.
pub const KEY_FUNCTION: u32 = 1 << 4;

const KEYS: u32 = KEY_COMMAND | KEY_SHIFT | KEY_OPTION | KEY_CONTROL | KEY_FUNCTION;

/// One terminal view's selection override and first-use hint.
/// `selection_press`: the left press held now went as an Option selection.
/// `hint_armed`: a plain press went to the program; its first drag shows the
/// hint. `hint_shown`: the hint showed in this terminal.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
#[repr(C)]
pub struct CmuxTerminalSelection {
    pub selection_press: bool,
    pub hint_armed: bool,
    pub hint_shown: bool,
}

/// The Rust name of [`CmuxTerminalSelection`].
pub type TerminalSelection = CmuxTerminalSelection;

fn option_only(keys: u32) -> bool {
    keys & KEYS == KEY_OPTION
}

fn no_keys(keys: u32) -> bool {
    keys & KEYS == 0
}

/// `keys` as Ghostty gets them in a selection: Shift in place of Option.
fn selection_keys(keys: u32) -> u32 {
    (keys & !KEY_OPTION) | KEY_SHIFT
}

impl CmuxTerminalSelection {
    /// Whether a left press with `keys` needs to know if the program has the mouse.
    pub fn press_asks_capture(&self, keys: u32) -> bool {
        option_only(keys) || (!self.hint_shown && no_keys(keys))
    }

    /// A left press with `keys`; `captured` is whether the program has the
    /// mouse (false when [`Self::press_asks_capture`] said not to ask).
    /// Returns the keys Ghostty gets with the press.
    pub fn press(&mut self, keys: u32, captured: bool) -> u32 {
        self.selection_press = captured && option_only(keys);
        self.hint_armed = captured && !self.hint_shown && no_keys(keys);
        self.following(keys)
    }

    /// The keys Ghostty gets with a drag or the release of the press held now.
    pub fn following(&self, keys: u32) -> u32 {
        if self.selection_press { selection_keys(keys) } else { keys }
    }

    /// A drag of the left press. True once per terminal: the first drag after
    /// an armed press, when the host shows the hint.
    pub fn dragged(&mut self) -> bool {
        if !self.hint_armed {
            return false;
        }
        self.hint_armed = false;
        self.hint_shown = true;
        true
    }

    /// The left button's release, after its keys went out.
    pub fn released(&mut self) {
        self.selection_press = false;
        self.hint_armed = false;
    }
}

#[cfg(test)]
mod tests;
