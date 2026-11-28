//! Parity with the Swift dialog rules: DialogKeyHintTests, KeycapPlaygroundTests,
//! KeycapChipConcentricTests, CmuxDialogDisabledOptionTests and RemoteConfirmUserOnlyTests (the
//! pure parts) value for value, plus pins of today's Swift outputs (keys, metrics, keycap styles,
//! values, steps, countdown, drag), through `ops::call("dialog.*")`.

use cmux_design_core::dialog::keycap::{GlyphWeight, KeycapStyle, Metrics};
use cmux_design_core::dialog::keys::{
    self, Action, Button, Field, Key, KeyHint, Layout, Modifiers, Record, Role, Spec,
};
use cmux_design_core::dialog::panel::{ViewKind, starts_drag};
use cmux_design_core::dialog::values::{self, InkRole, StepGlyph, StepState, Value as V, Values};
use cmux_design_core::ops::{OpError, call};
use serde_json::{Value, json};
use std::collections::HashSet;

fn op(name: &str, request: Value) -> Value {
    call(&format!("dialog.{name}"), &request).unwrap_or_else(|e| panic!("dialog.{name}: {e:?}"))
}

fn button(id: &str, role: Role) -> Button {
    Button::new(id, role)
}

/// DialogKeyHintTests' four specs.
fn approval() -> Spec {
    Spec::with_buttons(vec![button("cancel", Role::Cancel), button("change", Role::Default)])
}
fn unsaved() -> Spec {
    Spec::with_buttons(vec![
        button("discard", Role::Destructive).with_key("d"),
        button("cancel", Role::Cancel),
        button("save", Role::Default),
    ])
}
fn notice() -> Spec {
    Spec::with_buttons(vec![button("close", Role::Normal)])
}
fn ok() -> Spec {
    Spec::with_buttons(vec![button("ok", Role::Default)])
}

fn hints(spec: &Spec) -> Vec<Option<KeyHint>> {
    spec.buttons.iter().map(|b| keys::hint(b, spec)).collect()
}

// MARK: DialogKeyHintTests

#[test]
fn hints_match_swift() {
    assert_eq!(hints(&approval()), vec![Some(KeyHint::Escape), Some(KeyHint::Return)]);
    assert_eq!(
        hints(&unsaved()),
        vec![
            Some(KeyHint::Command { character: "d".into() }),
            Some(KeyHint::Escape),
            Some(KeyHint::Return)
        ]
    );
    assert_eq!(hints(&notice()), vec![Some(KeyHint::Escape)]);
    assert_eq!(hints(&ok()), vec![Some(KeyHint::Return)]);
}

#[test]
fn hint_glyphs() {
    assert_eq!(KeyHint::Escape.glyph(), "esc");
    assert_eq!(KeyHint::Return.glyph(), "return");
    assert_eq!(KeyHint::Command { character: "d".into() }.glyph(), "⌘D");
    assert_eq!(KeyHint::Return.key_equivalent(), "\r");
    assert_eq!(KeyHint::Escape.key_equivalent(), "\u{1b}");
}

#[test]
fn every_shown_key_presses_its_button() {
    for spec in [approval(), unsaved(), notice(), ok()] {
        for b in &spec.buttons {
            let Some(hint) = keys::hint(b, &spec) else { continue };
            assert_eq!(
                keys::action(&hint.key(), hint.modifiers(), &spec),
                Some(Action::Press { id: b.id.clone() }),
                "{}",
                b.id
            );
        }
    }
}

#[test]
fn keycap_legend_and_text() {
    for named in ["↩", "⏎", "↵", "\r"] {
        assert_eq!(keys::keycap_legend(named), "return");
        assert_eq!(keys::keycap_text(named), "return");
    }
    assert_eq!(keys::keycap_legend("⇥"), "tab");
    assert_eq!(keys::keycap_legend("⎋"), "esc");
    assert_eq!(keys::keycap_legend("Esc"), "esc");
    assert_eq!(keys::keycap_legend("⌫"), "delete");
    for plain in ["⌘", "⌥", "⌃", "⇧", "J", ",", "1…9"] {
        assert_eq!(keys::keycap_legend(plain), plain);
        assert_eq!(keys::keycap_text(plain), plain);
    }
    assert_eq!(keys::keycap_text("⌘↩"), "⌘ return");
    assert_eq!(keys::keycap_text("⇧⇥"), "⇧ tab");
    assert_eq!(keys::keycap_text("⇧⌘P"), "⇧⌘P");
    assert_eq!(op("keycapText", json!({"text": "⌘↩"})), json!("⌘ return"));
    assert_eq!(op("keycapLegend", json!({"text": "⌫"})), json!("delete"));
    assert_eq!(op("isModifierKeycap", json!({"text": "⌥"})), json!(true));
    assert_eq!(op("isModifierKeycap", json!({"text": "J"})), json!(false));
}

