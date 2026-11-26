//! The one keymap layer of two cmux NEXT settings (design/keyboard-style.md):
//!
//! - `app.keyStyle` (`standard`, `vim`, `emacs`): the list navigation keys a style adds
//!   ([`ListKeys`]): j/k, gg/G, / and Esc for vim; Ctrl-n/p/f/b/a/e for emacs.
//! - `app.shortcutLayout` (`followLayout`, `qwertyPositions`): whether a shortcut is the
//!   character the keyboard layout types or the physical US key position
//!   ([`stroke_matches`]), so Dvorak, Colemak, AZERTY and QWERTZ users can keep their muscle
//!   memory.
//!
//! Both read `schemas/keymap/key-styles.json` (embedded with `include_str!`), the table
//! `webviews/src/ui/keyStyle.ts` imports for the web surfaces; both run every case of
//! `schemas/keymap/key-vectors.json`. The macOS app calls this crate through [`ffi`]
//! (`include/cmux_keymap.h`, linked into cmux-app-ffi).

pub mod ffi;
mod list;
mod matching;
mod stroke;
mod table;

pub use list::{ListKeys, Outcome};
pub use matching::{
    CANDIDATE_KEY_MAX, CANDIDATES_MAX, Candidate, Candidates, candidates, code_for_mac_key_code,
    key_candidates, mac_key_code_for_code, qwerty_char, stroke_matches,
};
pub use stroke::Stroke;
pub use table::{KEY_STYLES_JSON, check_table};

/// `app.keyStyle`: which list navigation keys apply.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum KeyStyle {
    /// No added keys: every key stays with the surface.
    #[default]
    Standard,
    Vim,
    Emacs,
}

impl KeyStyle {
    pub const ALL: [KeyStyle; 3] = [KeyStyle::Standard, KeyStyle::Vim, KeyStyle::Emacs];

    /// The setting's value; anything unknown is the default, `standard`.
    pub fn from_setting(value: &str) -> Self {
        Self::from_setting_exact(value).unwrap_or_default()
    }

    pub(crate) fn from_setting_exact(value: &str) -> Option<Self> {
        match value {
            "standard" => Some(KeyStyle::Standard),
            "vim" => Some(KeyStyle::Vim),
            "emacs" => Some(KeyStyle::Emacs),
            _ => None,
        }
    }

    pub fn as_setting(self) -> &'static str {
        match self {
            KeyStyle::Standard => "standard",
            KeyStyle::Vim => "vim",
            KeyStyle::Emacs => "emacs",
        }
    }
}

/// `app.shortcutLayout`: how a shortcut's key is matched.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum ShortcutLayout {
    /// A shortcut is the character the layout types (with the digit-row, non-ASCII/dead-key
    /// and Shift-consumed fallbacks of key-vectors.json's `$shortcutComment`).
    #[default]
    FollowLayout,
    /// A shortcut is the key at that US QWERTY position, whatever the layout types.
    QwertyPositions,
}

impl ShortcutLayout {
    pub const ALL: [ShortcutLayout; 2] =
        [ShortcutLayout::FollowLayout, ShortcutLayout::QwertyPositions];

    /// The setting's value; anything unknown is the default, `followLayout`.
    pub fn from_setting(value: &str) -> Self {
        match value {
            "qwertyPositions" => ShortcutLayout::QwertyPositions,
            _ => ShortcutLayout::FollowLayout,
        }
    }

    pub fn as_setting(self) -> &'static str {
        match self {
            ShortcutLayout::FollowLayout => "followLayout",
            ShortcutLayout::QwertyPositions => "qwertyPositions",
        }
    }
}

/// The modifiers held with a key, or named by a stroke.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct Mods {
    pub cmd: bool,
    pub ctrl: bool,
    pub alt: bool,
    pub shift: bool,
}

impl Mods {
    pub const CMD: u32 = 1;
    pub const CTRL: u32 = 2;
    pub const ALT: u32 = 4;
    pub const SHIFT: u32 = 8;

