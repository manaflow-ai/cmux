//! The viewer's keyboard rules (was `RemoteKeyboardPolicy.swift`,
//! `RemoteSystemShortcuts.swift`, `RemoteKeyboardState.swift`,
//! `RemoteHIDKeyMap.swift`, `RemoteScrollAccumulator.swift` and
//! `RemoteInputEvent.textEvents`): which key goes where, which keys the host
//! believes are down, and how AppKit deltas become wire scroll events.
//!
//! Modifier flags are AppKit's `NSEvent.ModifierFlags` raw bits and scroll
//! phases `NSEvent.Phase` raw bits, so the caller passes `rawValue` as is.

use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

/// `NSEvent.ModifierFlags` bits.
pub mod flags {
    pub const CAPS_LOCK: u64 = 1 << 16;
    pub const SHIFT: u64 = 1 << 17;
    pub const CONTROL: u64 = 1 << 18;
    pub const OPTION: u64 = 1 << 19;
    pub const COMMAND: u64 = 1 << 20;
    /// `.deviceIndependentFlagsMask`.
    pub const DEVICE_INDEPENDENT: u64 = 0xFFFF_0000;
    /// Command, Control, Option and Shift: what a chord compares.
    pub const CHORD: u64 = SHIFT | CONTROL | OPTION | COMMAND;
}

/// `NSEvent.Phase` bits.
pub mod phase {
    pub const BEGAN: u64 = 0x1;
    pub const ENDED: u64 = 0x8;
    pub const CANCELLED: u64 = 0x10;
    pub const MAY_BEGIN: u64 = 0x20;
}

/// macOS virtual key codes the rules name (Carbon `kVK_*`).
pub mod key {
    pub const TAB: u16 = 0x30;
    pub const GRAVE: u16 = 0x32;
    pub const SPACE: u16 = 0x31;
    pub const ESCAPE: u16 = 0x35;
    pub const LEFT: u16 = 0x7B;
    pub const RIGHT: u16 = 0x7C;
    pub const DOWN: u16 = 0x7D;
    pub const UP: u16 = 0x7E;
    pub const MISSION_CONTROL: u16 = 0xA0;
    pub const LAUNCHPAD: u16 = 0x83;
    pub const Q: u16 = 0x0C;
    pub const H: u16 = 0x04;
    pub const M: u16 = 0x2E;
    pub const W: u16 = 0x0D;
    pub const THREE: u16 = 0x14;
    pub const FOUR: u16 = 0x15;
    pub const FIVE: u16 = 0x17;
    pub const CAPS_LOCK: u16 = 0x39;
}

/// HID keyboard/keypad usage page.
pub const KEYBOARD_PAGE: u32 = 0x07;

