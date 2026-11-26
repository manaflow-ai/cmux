//! Dialogs: CmuxNextDesign/Dialog and CmuxNextDesignTokens/Dialog.
//!
//! The rules every cmux dialog shares, with no AppKit: which key presses which button
//! ([`keys`]), what a keycap prints ([`keys::keycap_legend`]), a shown dialog's field values
//! ([`values`]), the keycap styles and the dialog metrics ([`keycap`]), and the floating
//! panel's drag rule ([`panel`]). The app keeps the drawing.
//!
//! Ops: `dialog.NAME` (see [`call`]). Every request and reply is camelCase JSON.

pub mod keycap;
pub mod keys;
pub mod panel;
pub mod values;

use crate::ops::{OpError, OpResult, parse, reply};
use serde::Deserialize;
use serde_json::Value;

pub use keycap::{KeycapLook, KeycapStyle, Metrics};
pub use keys::{
    Action, Button, Field, Key, KeyHint, Layout, Modifiers, Option as DialogOption, Role, Spec,
};
pub use values::{StepState, Value as DialogValue};

/// Runs `dialog.NAME`.
///
/// | op | request | reply |
/// |---|---|---|
/// | `action` | `{key, modifiers, spec}` | an [`Action`] or null |
/// | `hint` | `{button, spec}` | a [`keys::HintReply`] or null |
/// | `shownHint` | `{button, spec}` | as `hint`, null in the `safeDefault` layout |
/// | `keyButtons` | `{spec}` | `{defaultButton, cancelButton}` (ids or null) |
/// | `focus` | `{current, count, backward}` | an index or null |
/// | `layoutFor` | `{buttons}` | `"standard"` or `"safeDefault"` |
/// | `keycapLegend` | `{text}` | the legend |
/// | `keycapText` | `{text}` | the keycap text |
/// | `isModifierKeycap` | `{text}` | bool |
/// | `keycapStrokes` | `{keys}` | the strokes |
/// | `named` | `{name}` | `{key, modifiers}` or null |
/// | `eventKey` | `{keyCode, characters, modifierFlags}` | `{key, modifiers}` |
/// | `syntheticInputRefusal` | `{records, userOnly, onlyCancels}` | the refusal or null |
/// | `onlyCancels` | `{key, modifiers, sequence, read}` | bool |
/// | `initialValues` | `{spec}` | the values by field id |
/// | `accepts` | `{spec, id, value}` | bool |
/// | `edit` | `{spec, values, edits}` | `{values, changed}` |
/// | `pressable` | `{spec, id}` | bool |
/// | `actionIds` | `{field}` | the ids |
/// | `pairingCountdown` | `{until, now}` (seconds) | `{clock, urgent}` |
/// | `stepLook` | `{state}` | a [`values::StepLook`] |
/// | `linesScroll` | `{lines}` | bool |
/// | `keycapStyles` | `{}` | every style, playground order |
/// | `keycapLook` | `{style, userScale, buttonCornerRadius}` | a [`KeycapLook`] |
/// | `keycapShowsKey` | `{style, role}` | bool |
/// | `keycapCornerRadius` | `{style, width, height, userScale, buttonCornerRadius}` | the corner |
/// | `metrics` | `{userScale, buttonCornerRadius}` | the [`Metrics`] |
/// | `startsDrag` | `{inCard, chain}` | bool |
pub fn call(name: &str, request: &Value) -> OpResult {
    match name {
        "action" => {
            let r: keys::ActionRequest = parse(request)?;
            reply(&keys::action(&r.key, r.modifiers, &r.spec))
        }
        "hint" => {
            let r: ButtonInSpec = parse(request)?;
            reply(&keys::hint(&r.button, &r.spec).map(keys::HintReply::from))
        }
        "shownHint" => {
            let r: ButtonInSpec = parse(request)?;
            reply(&keys::shown_hint(&r.button, &r.spec).map(keys::HintReply::from))
        }
        "keyButtons" => {
            let r: SpecOnly = parse(request)?;
            reply(&keys::KeyButtons::of(&r.spec))
        }
        "focus" => {
            let r: keys::FocusRequest = parse(request)?;
            reply(&keys::focus(r.current, r.count, r.backward))
        }
        "layoutFor" => {
            let r: ButtonsOnly = parse(request)?;
            reply(&Layout::alert_for(&r.buttons))
        }
        "keycapLegend" => reply(&keys::keycap_legend(&parse::<Text>(request)?.text)),
        "keycapText" => reply(&keys::keycap_text(&parse::<Text>(request)?.text)),
        "isModifierKeycap" => reply(&keys::is_modifier_keycap(&parse::<Text>(request)?.text)),
        "keycapStrokes" => {
            let r: KeysOnly = parse(request)?;
            reply(&keys::keycap_strokes(&r.keys))
        }
        "named" => {
            let r: NameOnly = parse(request)?;
            reply(&keys::named(&r.name).map(|(key, modifiers)| keys::KeyPress { key, modifiers }))
        }
        "eventKey" => {
            let r: keys::EventRequest = parse(request)?;
            reply(&keys::event_key(r.key_code, r.characters.as_deref(), r.modifier_flags))
        }
        "syntheticInputRefusal" => {
            let r: keys::RefusalRequest = parse(request)?;
            reply(&keys::synthetic_input_refusal(&r.records, &r.user_only, r.only_cancels))
        }
        "onlyCancels" => {
            let r: keys::OnlyCancelsRequest = parse(request)?;
            reply(&keys::only_cancels(r.key.as_deref(), r.modifiers, r.sequence, r.read))
        }
        "initialValues" => reply(&values::initial_values(&parse::<SpecOnly>(request)?.spec)),
        "accepts" => {
            let r: values::AcceptsRequest = parse(request)?;
            reply(&values::accepts(&r.spec, &r.id, &r.value))
        }
        "edit" => {
            let r: values::EditRequest = parse(request)?;
            reply(&values::edit(&r.spec, r.values, &r.edits))
        }
        "pressable" => {
            let r: values::PressableRequest = parse(request)?;
            reply(&values::pressable(&r.spec, &r.id))
        }
        "actionIds" => {
            let r: FieldOnly = parse(request)?;
            reply(&r.field.action_ids())
        }
        "pairingCountdown" => {
            let r: values::CountdownRequest = parse(request)?;
            reply(&values::pairing_countdown(r.until, r.now))
        }
        "stepLook" => {
            let r: values::StepRequest = parse(request)?;
            reply(&values::step_look(r.state))
        }
        "linesScroll" => {
            let r: values::LinesRequest = parse(request)?;
            reply(&values::lines_scroll(&r.lines))
        }
        "keycapStyles" => reply(&KeycapStyle::ALL),
        "keycapLook" => {
            let r: keycap::StyleRequest = parse(request)?;
            reply(&r.style.look(r.user_scale, r.button_corner_radius))
        }
        "keycapShowsKey" => {
            let r: keycap::ShowsKeyRequest = parse(request)?;
            reply(&r.style.shows_key(r.role))
        }
        "keycapCornerRadius" => {
            let r: keycap::CornerRequest = parse(request)?;
            reply(&r.style.corner_radius(r.width, r.height, r.user_scale, r.button_corner_radius))
        }
        "metrics" => {
            let r: keycap::MetricsRequest = parse(request)?;
            reply(&Metrics::new(r.user_scale, r.button_corner_radius))
        }
        "startsDrag" => {
            let r: panel::DragRequest = parse(request)?;
            reply(&panel::starts_drag(r.in_card, &r.chain))
        }
        _ => Err(OpError::Unknown),
    }
}

#[derive(Deserialize)]
struct ButtonInSpec {
    button: Button,
    spec: Spec,
}

#[derive(Deserialize)]
struct SpecOnly {
    spec: Spec,
}

#[derive(Deserialize)]
struct ButtonsOnly {
    buttons: Vec<Button>,
}

#[derive(Deserialize)]
struct Text {
    text: String,
}

#[derive(Deserialize)]
struct KeysOnly {
    keys: Vec<String>,
}

#[derive(Deserialize)]
struct NameOnly {
    name: String,
}

#[derive(Deserialize)]
struct FieldOnly {
    field: Field,
}