#[test]
fn keycap_strokes() {
    let s = |v: &[&str]| v.iter().map(|k| k.to_string()).collect::<Vec<_>>();
    assert_eq!(keys::keycap_strokes(&s(&["⌘", "J", "S"])), vec![s(&["⌘", "J"]), s(&["S"])]);
    assert_eq!(keys::keycap_strokes(&s(&["⇧", "⌘", "P"])), vec![s(&["⇧", "⌘", "P"])]);
    assert_eq!(
        keys::keycap_strokes(&s(&["⌃", "B", "⌥", "1…9"])),
        vec![s(&["⌃", "B"]), s(&["⌥", "1…9"])]
    );
    assert_eq!(op("keycapStrokes", json!({"keys": ["⌘", "J", "S"]})), json!([["⌘", "J"], ["S"]]));
}

// MARK: Keys (pins)

#[test]
fn key_actions() {
    let spec = unsaved();
    let press = |id: &str| Some(Action::Press { id: id.into() });
    assert_eq!(keys::action(&Key::Return, Modifiers::NONE, &spec), press("save"));
    assert_eq!(keys::action(&Key::Return, Modifiers::COMMAND, &spec), press("save"));
    assert_eq!(keys::action(&Key::Return, Modifiers::SHIFT, &spec), press("save"));
    assert_eq!(keys::action(&Key::Return, Modifiers::OPTION, &spec), None);
    assert_eq!(keys::action(&Key::Escape, Modifiers::NONE, &spec), press("cancel"));
    assert_eq!(keys::action(&Key::Tab, Modifiers::NONE, &spec), Some(Action::FocusNext));
    assert_eq!(keys::action(&Key::Tab, Modifiers::SHIFT, &spec), Some(Action::FocusPrevious));
    assert_eq!(keys::action(&Key::Tab, Modifiers::CONTROL, &spec), None);
    let ch = |c: &str| Key::Character(c.into());
    assert_eq!(keys::action(&ch("d"), Modifiers::COMMAND, &spec), press("discard"));
    assert_eq!(
        keys::action(&ch("D"), Modifiers::COMMAND.union(Modifiers::SHIFT), &spec),
        press("discard")
    );
    assert_eq!(keys::action(&ch("."), Modifiers::COMMAND, &spec), press("cancel"));
    assert_eq!(keys::action(&ch("d"), Modifiers::NONE, &spec), None);
    assert_eq!(keys::action(&ch("x"), Modifiers::COMMAND, &spec), None);

    let mut person = unsaved();
    person.buttons[2].person_only = true;
    person.buttons[0].is_enabled = false;
    assert_eq!(keys::action(&Key::Return, Modifiers::NONE, &person), None);
    assert_eq!(keys::action(&ch("d"), Modifiers::COMMAND, &person), None);
    assert_eq!(keys::hint(&person.buttons[2], &person), None);

    let spec_json = serde_json::to_value(unsaved()).unwrap();
    assert_eq!(
        op("action", json!({"key": "d", "modifiers": 1, "spec": spec_json})),
        json!({"kind": "press", "id": "discard"})
    );
    assert_eq!(
        op("action", json!({"key": "tab", "modifiers": 2, "spec": spec_json})),
        json!({"kind": "focusPrevious"})
    );
    assert_eq!(
        op("action", json!({"key": "return", "modifiers": 4, "spec": spec_json})),
        Value::Null
    );
}

#[test]
fn hint_ops_and_layouts() {
    let mut spec = unsaved();
    let b = serde_json::to_value(&spec.buttons[0]).unwrap();
    assert_eq!(
        op("hint", json!({"button": b, "spec": spec})),
        json!({"hint": {"kind": "command", "character": "d"}, "glyph": "⌘D", "key": "d", "modifiers": 1, "keyEquivalent": "d"})
    );
    spec.layout = Layout::SafeDefault;
    assert_eq!(keys::shown_hint(&spec.buttons[0], &spec), None);
    assert_eq!(op("shownHint", json!({"button": b, "spec": spec})), Value::Null);
    assert_eq!(Layout::alert_for(&unsaved().buttons), Layout::SafeDefault);
    assert_eq!(Layout::alert_for(&approval().buttons), Layout::Standard);
    assert_eq!(op("layoutFor", json!({"buttons": unsaved().buttons})), json!("safeDefault"));
    assert_eq!(
        op("keyButtons", json!({"spec": notice()})),
        json!({"defaultButton": null, "cancelButton": "close"})
    );
    assert_eq!(
        op("keyButtons", json!({"spec": approval()})),
        json!({"defaultButton": "change", "cancelButton": "cancel"})
    );
}

