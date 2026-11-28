//! A shown dialog's field values (CmuxDialogPresentation: `initialValues`, `accepts`, `edited`,
//! `press`'s guard), the pairing code's countdown (`CmuxDialogPairingCode.clock` and the
//! last-minute ink in CmuxDialogView+ReadOnlyFields), a step's look (`CmuxDialogStep.State`)
//! and when a message scrolls (CmuxDialogView's lines box).

use super::keys::{Field, Spec};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// A field's value (`CmuxDialogValue`): `{"text": "…"}` or `{"bool": true}`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Value {
    /// A text or choice field's value.
    Text(String),
    /// A check box's value.
    Bool(bool),
}

/// Every field's value by field id.
pub type Values = BTreeMap<String, Value>;

/// `CmuxDialogPresentation.initialValues`: a choice starts on its selected option when that one
/// is enabled, else on the first enabled one, else "".
pub fn initial_values(spec: &Spec) -> Values {
    let mut values = Values::new();
    for field in &spec.fields {
        match field {
            Field::Text { id, initial } => {
                values.insert(id.clone(), Value::Text(initial.clone()));
            }
            Field::Choice { id, options, selected } => {
                let mut enabled = options.iter().filter(|o| o.is_enabled);
                let picked = selected
                    .as_ref()
                    .and_then(|s| options.iter().find(|o| o.is_enabled && &o.value == s))
                    .or_else(|| enabled.next())
                    .map(|o| o.value.clone())
                    .unwrap_or_default();
                values.insert(id.clone(), Value::Text(picked));
            }
            Field::Check { id, on } => {
                values.insert(id.clone(), Value::Bool(*on));
            }
            _ => {}
        }
    }
    values
}

/// `CmuxDialogPresentation.accepts`: the first field with `id` takes a value of its kind; a
/// choice only one of its enabled options.
pub fn accepts(spec: &Spec, id: &str, value: &Value) -> bool {
    let Some(field) = spec.fields.iter().find(|f| f.id() == Some(id)) else {
        return false;
    };
    match (field, value) {
        (Field::Text { .. }, Value::Text(_)) => true,
        (Field::Choice { options, .. }, Value::Text(picked)) => {
            options.iter().any(|o| &o.value == picked && o.is_enabled)
        }
        (Field::Check { .. }, Value::Bool(_)) => true,
        _ => false,
    }
}

/// `edit` reply.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Edited {
    /// The values after the edits.
    pub values: Values,
    /// Whether any changed (the host's `onEdit` hears it).
    pub changed: bool,
}

/// `CmuxDialogPresentation.edited`: the edits the spec accepts, and whether any changed.
pub fn edit(spec: &Spec, mut values: Values, edits: &Values) -> Edited {
    let before = values.clone();
    for (id, value) in edits {
        if accepts(spec, id, value) {
            values.insert(id.clone(), value.clone());
        }
    }
    let changed = values != before;
    Edited { values, changed }
}

/// `press`'s guard: the dialog has a button `id`, or a field whose in-field button is `id`.
pub fn pressable(spec: &Spec, id: &str) -> bool {
    spec.buttons.iter().any(|b| b.id == id)
        || spec.fields.iter().any(|f| f.action_ids().iter().any(|a| a == id))
}

/// `accepts` request.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AcceptsRequest {
    /// The dialog.
    pub spec: Spec,
    /// The field id.
    pub id: String,
    /// The value.
    pub value: Value,
}

/// `edit` request.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EditRequest {
    /// The dialog.
    pub spec: Spec,
    /// The current values.
    #[serde(default)]
    pub values: Values,
    /// The person's edits.
    #[serde(default)]
    pub edits: Values,
}

/// `pressable` request.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PressableRequest {
    /// The dialog.
    pub spec: Spec,
    /// The pressed id.
    pub id: String,
}

/// The countdown line's text and ink.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Countdown {
    /// `9:41`.
    pub clock: String,
    /// Under a minute left: the attention (danger) ink.
    pub urgent: bool,
}

/// `pairingCountdown` request: both in seconds on one clock.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CountdownRequest {
    /// When the code stops working.
    pub until: f64,
    /// Now.
    pub now: f64,
}