/// Key code to HID usage id pairs (index = key code); key codes name physical
/// positions, so the table is layout independent.
#[rustfmt::skip]
const PAIRS: &[(u16, u16)] = &[
    // letters a..z
    (0x00, 0x04), (0x0B, 0x05), (0x08, 0x06), (0x02, 0x07), (0x0E, 0x08), (0x03, 0x09),
    (0x05, 0x0A), (0x04, 0x0B), (0x22, 0x0C), (0x26, 0x0D), (0x28, 0x0E), (0x25, 0x0F),
    (0x2E, 0x10), (0x2D, 0x11), (0x1F, 0x12), (0x23, 0x13), (0x0C, 0x14), (0x0F, 0x15),
    (0x01, 0x16), (0x11, 0x17), (0x20, 0x18), (0x09, 0x19), (0x0D, 0x1A), (0x07, 0x1B),
    (0x10, 0x1C), (0x06, 0x1D),
    // digits 1..0
    (0x12, 0x1E), (0x13, 0x1F), (0x14, 0x20), (0x15, 0x21), (0x17, 0x22),
    (0x16, 0x23), (0x1A, 0x24), (0x1C, 0x25), (0x19, 0x26), (0x1D, 0x27),
    // punctuation - = [ ] \ ; ' ` , . /
    (0x1B, 0x2D), (0x18, 0x2E), (0x21, 0x2F), (0x1E, 0x30), (0x2A, 0x31),
    (0x29, 0x33), (0x27, 0x34), (0x32, 0x35), (0x2B, 0x36), (0x2F, 0x37),
    (0x2C, 0x38),
    // editing: return escape delete tab space, help home pgup fwd-delete end,
    // pgdn right left down up, context menu
    (0x24, 0x28), (0x35, 0x29), (0x33, 0x2A), (0x30, 0x2B), (0x31, 0x2C),
    (0x72, 0x49), (0x73, 0x4A), (0x74, 0x4B), (0x75, 0x4C), (0x77, 0x4D),
    (0x79, 0x4E), (0x7C, 0x4F), (0x7B, 0x50), (0x7D, 0x51), (0x7E, 0x52),
    (0x6E, 0x65),
    // modifiers: caps lock, left control shift option command, right ones
    (0x39, 0x39),
    (0x3B, 0xE0), (0x38, 0xE1), (0x3A, 0xE2), (0x37, 0xE3),
    (0x3E, 0xE4), (0x3C, 0xE5), (0x3D, 0xE6), (0x36, 0xE7),
    // F1..F20
    (0x7A, 0x3A), (0x78, 0x3B), (0x63, 0x3C), (0x76, 0x3D), (0x60, 0x3E),
    (0x61, 0x3F), (0x62, 0x40), (0x64, 0x41), (0x65, 0x42), (0x6D, 0x43),
    (0x67, 0x44), (0x6F, 0x45), (0x69, 0x68), (0x6B, 0x69), (0x71, 0x6A),
    (0x6A, 0x6B), (0x40, 0x6C), (0x4F, 0x6D), (0x50, 0x6E), (0x5A, 0x6F),
    // keypad: clear / * - +, enter 1 2 3 4, 5 6 7 8 9, 0 . =
    (0x47, 0x53), (0x4B, 0x54), (0x43, 0x55), (0x4E, 0x56), (0x45, 0x57),
    (0x4C, 0x58), (0x53, 0x59), (0x54, 0x5A), (0x55, 0x5B), (0x56, 0x5C),
    (0x57, 0x5D), (0x58, 0x5E), (0x59, 0x5F), (0x5B, 0x60), (0x5C, 0x61),
    (0x52, 0x62), (0x41, 0x63), (0x51, 0x67),
    // international: ISO section, JIS keypad comma, Ro, yen, kana, eisu
    (0x0A, 0x64), (0x5F, 0x85), (0x5E, 0x87), (0x5D, 0x89), (0x68, 0x90), (0x66, 0x91),
    // media: mute, volume up, volume down
    (0x4A, 0x7F), (0x48, 0x80), (0x49, 0x81),
];

/// Index = key code, value = HID usage id (0 = none). 0x80 entries.
pub fn hid_table() -> [u16; 0x80] {
    let mut table = [0u16; 0x80];
    for &(code, id) in PAIRS {
        table[usize::from(code)] = id;
    }
    table
}

/// The full usage (`page << 16 | id`) of a key code; None for keys with no
/// HID usage (fn) or unknown codes.
pub fn usage(key_code: u16) -> Option<u32> {
    let table = hid_table();
    let id = *table.get(usize::from(key_code))?;
    (id != 0).then(|| KEYBOARD_PAGE << 16 | u32::from(id))
}

/// The key code of a usage on the keyboard page (the first in the table).
pub fn key_code(usage: u32) -> Option<u16> {
    if usage >> 16 != KEYBOARD_PAGE {
        return None;
    }
    let id = (usage & 0xFFFF) as u16;
    hid_table().iter().position(|&v| v == id).map(|i| i as u16)
}

/// Modifier keys (HID 0xE0...0xE7) and Caps Lock.
pub const MODIFIER_KEY_CODES: [u16; 9] = [0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E];

pub fn is_modifier(key_code: u16) -> bool {
    MODIFIER_KEY_CODES.contains(&key_code)
}

/// How a key event leaves the viewer (`remoteDesktop.keyboard.mode`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum KeyboardMode {
    #[default]
    Auto,
    Physical,
    Text,
}

/// Where a key down goes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Route {
    /// Handled in the viewer: never sent.
    Local,
    /// The release chord: the keyboard returns to the viewer.
    ReleaseKeyboard,
    Physical,
    TextInput,
}

/// The chord that always returns the keyboard to the viewer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReleaseChord {
    pub key_code: u16,
    pub modifiers: u64,
}

impl Default for ReleaseChord {
    /// Control-Option-Escape.
    fn default() -> Self {
        Self { key_code: key::ESCAPE, modifiers: flags::CONTROL | flags::OPTION }
    }
}

impl ReleaseChord {
    pub fn matches(&self, key_code: u16, modifiers: u64) -> bool {
        key_code == self.key_code && modifiers & flags::CHORD == self.modifiers & flags::CHORD
    }
}