#[test]
fn focus_wraps() {
    assert_eq!(keys::focus(None, 3, false), Some(0));
    assert_eq!(keys::focus(None, 3, true), Some(2));
    assert_eq!(keys::focus(Some(2), 3, false), Some(0));
    assert_eq!(keys::focus(Some(0), 3, true), Some(2));
    assert_eq!(keys::focus(Some(1), 3, false), Some(2));
    assert_eq!(keys::focus(Some(7), 3, false), Some(0));
    assert_eq!(keys::focus(Some(0), 0, false), None);
    assert_eq!(op("focus", json!({"current": 1, "count": 3, "backward": true})), json!(0));
    assert_eq!(op("focus", json!({"count": 0})), Value::Null);
}

#[test]
fn named_and_event_keys() {
    assert_eq!(keys::named("return"), Some((Key::Return, Modifiers::NONE)));
    assert_eq!(keys::named("escape"), Some((Key::Escape, Modifiers::NONE)));
    assert_eq!(keys::named("shift-tab"), Some((Key::Tab, Modifiers::SHIFT)));
    assert_eq!(keys::named("cmd-d"), Some((Key::Character("d".into()), Modifiers::COMMAND)));
    assert_eq!(keys::named("cmd-dd"), None);
    assert_eq!(keys::named("space"), None);
    assert_eq!(op("named", json!({"name": "cmd-."})), json!({"key": ".", "modifiers": 1}));
    assert_eq!(op("named", json!({"name": "f1"})), Value::Null);

    assert_eq!(keys::event_key(36, None, 0).key, Some(Key::Return));
    assert_eq!(keys::event_key(76, None, 0).key, Some(Key::Return));
    assert_eq!(keys::event_key(53, None, 0).key, Some(Key::Escape));
    assert_eq!(keys::event_key(48, None, 0).key, Some(Key::Tab));
    assert_eq!(keys::event_key(2, Some(""), 0).key, None);
    let flags = (1u64 << 20) | (1 << 17) | (1 << 19) | (1 << 18) | (1 << 16);
    let k = keys::event_key(2, Some("dx"), flags);
    assert_eq!(k.key, Some(Key::Character("d".into())));
    assert_eq!(k.modifiers, Modifiers(15));
    assert_eq!(
        op("eventKey", json!({"keyCode": 2, "characters": "d", "modifierFlags": 1u64 << 20})),
        json!({"key": "d", "modifiers": 1})
    );
}

// MARK: RemoteConfirmUserOnlyTests

#[test]
fn synthetic_refusal() {
    let user_only: HashSet<String> = ["remote.confirm".to_string()].into();
    let shown = |id: &str, visible: bool| Record { visible, identifier: Some(id.into()) };
    let refusal = Some(keys::SYNTHETIC_REFUSAL);
    assert_eq!(
        keys::synthetic_input_refusal(&[shown("remote.confirm", true)], &user_only, false),
        refusal
    );
    assert_eq!(
        keys::synthetic_input_refusal(&[shown("remote.confirm", true)], &user_only, true),
        None
    );
    assert_eq!(keys::synthetic_input_refusal(&[shown("other", true)], &user_only, false), None);
    assert_eq!(
        keys::synthetic_input_refusal(&[shown("remote.confirm", false)], &user_only, false),
        None
    );
    assert_eq!(
        op(
            "syntheticInputRefusal",
            json!({"records": [{"visible": true, "identifier": "remote.confirm"}], "userOnly": ["remote.confirm"], "onlyCancels": false})
        ),
        json!(keys::SYNTHETIC_REFUSAL)
    );
}

#[test]
fn only_cancels() {
    assert!(!keys::only_cancels(Some("return"), 0, false, false));
    assert!(!keys::only_cancels(Some("escape"), 1, false, false));
    assert!(!keys::only_cancels(Some("escape"), 0, true, false));
    assert!(keys::only_cancels(Some("escape"), 0, false, false));
    assert!(keys::only_cancels(None, 0, false, true));
    assert_eq!(op("onlyCancels", json!({"key": "escape"})), json!(true));
    assert_eq!(op("onlyCancels", json!({"key": "escape", "sequence": true})), json!(false));
}