    pub const NONE: Mods = Mods { cmd: false, ctrl: false, alt: false, shift: false };

    /// From the C ABI's bits: cmd 1, ctrl 2, alt 4, shift 8; other bits are ignored.
    pub fn from_bits(bits: u32) -> Self {
        Mods {
            cmd: bits & Self::CMD != 0,
            ctrl: bits & Self::CTRL != 0,
            alt: bits & Self::ALT != 0,
            shift: bits & Self::SHIFT != 0,
        }
    }

    pub fn bits(self) -> u32 {
        (if self.cmd { Self::CMD } else { 0 })
            | (if self.ctrl { Self::CTRL } else { 0 })
            | (if self.alt { Self::ALT } else { 0 })
            | (if self.shift { Self::SHIFT } else { 0 })
    }

    /// A modifier name of the keybindings.json stroke syntax (and its common aliases).
    pub fn with_name(mut self, name: &str) -> Option<Self> {
        match name.to_ascii_lowercase().as_str() {
            "cmd" | "command" | "meta" | "super" => self.cmd = true,
            "ctrl" | "control" => self.ctrl = true,
            "alt" | "opt" | "option" => self.alt = true,
            "shift" => self.shift = true,
            _ => return None,
        }
        Some(self)
    }

    pub fn without_shift(self) -> Self {
        Mods { shift: false, ..self }
    }
}

/// One key press as a surface sees it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KeyEvent<'a> {
    /// The physical key, as its W3C `KeyboardEvent.code` name (`KeyZ`, `Escape`), when known.
    pub code: Option<&'a str>,
    /// What the layout types on the key without modifiers (lowercase), `Dead` for a dead key,
    /// or a named key (`escape`, `enter`, `up`, `down`, `left`, `right`, `pageup`, `pagedown`).
    pub key: &'a str,
    /// What the layout types on the key with Shift, when known.
    pub shifted_key: Option<&'a str>,
    pub mods: Mods,
}

/// A list command, in the order of key-styles.json's `commands` (its index there is
/// [`ListCommand::index`] and the C ABI's return value).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ListCommand {
    Next,
    Previous,
    First,
    Last,
    PageDown,
    PageUp,
    Open,
    Back,
    Search,
    Leave,
}

impl ListCommand {
    pub const ALL: [ListCommand; 10] = [
        ListCommand::Next,
        ListCommand::Previous,
        ListCommand::First,
        ListCommand::Last,
        ListCommand::PageDown,
        ListCommand::PageUp,
        ListCommand::Open,
        ListCommand::Back,
        ListCommand::Search,
        ListCommand::Leave,
    ];

    /// The command id (`list.next`).
    pub fn id(self) -> &'static str {
        match self {
            ListCommand::Next => "list.next",
            ListCommand::Previous => "list.previous",
            ListCommand::First => "list.first",
            ListCommand::Last => "list.last",
            ListCommand::PageDown => "list.pageDown",
            ListCommand::PageUp => "list.pageUp",
            ListCommand::Open => "list.open",
            ListCommand::Back => "list.back",
            ListCommand::Search => "list.search",
            ListCommand::Leave => "list.leave",
        }
    }

    pub fn from_id(id: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|c| c.id() == id)
    }

    /// The command's index in key-styles.json's `commands`.
    pub fn index(self) -> usize {
        match self {
            ListCommand::Next => 0,
            ListCommand::Previous => 1,
            ListCommand::First => 2,
            ListCommand::Last => 3,
            ListCommand::PageDown => 4,
            ListCommand::PageUp => 5,
            ListCommand::Open => 6,
            ListCommand::Back => 7,
            ListCommand::Search => 8,
            ListCommand::Leave => 9,
        }
    }
}

// A candidate key and its NUL fit the C ABI's stroke.
const _: () = assert!(CANDIDATE_KEY_MAX < ffi::CMUX_KEYMAP_STROKE_KEY_LEN);
const _: () = assert!(CANDIDATES_MAX == ffi::CMUX_KEYMAP_CANDIDATES_MAX);