/// Routes a key down. `is_local_shortcut` (the App's matcher for cmux
/// shortcuts) applies only while system shortcuts stay local.
pub fn route(
    key_code: u16,
    modifiers: u64,
    mode: KeyboardMode,
    send_system_shortcuts: bool,
    input_source_is_ascii_capable: bool,
    release_chord: ReleaseChord,
    is_local_shortcut: bool,
) -> Route {
    let f = modifiers & flags::DEVICE_INDEPENDENT;
    if release_chord.matches(key_code, f) {
        return Route::ReleaseKeyboard;
    }
    if !send_system_shortcuts && (is_system_shortcut(key_code, f) || is_local_shortcut) {
        return Route::Local;
    }
    let text_mode = match mode {
        KeyboardMode::Physical => false,
        KeyboardMode::Text => true,
        KeyboardMode::Auto => !input_source_is_ascii_capable,
    };
    if text_mode && types_text(key_code, f) { Route::TextInput } else { Route::Physical }
}

/// Chords the system or the window server owns (app switching, Spotlight and
/// input sources, Mission Control and Spaces, Cmd-Q / Cmd-H / Cmd-M).
pub fn is_system_shortcut(key_code: u16, modifiers: u64) -> bool {
    let f = modifiers & flags::CHORD;
    match key_code {
        key::TAB | key::GRAVE => f & flags::COMMAND != 0,
        key::SPACE => f & flags::COMMAND != 0 || f == flags::CONTROL,
        key::LEFT | key::RIGHT | key::UP | key::DOWN => f == flags::CONTROL,
        key::MISSION_CONTROL | key::LAUNCHPAD => true,
        key::Q | key::H | key::M => f == flags::COMMAND || f == flags::COMMAND | flags::OPTION,
        _ => false,
    }
}

/// Whether the key can produce text: no Command or Control, and not a
/// navigation, editing or function key.
pub fn types_text(key_code: u16, modifiers: u64) -> bool {
    if modifiers & (flags::COMMAND | flags::CONTROL) != 0 {
        return false;
    }
    let Some(usage) = usage(key_code) else { return false };
    match usage & 0xFFFF {
        0x28..=0x2B => false,
        0x04..=0x38 | 0x64 | 0x85 | 0x87 | 0x89 => true,
        0x54..=0x57 | 0x59..=0x63 | 0x67 => true,
        _ => false,
    }
}

/// Whether a key routed physical goes as its text instead: its characters
/// differ from what its key code types on the viewer's own layout (CMUX-572).
pub fn sends_as_text(
    characters: Option<&str>,
    layout_characters: Option<&str>,
    modifiers: u64,
) -> bool {
    if modifiers & (flags::COMMAND | flags::CONTROL) != 0 {
        return false;
    }
    let (Some(characters), Some(layout)) = (characters, layout_characters) else { return false };
    if characters.is_empty() {
        return false;
    }
    let types_nothing =
        characters.chars().any(|c| c.is_control() || ('\u{F700}'..='\u{F8FF}').contains(&c));
    !types_nothing && characters != layout
}

/// Mouse buttons on the wire (X11 numbering).
pub const BUTTONS: [u8; 5] = [1, 2, 3, 8, 9];

/// AppKit's `buttonNumber` to the wire button.
pub fn button_from_appkit(number: i64) -> Option<u8> {
    match number {
        0 => Some(1),
        1 => Some(3),
        2 => Some(2),
        3 => Some(8),
        4 => Some(9),
        _ => None,
    }
}

/// One viewer input event, in the cmux-rd-proto `InputEvent` fields.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum InputEvent {
    Key { usage: u32, down: bool },
    Pointer { x: i32, y: i32 },
    Button { button: u8, down: bool },
    Scroll { dx: i32, dy: i32, precise: bool },
    Text { text: String },
}

/// cmux-rd-proto `MAX_TEXT_BYTES`.
pub const MAX_TEXT_BYTES: usize = 256;

/// `text` split into events of at most [`MAX_TEXT_BYTES`], cut on grapheme
/// boundaries (Swift `Character`s; a cluster is approximated by a base scalar
/// with its following combining and joining scalars).
pub fn text_events(text: &str) -> Vec<InputEvent> {
    let mut events = Vec::new();
    let mut chunk = String::new();
    for cluster in clusters(text) {
        if chunk.len() + cluster.len() > MAX_TEXT_BYTES && !chunk.is_empty() {
            events.push(InputEvent::Text { text: std::mem::take(&mut chunk) });
        }
        chunk.push_str(cluster);
    }
    if !chunk.is_empty() {
        events.push(InputEvent::Text { text: chunk });
    }
    events
}