// MARK: CmuxDialogDisabledOptionTests

fn choice(selected: Option<&str>) -> Spec {
    let spec = json!({"fields": [{"kind": "choice", "id": "where", "options": [
        {"label": "Mini", "value": "mini", "isEnabled": false},
        {"label": "Local", "value": "local"}
    ], "selected": selected}], "buttons": [{"id": "ok", "role": "default"}]});
    serde_json::from_value(spec).unwrap()
}

#[test]
fn disabled_option_is_never_the_selection() {
    let spec = choice(None);
    let initial = values::initial_values(&spec);
    assert_eq!(initial.get("where"), Some(&V::Text("local".into())));
    assert!(!values::accepts(&spec, "where", &V::Text("mini".into())));
    assert!(values::accepts(&spec, "where", &V::Text("local".into())));
    let edits: Values = [("where".to_string(), V::Text("mini".into()))].into();
    let edited = values::edit(&spec, initial.clone(), &edits);
    assert!(!edited.changed);
    assert_eq!(edited.values, initial);
    assert_eq!(
        values::initial_values(&choice(Some("mini"))).get("where"),
        Some(&V::Text("local".into()))
    );
    assert_eq!(
        op("initialValues", json!({"spec": choice(Some("mini"))})),
        json!({"where": {"text": "local"}})
    );
}

// MARK: Values (pins)

#[test]
fn values_and_presses() {
    let spec: Spec = serde_json::from_value(json!({
        "fields": [
            {"kind": "text", "id": "name", "initial": "a"},
            {"kind": "check", "id": "keep", "on": true},
            {"kind": "copyLine", "id": "copy"},
            {"kind": "pairingCode", "copyId": "copyCode"},
            {"kind": "note"}
        ],
        "buttons": [{"id": "ok", "role": "default"}]
    }))
    .unwrap();
    assert_eq!(
        op("initialValues", json!({"spec": spec})),
        json!({"name": {"text": "a"}, "keep": {"bool": true}})
    );
    assert!(!values::accepts(&spec, "name", &V::Bool(true)));
    assert!(!values::accepts(&spec, "keep", &V::Text("x".into())));
    assert!(!values::accepts(&spec, "missing", &V::Text("x".into())));
    assert_eq!(
        op(
            "edit",
            json!({"spec": spec, "values": {"name": {"text": "a"}}, "edits": {"name": {"text": "b"}, "keep": {"text": "no"}}})
        ),
        json!({"values": {"name": {"text": "b"}}, "changed": true})
    );
    assert!(values::pressable(&spec, "ok"));
    assert!(values::pressable(&spec, "copy"));
    assert!(values::pressable(&spec, "copyCode"));
    assert!(!values::pressable(&spec, "nope"));
    assert_eq!(op("pressable", json!({"spec": spec, "id": "copyCode"})), json!(true));
    assert_eq!(op("actionIds", json!({"field": {"kind": "pairingCode"}})), json!([]));
    assert_eq!(op("actionIds", json!({"field": {"kind": "copyLine", "id": "c"}})), json!(["c"]));
    assert_eq!(Field::Note {}.id(), None);
}

#[test]
fn pairing_countdown() {
    assert_eq!(values::pairing_clock(600.0, 0.0), "10:00");
    assert_eq!(values::pairing_clock(61.2, 0.0), "1:02");
    assert_eq!(values::pairing_clock(0.0, 5.0), "0:00");
    assert_eq!(values::pairing_clock(9.01, 0.0), "0:10");
    assert!(!values::pairing_countdown(60.0, 0.0).urgent);
    assert!(values::pairing_countdown(59.9, 0.0).urgent);
    assert_eq!(
        op("pairingCountdown", json!({"until": 100, "now": 41})),
        json!({"clock": "0:59", "urgent": true})
    );
}

