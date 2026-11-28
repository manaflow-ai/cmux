//! The dialog keyboard (CmuxDialogKeys, CmuxDialogKeys+Synthetic, CmuxDialogKeyHint) and what a
//! keycap prints (CmuxDialogKeyHint.swift's `String.keycapLegend`, `keycapText`,
//! `isModifierKeycap` and `Array.keycapStrokes`), with the spec they read (CmuxDialogSpec,
//! CmuxDialogButton, CmuxDialogField).
//!
//! Return presses the default button, Escape (or Command-period) the cancel button, Command plus
//! a button's `key` that button, Tab and Shift-Tab move focus inside the dialog only. A hint is
//! the inverse, so a button never shows a key that does not press it.

use serde::{Deserialize, Serialize};
use std::collections::HashSet;

/// A button's role (`CmuxDialogButton.Role`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Role {
    /// Return presses it; drawn prominent.
    Default,
    /// Escape presses it.
    Cancel,
    /// Drawn in the danger color.
    Destructive,
    /// Any other button.
    #[default]
    Normal,
}

fn yes() -> bool {
    true
}

/// One dialog button (`CmuxDialogButton`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Button {
    /// Stable id reported in the answer.
    pub id: String,
    /// The title.
    #[serde(default)]
    pub title: String,
    /// The role.
    #[serde(default)]
    pub role: Role,
    /// A lowercase character pressed with Command ("d" for Don't Save).
    #[serde(default, skip_serializing_if = "std::option::Option::is_none")]
    pub key: std::option::Option<String>,
    /// Only the person's own click answers it: no key presses it.
    #[serde(default)]
    pub person_only: bool,
    /// False: nothing presses it.
    #[serde(default = "yes")]
    pub is_enabled: bool,
}

impl Button {
    /// A button with `id` and `role`, enabled, no key.
    pub fn new(id: &str, role: Role) -> Self {
        Self {
            id: id.into(),
            title: String::new(),
            role,
            key: None,
            person_only: false,
            is_enabled: true,
        }
    }

    /// The same button pressed with Command plus `key`.
    pub fn with_key(mut self, key: &str) -> Self {
        self.key = Some(key.into());
        self
    }
}

/// One choice option (`CmuxDialogOption`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Option {
    /// What the list shows.
    #[serde(default)]
    pub label: String,
    /// What the answer carries.
    pub value: String,
    /// False lists it greyed out: it cannot be picked.
    #[serde(default = "yes")]
    pub is_enabled: bool,
}

/// One field (`CmuxDialogField`): only what the rules read.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum Field {
    /// One line of text.
    Text {
        /// The field id.
        id: String,
        /// The starting text.
        #[serde(default)]
        initial: String,
    },
    /// One of `options`.
    Choice {
        /// The field id.
        id: String,
        /// The options in order.
        options: Vec<Option>,
        /// The option the spec names as selected.
        #[serde(default)]
        selected: std::option::Option<String>,
    },
    /// A check box.
    Check {
        /// The field id.
        id: String,
        /// Whether it starts checked.
        #[serde(default)]
        on: bool,
    },
    /// Read-only text.
    Preview {},
    /// A read-only code.
    Code {},
    /// A line to copy, with a button that presses `id`.
    CopyLine {
        /// The in-field button's id.
        id: String,
    },
    /// A pairing code; `copyId` is its Copy button's id.
    PairingCode {
        /// The Copy button's id; none draws none.
        #[serde(default)]
        copy_id: std::option::Option<String>,
    },
    /// Work under way.
    Progress {},
    /// A caption among the fields.
    Note {},
    /// The steps of a run.
    Steps {},
}

impl Field {
    /// The value-carrying field's id (`CmuxDialogField.id`).
    pub fn id(&self) -> std::option::Option<&str> {
        match self {
            Field::Text { id, .. } | Field::Choice { id, .. } | Field::Check { id, .. } => Some(id),
            _ => None,
        }
    }

    /// The ids of the in-field buttons (`CmuxDialogField.actionIDs`).
    pub fn action_ids(&self) -> Vec<String> {
        match self {
            Field::CopyLine { id } => vec![id.clone()],
            Field::PairingCode { copy_id } => copy_id.iter().cloned().collect(),
            _ => Vec::new(),
        }
    }
}