/// `CmuxDialogPairingCode.clock(until:now:)`: `m:ss` for the seconds left, rounded up, never
/// below zero.
pub fn pairing_clock(until: f64, now: f64) -> String {
    let left = ((until - now).ceil() as i64).max(0);
    format!("{}:{:02}", left / 60, left % 60)
}

/// The countdown's clock and whether it is in its last minute (`until - now < 60`).
pub fn pairing_countdown(until: f64, now: f64) -> Countdown {
    Countdown { clock: pairing_clock(until, now), urgent: until - now < 60.0 }
}

/// A step's state (`CmuxDialogStep.State`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum StepState {
    /// Not started.
    Pending,
    /// Under way.
    Running,
    /// Done.
    Done,
    /// Done with a warning.
    Warning,
    /// Failed.
    Failed,
    /// Skipped.
    Skipped,
}

/// The sidebar glyph a step draws.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum StepGlyph {
    /// Idle.
    Idle,
    /// Spinning.
    Busy,
    /// Done.
    Success,
    /// Waiting.
    Waiting,
    /// Error.
    Error,
}

/// A text ink role.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum InkRole {
    /// Primary text.
    Primary,
    /// Secondary text.
    Secondary,
    /// The danger ink.
    Danger,
}

/// How a step row draws (CmuxDialogView+ReadOnlyFields' step row).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StepLook {
    /// The state's glyph.
    pub glyph: StepGlyph,
    /// The title's ink.
    pub title_role: InkRole,
    /// The fix line's ink.
    pub fix_role: InkRole,
}

/// `stepLook` request.
#[derive(Deserialize)]
pub struct StepRequest {
    /// The step's state.
    pub state: StepState,
}

/// A step row's glyph and inks: pending and skipped read idle and secondary, a failed step's fix
/// the danger ink.
pub fn step_look(state: StepState) -> StepLook {
    let glyph = match state {
        StepState::Pending | StepState::Skipped => StepGlyph::Idle,
        StepState::Running => StepGlyph::Busy,
        StepState::Done => StepGlyph::Success,
        StepState::Warning => StepGlyph::Waiting,
        StepState::Failed => StepGlyph::Error,
    };
    let title_role = match state {
        StepState::Pending | StepState::Skipped => InkRole::Secondary,
        _ => InkRole::Primary,
    };
    let fix_role = if state == StepState::Failed { InkRole::Danger } else { InkRole::Secondary };
    StepLook { glyph, title_role, fix_role }
}

/// A message past this many lines scrolls (`CmuxDialogMetrics.scrollingLineCount`).
pub const SCROLLING_LINE_COUNT: usize = 8;
/// A message past this many characters scrolls (`CmuxDialogMetrics.scrollingCharacterCount`).
pub const SCROLLING_CHARACTER_COUNT: usize = 600;

/// `linesScroll` request.
#[derive(Deserialize)]
pub struct LinesRequest {
    /// The spec's lines.
    pub lines: Vec<String>,
}

/// Whether a dialog's message scrolls in a box: more than 8 lines or 600 characters.
pub fn lines_scroll(lines: &[String]) -> bool {
    lines.len() > SCROLLING_LINE_COUNT
        || lines.iter().map(|l| character_count(l)).sum::<usize>() > SCROLLING_CHARACTER_COUNT
}

/// Swift's `String.count` (extended grapheme clusters), close enough for a length threshold
/// without a segmentation table: a scalar that extends the one before it (a combining mark, a
/// variation selector, a skin tone, a tag, the scalar after a zero-width joiner, `\n` after
/// `\r`) does not count.
pub fn character_count(text: &str) -> usize {
    let mut count = 0;
    let mut previous: Option<char> = None;
    for c in text.chars() {
        let joins = previous == Some('\u{200D}') || (previous == Some('\r') && c == '\n');
        if !(joins || extends(c)) {
            count += 1;
        }
        previous = Some(c);
    }
    count
}

fn extends(c: char) -> bool {
    matches!(c as u32,
        0x0300..=0x036F | 0x1AB0..=0x1AFF | 0x1DC0..=0x1DFF | 0x20D0..=0x20FF | 0xFE20..=0xFE2F
        | 0xFE00..=0xFE0F | 0x200D | 0x1F3FB..=0x1F3FF | 0xE0020..=0xE007F | 0xE0100..=0xE01EF)
}