#[test]
fn step_looks() {
    let look = |s| {
        let l = values::step_look(s);
        (l.glyph, l.title_role, l.fix_role)
    };
    assert_eq!(look(StepState::Pending), (StepGlyph::Idle, InkRole::Secondary, InkRole::Secondary));
    assert_eq!(look(StepState::Skipped), (StepGlyph::Idle, InkRole::Secondary, InkRole::Secondary));
    assert_eq!(look(StepState::Running), (StepGlyph::Busy, InkRole::Primary, InkRole::Secondary));
    assert_eq!(look(StepState::Done), (StepGlyph::Success, InkRole::Primary, InkRole::Secondary));
    assert_eq!(
        look(StepState::Warning),
        (StepGlyph::Waiting, InkRole::Primary, InkRole::Secondary)
    );
    assert_eq!(look(StepState::Failed), (StepGlyph::Error, InkRole::Primary, InkRole::Danger));
    assert_eq!(
        op("stepLook", json!({"state": "failed"})),
        json!({"glyph": "error", "titleRole": "primary", "fixRole": "danger"})
    );
}

#[test]
fn lines_scroll() {
    let lines = |n: usize, s: &str| vec![s.to_string(); n];
    assert!(!values::lines_scroll(&lines(8, "x")));
    assert!(values::lines_scroll(&lines(9, "x")));
    assert!(!values::lines_scroll(&lines(1, &"a".repeat(600))));
    assert!(values::lines_scroll(&lines(1, &"a".repeat(601))));
    // Swift counts graphemes: an accent, a ZWJ family and CRLF are one character each.
    assert_eq!(values::character_count("e\u{301}"), 1);
    assert_eq!(values::character_count("👨\u{200D}👩\u{200D}👧"), 1);
    assert_eq!(values::character_count("a\r\nb"), 3);
    assert!(!values::lines_scroll(&lines(1, &"e\u{301}".repeat(600))));
    assert_eq!(op("linesScroll", json!({"lines": lines(9, "x")})), json!(true));
}

// MARK: KeycapPlaygroundTests, KeycapChipConcentricTests

#[test]
fn keycap_styles() {
    assert_eq!(KeycapStyle::ALL.len(), 8);
    assert_eq!(KeycapStyle::SHIPPED, KeycapStyle::LinearKbd);
    assert_eq!(
        op("keycapStyles", json!({})),
        json!([
            "plate",
            "linearKbd",
            "plainGlyph",
            "faintFill",
            "hairline",
            "quietSmall",
            "defaultOnly",
            "outside"
        ])
    );
    let titles: Vec<_> = KeycapStyle::ALL.iter().map(|s| s.title()).collect();
    assert_eq!(titles[1], "2. Linear kbd (shipped)");
    assert_eq!(titles[7], "8. Outside the buttons");
    for style in KeycapStyle::ALL {
        for role in [Role::Default, Role::Cancel, Role::Destructive, Role::Normal] {
            let expected = match style {
                KeycapStyle::Outside => false,
                KeycapStyle::DefaultOnly => role == Role::Default,
                _ => true,
            };
            assert_eq!(style.shows_key(role), expected, "{style:?} {role:?}");
        }
    }
    assert_eq!(
        op("keycapShowsKey", json!({"style": "defaultOnly", "role": "cancel"})),
        json!(false)
    );
}

#[test]
fn linear_kbd_chip_is_concentric() {
    for scale in [1.0, 1.25, 0.85] {
        let s = KeycapStyle::LinearKbd;
        assert_eq!(s.plate_height(scale), Some(16.0 * scale));
        assert_eq!(s.glyph_size(scale), 11.0 * scale);
        for outer in [8.0, 6.0, 4.0] {
            let h = 16.0 * scale;
            assert_eq!(s.corner_radius(40.0, h, scale, outer), (outer - 5.0 * scale).max(2.0));
        }
    }
}