/// Where a dialog places its buttons (`CmuxDialogSpec.Layout`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Layout {
    /// Fields above the buttons on one line (every dialog).
    #[default]
    Standard,
    /// One safe answer among destructive ones; no key glyphs.
    SafeDefault,
    /// Every button the card's width, one under another.
    Stacked,
}

impl Layout {
    /// `Layout(alertFor:)`: `safeDefault` when a button is destructive, else `standard`.
    pub fn alert_for(buttons: &[Button]) -> Self {
        if buttons.iter().any(|b| b.role == Role::Destructive) {
            Layout::SafeDefault
        } else {
            Layout::Standard
        }
    }
}

/// What a dialog asks (`CmuxDialogSpec`): only what the rules read.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Spec {
    /// The title.
    #[serde(default)]
    pub title: String,
    /// One short sentence per line.
    #[serde(default)]
    pub lines: Vec<String>,
    /// The fields in order.
    #[serde(default)]
    pub fields: Vec<Field>,
    /// The buttons, left to right.
    #[serde(default)]
    pub buttons: Vec<Button>,
    /// The dialog's accessibility identifier.
    #[serde(default)]
    pub identifier: std::option::Option<String>,
    /// Where the buttons go.
    #[serde(default)]
    pub layout: Layout,
}

impl Spec {
    /// A spec with these buttons and nothing else.
    pub fn with_buttons(buttons: Vec<Button>) -> Self {
        Self { buttons, ..Self::default() }
    }

    /// The button Return presses: the first enabled, non-person-only `default`.
    pub fn default_button(&self) -> std::option::Option<&Button> {
        self.buttons.iter().find(|b| b.role == Role::Default && !b.person_only && b.is_enabled)
    }

    /// The button Escape presses: the first `cancel`, else the only button; never a
    /// person-only or disabled one.
    pub fn cancel_button(&self) -> std::option::Option<&Button> {
        let candidate = self
            .buttons
            .iter()
            .find(|b| b.role == Role::Cancel)
            .or(if self.buttons.len() == 1 { self.buttons.first() } else { None });
        candidate.filter(|b| !b.person_only && b.is_enabled)
    }
}

/// The ids Return and Escape press.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KeyButtons {
    /// Return's button.
    pub default_button: std::option::Option<String>,
    /// Escape's button.
    pub cancel_button: std::option::Option<String>,
}

impl KeyButtons {
    /// Return's and Escape's buttons in `spec`.
    pub fn of(spec: &Spec) -> Self {
        Self {
            default_button: spec.default_button().map(|b| b.id.clone()),
            cancel_button: spec.cancel_button().map(|b| b.id.clone()),
        }
    }
}

/// A dialog key (`CmuxDialogKeys.Key`). JSON: `"return"`, `"escape"`, `"tab"`, else the character.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(from = "String", into = "String")]
pub enum Key {
    /// Return (or Enter).
    Return,
    /// Escape.
    Escape,
    /// Tab.
    Tab,
    /// Any other key, by its character.
    Character(String),
}

impl From<String> for Key {
    fn from(s: String) -> Self {
        match s.as_str() {
            "return" => Key::Return,
            "escape" => Key::Escape,
            "tab" => Key::Tab,
            _ => Key::Character(s),
        }
    }
}

impl From<Key> for String {
    fn from(k: Key) -> Self {
        match k {
            Key::Return => "return".into(),
            Key::Escape => "escape".into(),
            Key::Tab => "tab".into(),
            Key::Character(c) => c,
        }
    }
}

/// Held modifiers (`CmuxDialogKeys.Modifiers`): the same bits as Swift's raw value.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Modifiers(pub u32);

impl Modifiers {
    /// None.
    pub const NONE: Self = Self(0);
    /// Command.
    pub const COMMAND: Self = Self(1 << 0);
    /// Shift.
    pub const SHIFT: Self = Self(1 << 1);
    /// Option.
    pub const OPTION: Self = Self(1 << 2);
    /// Control.
    pub const CONTROL: Self = Self(1 << 3);

    /// Whether every bit of `other` is held.
    pub fn contains(self, other: Self) -> bool {
        self.0 & other.0 == other.0
    }

