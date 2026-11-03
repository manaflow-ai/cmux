//! A key as the platform hands it to the router: its window, phase, key code,
//! modifiers and the facts of its own moment. No characters: the router never
//! needs what a key types, and its state never holds it.

use crate::input::sink::Sink;
use std::sync::Arc;

/// A key event's phase.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum KeyPhase {
    /// The press.
    Down,
    /// An auto-repeat of a held key: it goes where its press went.
    Repeat,
    /// The release: it follows its press.
    Up,
}

/// The modifier keys held with a key.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct Modifiers {
    /// Shift is held.
    pub shift: bool,
    /// Control is held.
    pub control: bool,
    /// Option is held.
    pub option: bool,
    /// Command is held.
    pub command: bool,
}

impl Modifiers {
    /// A Command or Control chord: a binding candidate, never typed text.
    pub fn is_chord(self) -> bool {
        self.command || self.control
    }
}

/// Where the key was typed, relative to its cmux window.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum WindowRole {
    /// The cmux window itself, or a Chromium page window of one of its panes.
    Main,
    /// A panel or sheet over the cmux window (the palette, a group editor, a
    /// sheet): it handles its own keys.
    Overlay,
    /// A window no cmux window owns (Settings, an app panel).
    Other,
}

/// An action's key tier (plans/cmux-next/focus.md section 5).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Tier {
    /// Always runs (in browser focus mode only its exit and Quit).
    System,
    /// Beats terminal keybinds, page shortcuts and text fields, unless
    /// browser focus mode is on.
    Navigation,
    /// Runs only when its content has the keyboard, never in a text field.
    Content,
}

/// The binding table's winner for a key in its window's context (the app's
/// table until rust-migration B5 moves the table into Rust).
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Binding {
    /// The action id.
    pub action: Arc<str>,
    /// The action's tier: which targets let it take a key.
    pub tier: Tier,
    /// A Ghostty keybind: a focused terminal runs its own.
    pub ghostty: bool,
    /// The action edits the input that has the keyboard (Paste, Select All,
    /// Undo): like a key, it waits in that input's lane while the input cannot
    /// take input or keys typed before it wait there.
    pub edits_input: bool,
}

/// One key event, with the facts of its own moment.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct KeyRecord {
    /// The cmux window the key was typed into (its owner when a page window
    /// or a panel of it had the key).
    pub window: Arc<str>,
    /// Where the key was typed, relative to `window`.
    pub role: WindowRole,
    /// Press, auto-repeat or release.
    pub phase: KeyPhase,
    /// The virtual key code.
    pub code: u16,
    /// The modifier keys held with the key.
    pub modifiers: Modifiers,
    /// The event's own time (`CLOCK_UPTIME_RAW` nanoseconds), for the input
    /// journal; no rule reads it.
    pub timestamp_ns: i64,
    /// The first responder has marked text: an input method composes, and
    /// every key but a Command chord is its own.
    pub composing: bool,
    /// The focused terminal is in copy mode (a Ghostty keybind's routed
    /// action runs there).
    pub terminal_copy_mode: bool,
    /// What AppKit's dispatch of this key reaches (the key window's first
    /// responder, classified), none for a view that is no sink.
    pub reaches: Option<Sink>,
    /// The binding table's winner for this key, if any.
    pub binding: Option<Binding>,
    /// The letter (lowercase a-z) the key types with no Command, Control or
    /// Option, by the keyboard layout; none for any other key. A hint session
    /// reads it.
    pub letter: Option<char>,
    /// The chord is one a page uses for editing (Cmd-B bold, Cmd-I, Cmd-U,
    /// Cmd-K; the app's `BrowserChordTable.pageEditingChords`): a navigation
    /// action on it goes to the page first.
    pub page_editing_chord: bool,
    /// Escape does something in the focused field itself now (it clears the
    /// field's text, closes its list): the field takes it.
    pub field_uses_escape: bool,
    /// The focused page reports the keys it leaves unhandled (a Chromium page
    /// whose page window has the keys; the app's
    /// `KeyFacts.pageReportsUnhandledKeys`): only such a page gets a bound
    /// chord first. A WebKit page never reports, so its chords run at once.
    pub page_reports_unhandled: bool,
}

impl KeyRecord {
    /// Text typing (not a chord): an input method may compose it.
    pub fn is_text(&self) -> bool {
        !self.modifiers.is_chord()
    }
}