/// Extended-grapheme-ish clusters: a scalar plus every following scalar that
/// extends it (combining marks, variation selectors, ZWJ and what it joins,
/// emoji modifiers, regional indicator pairs, CR LF).
fn clusters(text: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let mut start = 0;
    let mut prev: Option<char> = None;
    let mut ri_run = 0usize;
    for (i, c) in text.char_indices() {
        if let Some(p) = prev {
            let joins = extends(c)
                || p == '\u{200D}'
                || (p == '\r' && c == '\n')
                || (is_regional(p) && is_regional(c) && ri_run % 2 == 1);
            if !joins {
                out.push(&text[start..i]);
                start = i;
                ri_run = 0;
            }
        }
        if is_regional(c) {
            ri_run += 1
        } else {
            ri_run = 0
        }
        prev = Some(c);
    }
    if start < text.len() {
        out.push(&text[start..]);
    }
    out
}

fn is_regional(c: char) -> bool {
    ('\u{1F1E6}'..='\u{1F1FF}').contains(&c)
}

fn extends(c: char) -> bool {
    let v = c as u32;
    matches!(v,
        0x0300..=0x036F | 0x0483..=0x0489 | 0x0591..=0x05BD | 0x0610..=0x061A | 0x064B..=0x065F
        | 0x0900..=0x0903 | 0x093A..=0x094F | 0x0E31 | 0x0E34..=0x0E3A | 0x0E47..=0x0E4E
        | 0x1AB0..=0x1AFF | 0x1DC0..=0x1DFF | 0x200C | 0x200D | 0x20D0..=0x20FF
        | 0x3099 | 0x309A | 0xFE00..=0xFE0F | 0xFE20..=0xFE2F
        | 0x1F3FB..=0x1F3FF | 0xE0020..=0xE007F | 0xE0100..=0xE01EF)
        || (0x1160..=0x11FF).contains(&v) // Hangul jamo medial and final
}

/// Which keys and buttons the host believes are down.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct KeyboardState {
    pub held_keys: BTreeSet<u16>,
    pub held_buttons: BTreeSet<u8>,
}

impl KeyboardState {
    /// A key down; repeats of a held key send nothing (auto-repeat is the host's).
    pub fn key_down(&mut self, key_code: u16, is_repeat: bool) -> Vec<InputEvent> {
        let Some(usage) = usage(key_code) else { return vec![] };
        if is_repeat && self.held_keys.contains(&key_code) {
            return vec![];
        }
        self.held_keys.insert(key_code);
        vec![InputEvent::Key { usage, down: true }]
    }

    pub fn key_up(&mut self, key_code: u16) -> Vec<InputEvent> {
        if !self.held_keys.remove(&key_code) {
            return vec![];
        }
        match usage(key_code) {
            Some(usage) => vec![InputEvent::Key { usage, down: false }],
            None => vec![],
        }
    }

    /// `flagsChanged` for modifier key `key_code` with the new `modifiers`.
    pub fn flags_changed(&mut self, key_code: u16, modifiers: u64) -> Vec<InputEvent> {
        let Some(usage) = usage(key_code) else { return vec![] };
        if key_code == key::CAPS_LOCK {
            return vec![
                InputEvent::Key { usage, down: true },
                InputEvent::Key { usage, down: false },
            ];
        }
        let Some(family) = family(key_code) else { return vec![] };
        if modifiers & family == 0 {
            let released: Vec<u16> =
                self.held_keys.iter().copied().filter(|&k| family_of(k) == Some(family)).collect();
            return released.into_iter().flat_map(|k| self.key_up(k)).collect();
        }
        if self.held_keys.contains(&key_code) {
            return self.key_up(key_code);
        }
        self.held_keys.insert(key_code);
        vec![InputEvent::Key { usage, down: true }]
    }

    pub fn button_down(&mut self, button: u8) -> Vec<InputEvent> {
        self.held_buttons.insert(button);
        vec![InputEvent::Button { button, down: true }]
    }

    pub fn button_up(&mut self, button: u8) -> Vec<InputEvent> {
        if self.held_buttons.remove(&button) {
            vec![InputEvent::Button { button, down: false }]
        } else {
            vec![]
        }
    }

    /// Ups for everything held, keys then buttons, each in ascending order.
    pub fn release_all(&mut self) -> Vec<InputEvent> {
        let keys: Vec<u16> = self.held_keys.iter().copied().collect();
        let buttons: Vec<u8> = self.held_buttons.iter().copied().collect();
        let mut out: Vec<InputEvent> = keys.into_iter().flat_map(|k| self.key_up(k)).collect();
        out.extend(buttons.into_iter().flat_map(|b| self.button_up(b)));
        out
    }
}