    /// These less `other`.
    pub fn subtracting(self, other: Self) -> Self {
        Self(self.0 & !other.0)
    }

    /// These and `other`.
    pub fn union(self, other: Self) -> Self {
        Self(self.0 | other.0)
    }
}

/// What a key does in a dialog (`CmuxDialogKeys.Action`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Action {
    /// Press the button `id`.
    Press {
        /// The button id.
        id: String,
    },
    /// Move focus forward.
    FocusNext,
    /// Move focus back.
    FocusPrevious,
}

fn press(button: std::option::Option<&Button>) -> std::option::Option<Action> {
    button.map(|b| Action::Press { id: b.id.clone() })
}

/// `CmuxDialogKeys.action(for:modifiers:in:)`: none lets the key reach the focused control.
pub fn action(key: &Key, modifiers: Modifiers, spec: &Spec) -> std::option::Option<Action> {
    let others = modifiers.subtracting(Modifiers::SHIFT);
    match key {
        Key::Return => {
            if others == Modifiers::NONE || others == Modifiers::COMMAND {
                press(spec.default_button())
            } else {
                None
            }
        }
        Key::Escape => press(spec.cancel_button()),
        Key::Tab => {
            if others != Modifiers::NONE {
                None
            } else if modifiers.contains(Modifiers::SHIFT) {
                Some(Action::FocusPrevious)
            } else {
                Some(Action::FocusNext)
            }
        }
        Key::Character(character) => {
            if others != Modifiers::COMMAND {
                return None;
            }
            if character == "." {
                return press(spec.cancel_button());
            }
            let lowered = character.to_lowercase();
            press(spec.buttons.iter().find(|b| {
                b.key.as_deref() == Some(lowered.as_str()) && !b.person_only && b.is_enabled
            }))
        }
    }
}

/// The key a button shows (`CmuxDialogKeyHint`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum KeyHint {
    /// Return presses it.
    Return,
    /// Escape presses it.
    Escape,
    /// Command plus `character` presses it.
    Command {
        /// The lowercase character.
        character: String,
    },
}

impl KeyHint {
    /// The keycap text: `return`, `esc`, `⌘D`.
    pub fn glyph(&self) -> String {
        match self {
            KeyHint::Return => keycap_legend("↩"),
            KeyHint::Escape => keycap_legend("⎋"),
            KeyHint::Command { character } => format!("⌘{}", character.to_uppercase()),
        }
    }

    /// The dialog key it names.
    pub fn key(&self) -> Key {
        match self {
            KeyHint::Return => Key::Return,
            KeyHint::Escape => Key::Escape,
            KeyHint::Command { character } => Key::Character(character.clone()),
        }
    }

    /// The modifiers held with [`Self::key`].
    pub fn modifiers(&self) -> Modifiers {
        match self {
            KeyHint::Command { .. } => Modifiers::COMMAND,
            _ => Modifiers::NONE,
        }
    }

    /// `NSButton.keyEquivalent`.
    pub fn key_equivalent(&self) -> String {
        match self {
            KeyHint::Return => "\r".into(),
            KeyHint::Escape => "\u{1b}".into(),
            KeyHint::Command { character } => character.clone(),
        }
    }
}

/// A hint with everything the button draws from it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HintReply {
    /// The hint.
    pub hint: KeyHint,
    /// Its keycap text.
    pub glyph: String,
    /// The key that presses it.
    pub key: Key,
    /// Held with `key`.
    pub modifiers: Modifiers,
    /// `NSButton.keyEquivalent`.
    pub key_equivalent: String,
}

impl From<KeyHint> for HintReply {
    fn from(hint: KeyHint) -> Self {
        Self {
            glyph: hint.glyph(),
            key: hint.key(),
            modifiers: hint.modifiers(),
            key_equivalent: hint.key_equivalent(),
            hint,
        }
    }
}