#[test]
fn keycap_looks_pin_swift() {
    let row = |s: KeycapStyle| {
        let l = s.look(1.0, 8.0);
        (
            l.has_plate,
            l.fill_alpha,
            l.border_alpha,
            l.glyph_alpha,
            l.glyph_size,
            l.glyph_weight,
            l.plate_height,
            l.trailing,
            l.gap,
            l.plate_padding,
        )
    };
    use GlyphWeight::{Emphasis as E, Regular as R};
    assert_eq!(row(KeycapStyle::Plate), (true, 0.14, 0.0, 1.0, 11.0, E, None, 3.0, 8.0, 4.0));
    assert_eq!(
        row(KeycapStyle::LinearKbd),
        (true, 0.10, 0.0, 1.0, 11.0, E, Some(16.0), 5.0, 6.0, 4.0)
    );
    assert_eq!(row(KeycapStyle::PlainGlyph), (false, 0.0, 0.0, 1.0, 11.0, R, None, 12.0, 6.0, 4.0));
    assert_eq!(
        row(KeycapStyle::FaintFill),
        (true, 0.06, 0.0, 0.8, 11.0, E, Some(18.0), 4.0, 6.0, 4.0)
    );
    assert_eq!(
        row(KeycapStyle::Hairline),
        (true, 0.0, 0.22, 1.0, 11.0, E, Some(18.0), 4.0, 6.0, 4.0)
    );
    assert_eq!(
        row(KeycapStyle::QuietSmall),
        (false, 0.0, 0.0, 0.55, 10.0, R, None, 12.0, 4.0, 4.0)
    );
    assert_eq!(
        row(KeycapStyle::DefaultOnly),
        (false, 0.0, 0.0, 1.0, 11.0, R, None, 12.0, 6.0, 4.0)
    );
    assert_eq!(row(KeycapStyle::Outside), (false, 0.0, 0.0, 1.0, 11.0, R, None, 12.0, 6.0, 4.0));
    // Plate: inset 3 from an 8 pt button corner, capped at half the plate, floored at 2.
    assert_eq!(KeycapStyle::Plate.corner_radius(30.0, 20.0, 1.0, 8.0), 5.0);
    assert_eq!(KeycapStyle::Plate.corner_radius(30.0, 6.0, 1.0, 8.0), 3.0);
    assert_eq!(KeycapStyle::Plate.corner_radius(30.0, 20.0, 1.0, 4.0), 2.0);
    assert_eq!(KeycapStyle::Hairline.corner_radius(30.0, 18.0, 1.0, 8.0), 4.0);
    let look =
        op("keycapLook", json!({"style": "faintFill", "userScale": 2, "buttonCornerRadius": 8}));
    assert_eq!(look["plateHeight"], json!(36.0));
    assert_eq!(look["glyphWeight"], json!("emphasis"));
    assert_eq!(look["defaultShowsKey"], json!(true));
    assert_eq!(look["note"], json!("An 18 pt plate, ink at 6%, no border; the glyph at 80%."));
    assert_eq!(
        op(
            "keycapCornerRadius",
            json!({"style": "linearKbd", "width": 30, "height": 16, "buttonCornerRadius": 8})
        ),
        json!(3.0)
    );
}

#[test]
fn metrics_pin_swift() {
    let m = Metrics::new(1.0, 8.0);
    assert_eq!((m.button_height, m.button_min_width, m.button_corner_radius), (26.0, 72.0, 8.0));
    assert_eq!(
        (m.width, m.width_with_icon, m.buttons_gap, m.field_height),
        (380.0, 432.0, 12.0, 24.0)
    );
    assert_eq!(
        (m.icon_size, m.icon_gap, m.header_icon_size, m.header_icon_gap),
        (40.0, 12.0, 20.0, 8.0)
    );
    assert_eq!(
        (m.lines_max_height, m.scrolling_line_count, m.scrolling_character_count),
        (240.0, 8, 600)
    );
    assert_eq!(
        (m.keycap_inset, m.keycap_corner_floor, m.keycap_padding, m.keycap_leading, m.keycap_gap),
        (3.0, 2.0, 4.0, 12.0, 8.0)
    );
    assert_eq!(
        (m.code_inset, m.code_vertical_inset, m.code_well_fill, m.code_well_edge, m.qr_side),
        (10.0, 7.0, 0.06, 0.12, 120.0)
    );
    assert_eq!(m.keycap_corner_radius(30.0, 20.0), 5.0);
    let big = op("metrics", json!({"userScale": 1.5, "buttonCornerRadius": 6}));
    assert_eq!(big["buttonHeight"], json!(39.0));
    assert_eq!(big["keycapCornerFloor"], json!(2.0));
    assert_eq!(big["keycapButtonCornerRadius"], json!(6.0));
    assert_eq!(big["qrSide"], json!(180.0));
}

// MARK: Panel

#[test]
fn drag_rule() {
    use ViewKind::*;
    assert!(starts_drag(true, &[]));
    assert!(starts_drag(true, &[Label, Other, Image]));
    for blocker in [EditableField, Control, Text, Scroller] {
        assert!(!starts_drag(true, &[Other, blocker]), "{blocker:?}");
    }
    assert!(!starts_drag(false, &[]));
    assert_eq!(
        op("startsDrag", json!({"inCard": true, "chain": ["label", "control"]})),
        json!(false)
    );
}

#[test]
fn unknown_and_invalid() {
    assert_eq!(call("dialog.nope", &json!({})), Err(OpError::Unknown));
    assert!(matches!(call("dialog.focus", &json!({"count": "x"})), Err(OpError::Invalid(_))));
}