fn family(key_code: u16) -> Option<u64> {
    family_of(key_code)
}

/// The device-independent flag of a modifier key.
pub fn family_of(key_code: u16) -> Option<u64> {
    match key_code {
        0x38 | 0x3C => Some(flags::SHIFT),
        0x3B | 0x3E => Some(flags::CONTROL),
        0x3A | 0x3D => Some(flags::OPTION),
        0x37 | 0x36 => Some(flags::COMMAND),
        _ => None,
    }
}

/// What must all hold for the system shortcut tap to be installed.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TapConditions {
    pub setting: bool,
    pub accessibility: bool,
    pub has_keyboard: bool,
    pub live: bool,
    pub window_key: bool,
    pub app_active: bool,
}

impl TapConditions {
    pub fn installs(&self) -> bool {
        self.setting
            && self.accessibility
            && self.has_keyboard
            && self.live
            && self.window_key
            && self.app_active
    }
}

/// "Send System Shortcuts to the Remote Mac": the tap's state.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SystemShortcuts {
    pub release_chord: ReleaseChord,
    /// Keys whose down the tap took: their ups are taken too.
    pub held_by_tap: BTreeSet<u16>,
}

/// One key event the tap saw.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TapKey {
    pub key_code: u16,
    pub modifiers: u64,
    pub down: bool,
    #[serde(default)]
    pub is_repeat: bool,
}

impl SystemShortcuts {
    /// Whether the tap takes a key down with `modifiers`.
    pub fn takes(&self, key_code: u16, modifiers: u64) -> bool {
        let f = modifiers & flags::CHORD;
        if self.release_chord.matches(key_code, f) || usage(key_code).is_none() {
            return false;
        }
        use flags::{COMMAND as CMD, CONTROL as CTL, OPTION as OPT, SHIFT as SH};
        match key_code {
            key::SPACE => f == CMD || f == CMD | OPT || f == CTL || f == CTL | OPT,
            key::TAB | key::GRAVE => f == CMD || f == CMD | SH,
            key::LEFT | key::RIGHT | key::UP | key::DOWN => f == CTL,
            key::THREE | key::FOUR | key::FIVE => f == CMD | SH || f == CMD | SH | CTL,
            key::Q => f == CMD || f == CMD | OPT || f == CMD | SH || f == CMD | CTL,
            key::H | key::M | key::W => f == CMD || f == CMD | OPT,
            _ => false,
        }
    }

    /// The events to send for `key`, recorded in `keyboard`; None when the tap
    /// lets the key go on to macOS and the app.
    pub fn route(&mut self, key: TapKey, keyboard: &mut KeyboardState) -> Option<Vec<InputEvent>> {
        if key.down {
            if !self.held_by_tap.contains(&key.key_code) && !self.takes(key.key_code, key.modifiers)
            {
                return None;
            }
            self.held_by_tap.insert(key.key_code);
            return Some(keyboard.key_down(key.key_code, key.is_repeat));
        }
        if !self.held_by_tap.remove(&key.key_code) {
            return None;
        }
        Some(keyboard.key_up(key.key_code))
    }
}

/// AppKit scroll deltas into wire `.scroll` events in hundredths, carrying
/// the sub-hundredth remainder.
#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ScrollAccumulator {
    pub remainder_x: f64,
    pub remainder_y: f64,
}

impl ScrollAccumulator {
    pub fn add(
        &mut self,
        dx: f64,
        dy: f64,
        precise: bool,
        phase_bits: u64,
        momentum_bits: u64,
    ) -> Option<InputEvent> {
        if phase_bits & (phase::BEGAN | phase::MAY_BEGIN) != 0 || momentum_bits & phase::BEGAN != 0
        {
            self.remainder_x = 0.0;
            self.remainder_y = 0.0;
        }
        let x = dx * 100.0 + self.remainder_x;
        let y = dy * 100.0 + self.remainder_y;
        let rx = x.trunc();
        let ry = y.trunc();
        self.remainder_x = x - rx;
        self.remainder_y = y - ry;
        if phase_bits & (phase::ENDED | phase::CANCELLED) != 0 || momentum_bits & phase::ENDED != 0
        {
            self.remainder_x = 0.0;
            self.remainder_y = 0.0;
        }
        if rx == 0.0 && ry == 0.0 {
            return None;
        }
        Some(InputEvent::Scroll { dx: clamp(rx), dy: clamp(ry), precise })
    }
}

fn clamp(v: f64) -> i32 {
    v.clamp(f64::from(i32::MIN), f64::from(i32::MAX)) as i32
}