/// `CmuxDialogKeys.hint(for:in:)`: the inverse of [`action`].
pub fn hint(button: &Button, spec: &Spec) -> std::option::Option<KeyHint> {
    if spec.default_button().map(|b| &b.id) == Some(&button.id) {
        return Some(KeyHint::Return);
    }
    if spec.cancel_button().map(|b| &b.id) == Some(&button.id) {
        return Some(KeyHint::Escape);
    }
    let key = button.key.as_ref()?;
    if button.person_only {
        return None;
    }
    let first = spec.buttons.iter().find(|b| b.key.as_ref() == Some(key))?;
    (first.id == button.id).then(|| KeyHint::Command { character: key.clone() })
}

/// `CmuxDialogPresentation.hint(for:)`: none in the `safeDefault` layout, which draws no key glyphs.
pub fn shown_hint(button: &Button, spec: &Spec) -> std::option::Option<KeyHint> {
    if spec.layout == Layout::SafeDefault { None } else { hint(button, spec) }
}

/// `focus` request.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FocusRequest {
    /// The focused control, if any.
    #[serde(default)]
    pub current: std::option::Option<i64>,
    /// How many controls.
    pub count: i64,
    /// Shift-Tab.
    #[serde(default)]
    pub backward: bool,
}

/// `action` request.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActionRequest {
    /// The key.
    pub key: Key,
    /// Held modifiers.
    #[serde(default)]
    pub modifiers: Modifiers,
    /// The dialog.
    pub spec: Spec,
}

/// `CmuxDialogKeys.focus(after:count:backward:)`: the control after (or before) `current`,
/// wrapping; with none focused, the first (or last).
pub fn focus(
    current: std::option::Option<i64>,
    count: i64,
    backward: bool,
) -> std::option::Option<i64> {
    if count <= 0 {
        return None;
    }
    match current {
        Some(c) if (0..count).contains(&c) => {
            Some(if backward { (c + count - 1) % count } else { (c + 1) % count })
        }
        _ => Some(if backward { count - 1 } else { 0 }),
    }
}

/// `String.keycapLegend`: the named keys as words, every other key as it is.
pub fn keycap_legend(key: &str) -> String {
    match key {
        "↩" | "⏎" | "↵" | "⌅" | "\r" => "return",
        "⇥" | "\t" => "tab",
        "⎋" | "Esc" | "ESC" | "\u{1B}" => "esc",
        "⌫" | "⌦" | "\u{8}" | "\u{7F}" => "delete",
        _ => key,
    }
    .to_string()
}

/// `String.keycapText`: a whole shortcut, each named key as its word, a space between the
/// modifiers and a word ("⌘ return").
pub fn keycap_text(text: &str) -> String {
    let legend = keycap_legend(text);
    if legend != text {
        return legend;
    }
    let mut out = String::new();
    for character in text.chars() {
        let single = character.to_string();
        let word = keycap_legend(&single);
        if word != single && !out.is_empty() && !out.ends_with(' ') {
            out.push(' ');
        }
        out.push_str(&word);
    }
    out
}

/// `String.isModifierKeycap`.
pub fn is_modifier_keycap(key: &str) -> bool {
    matches!(key, "⌃" | "⌥" | "⇧" | "⌘" | "fn")
}

/// `Array.keycapStrokes`: a stroke runs through its modifiers to its first other key.
pub fn keycap_strokes(keys: &[String]) -> Vec<Vec<String>> {
    let mut strokes = Vec::new();
    let mut current = Vec::new();
    for key in keys {
        current.push(key.clone());
        if !is_modifier_keycap(key) {
            strokes.push(std::mem::take(&mut current));
        }
    }
    if !current.is_empty() {
        strokes.push(current);
    }
    strokes
}

/// A key and its modifiers.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KeyPress {
    /// The key.
    pub key: Key,
    /// Held modifiers.
    pub modifiers: Modifiers,
}

/// `CmuxDialogKeys.named(_:)`: `return`, `escape`, `tab`, `shift-tab`, `cmd-<c>`.
pub fn named(name: &str) -> std::option::Option<(Key, Modifiers)> {
    match name {
        "return" => Some((Key::Return, Modifiers::NONE)),
        "escape" => Some((Key::Escape, Modifiers::NONE)),
        "tab" => Some((Key::Tab, Modifiers::NONE)),
        "shift-tab" => Some((Key::Tab, Modifiers::SHIFT)),
        _ => {
            let rest = name.strip_prefix("cmd-")?;
            let mut chars = rest.chars();
            let character = chars.next()?;
            chars
                .next()
                .is_none()
                .then(|| (Key::Character(character.to_string()), Modifiers::COMMAND))
        }
    }
}

/// `eventKey` request: an `NSEvent`'s key code, `charactersIgnoringModifiers` and raw flags.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EventRequest {
    /// `NSEvent.keyCode`.
    pub key_code: u16,
    /// `NSEvent.charactersIgnoringModifiers`.
    #[serde(default)]
    pub characters: std::option::Option<String>,
    /// `NSEvent.modifierFlags.rawValue`.
    #[serde(default)]
    pub modifier_flags: u64,
}

/// An event's dialog key (none for an empty key) and modifiers.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EventKey {
    /// The key, none when the event carries no character.
    pub key: std::option::Option<Key>,
    /// Held modifiers.
    pub modifiers: Modifiers,
}

/// `NSEvent.ModifierFlags` bits.
const NS_SHIFT: u64 = 1 << 17;
const NS_CONTROL: u64 = 1 << 18;
const NS_OPTION: u64 = 1 << 19;
const NS_COMMAND: u64 = 1 << 20;

/// `CmuxDialogPresentation.key(_:)` and `.modifiers(_:)`: key codes 36 and 76 are Return, 53
/// Escape, 48 Tab, else the first character.
pub fn event_key(key_code: u16, characters: std::option::Option<&str>, flags: u64) -> EventKey {
    let key = match key_code {
        36 | 76 => Some(Key::Return),
        53 => Some(Key::Escape),
        48 => Some(Key::Tab),
        _ => characters.and_then(|c| c.chars().next()).map(|c| Key::Character(c.to_string())),
    };
    let mut modifiers = Modifiers::NONE;
    for (bit, modifier) in [
        (NS_COMMAND, Modifiers::COMMAND),
        (NS_SHIFT, Modifiers::SHIFT),
        (NS_OPTION, Modifiers::OPTION),
        (NS_CONTROL, Modifiers::CONTROL),
    ] {
        if flags & bit != 0 {
            modifiers = modifiers.union(modifier);
        }
    }
    EventKey { key, modifiers }
}

/// One shown dialog as the synthetic-input rule sees it (`CmuxDialogCenter.Record`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Record {
    /// Whether it shows.
    pub visible: bool,
    /// Its spec's identifier.
    #[serde(default)]
    pub identifier: std::option::Option<String>,
}

/// `syntheticInputRefusal` request.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RefusalRequest {
    /// The shown dialogs.
    pub records: Vec<Record>,
    /// The identifiers that answer only to the person.
    pub user_only: HashSet<String>,
    /// Whether the input only cancels or reads.
    pub only_cancels: bool,
}

/// The refusal [`synthetic_input_refusal`] gives.
pub const SYNTHETIC_REFUSAL: &str =
    "a dialog that answers only to the user is open: synthetic input may only cancel it (Escape)";

/// `CmuxDialogKeys.syntheticInputRefusal`: synthetic input while a user-only dialog shows is
/// refused, unless it only cancels.
pub fn synthetic_input_refusal(
    records: &[Record],
    user_only: &HashSet<String>,
    only_cancels: bool,
) -> std::option::Option<&'static str> {
    let blocked = records
        .iter()
        .any(|r| r.visible && r.identifier.as_ref().is_some_and(|id| user_only.contains(id)));
    (!only_cancels && blocked).then_some(SYNTHETIC_REFUSAL)
}

/// `onlyCancels` request.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OnlyCancelsRequest {
    /// The named key.
    #[serde(default)]
    pub key: std::option::Option<String>,
    /// The raw modifiers.
    #[serde(default)]
    pub modifiers: i64,
    /// Whether it sends a sequence.
    #[serde(default)]
    pub sequence: bool,
    /// Whether it only reads.
    #[serde(default)]
    pub read: bool,
}

/// `CmuxDialogKeys.onlyCancels`: a bare Escape, or a read.
pub fn only_cancels(
    key: std::option::Option<&str>,
    modifiers: i64,
    sequence: bool,
    read: bool,
) -> bool {
    read || (!sequence && key == Some("escape") && modifiers == 0)
}
