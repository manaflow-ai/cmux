//! Runs every case of `schemas/keymap/key-vectors.json`, the synthetic layouts and events
//! that cmux-keymap and webviews/src/ui/keyStyle.ts must both resolve the same way.

use cmux_keymap::{
    KeyEvent, KeyStyle, ListKeys, Mods, Outcome, ShortcutLayout, Stroke, check_table,
    stroke_matches,
};
use serde_json::{Map, Value};
use std::collections::BTreeSet;

const VECTORS: &str = include_str!("../../../../schemas/keymap/key-vectors.json");

fn vectors() -> Value {
    serde_json::from_str(VECTORS).expect("key-vectors.json parses")
}

fn mods(value: Option<&Value>, case: &str) -> Mods {
    let mut mods = Mods::NONE;
    for name in value.and_then(Value::as_array).into_iter().flatten() {
        let name = name.as_str().unwrap_or_else(|| panic!("{case}: a modifier is not a string"));
        mods = mods.with_name(name).unwrap_or_else(|| panic!("{case}: unknown modifier {name}"));
    }
    mods
}

/// The event of `{layout, code, mods?}` or `{named}`, built from the vectors' `layouts`.
fn event<'a>(layouts: &'a Map<String, Value>, spec: &'a Value, case: &str) -> KeyEvent<'a> {
    let mods = mods(spec.get("mods"), case);
    if let Some(named) = spec.get("named").and_then(Value::as_str) {
        return KeyEvent { code: None, key: named, shifted_key: None, mods };
    }
    let layout = spec["layout"].as_str().unwrap_or_else(|| panic!("{case}: no layout"));
    let code = spec["code"].as_str().unwrap_or_else(|| panic!("{case}: no code"));
    let chars = layouts
        .get(layout)
        .unwrap_or_else(|| panic!("{case}: layout {layout} is not in `layouts`"))
        .get(code)
        .and_then(Value::as_array)
        .unwrap_or_else(|| panic!("{case}: layout {layout} has no key {code}"));
    let key = chars.first().and_then(Value::as_str).unwrap_or_else(|| panic!("{case}: no key"));
    let shifted_key = chars.get(1).and_then(Value::as_str);
    KeyEvent { code: Some(code), key, shifted_key, mods }
}

#[test]
fn the_embedded_table_parses_completely() {
    if let Err(problems) = check_table() {
        panic!("key-styles.json and cmux-keymap disagree:\n  {}", problems.join("\n  "));
    }
}

#[test]
fn every_shortcut_case_matches_in_both_modes() {
    let vectors = vectors();
    let layouts = vectors["layouts"].as_object().expect("layouts");
    let cases = vectors["shortcuts"].as_array().expect("shortcuts");
    assert!(!cases.is_empty());
    let mut failures = Vec::new();
    for case in cases {
        let name = case["name"].as_str().expect("a case name");
        let binding = case["binding"].as_str().expect("a binding");
        let stroke = Stroke::parse(binding)
            .unwrap_or_else(|| panic!("{name}: binding {binding:?} does not parse"));
        let event = event(layouts, case, name);
        for layout in ShortcutLayout::ALL {
            let want = case[layout.as_setting()]
                .as_bool()
                .unwrap_or_else(|| panic!("{name}: no {} expectation", layout.as_setting()));
            let got = stroke_matches(layout, &stroke, &event);
            if got != want {
                failures.push(format!(
                    "{name}: {binding} on {event:?} in {}: got {got}, want {want}",
                    layout.as_setting()
                ));
            }
        }
    }
    assert!(
        failures.is_empty(),
        "{} shortcut cases fail:\n  {}",
        failures.len(),
        failures.join("\n  ")
    );
}

fn outcome_name(outcome: Outcome) -> String {
    match outcome {
        Outcome::Command(command) => command.id().to_owned(),
        Outcome::Pending => "pending".to_owned(),
        Outcome::Pass => "pass".to_owned(),
    }
}

#[test]
fn every_list_case_gives_its_outcomes() {
    let vectors = vectors();
    let layouts = vectors["layouts"].as_object().expect("layouts");
    let cases = vectors["lists"].as_array().expect("lists");
    assert!(!cases.is_empty());
    let mut failures = Vec::new();
    for case in cases {
        let name = case["name"].as_str().expect("a case name");
        let style_name = case["style"].as_str().expect("a style");
        let style = KeyStyle::from_setting(style_name);
        assert_eq!(style.as_setting(), style_name, "{name}: unknown style");
        let layout = ShortcutLayout::from_setting(
            case.get("shortcutLayout").and_then(Value::as_str).unwrap_or("followLayout"),
        );
        let in_text = case.get("inText").and_then(Value::as_bool).unwrap_or(false);
        let strokes = case["strokes"].as_array().expect("strokes");
        let expect = case["expect"].as_array().expect("expect");
        assert_eq!(strokes.len(), expect.len(), "{name}: one expectation per stroke");
        let mut keys = ListKeys::new(style, layout);
        for (step, (spec, want)) in strokes.iter().zip(expect).enumerate() {
            let event = event(layouts, spec, name);
            let got = outcome_name(keys.feed(&event, in_text));
            let want = want.as_str().expect("an outcome name");
            if got != want {
                failures.push(format!(
                    "{name} (stroke {step}, {event:?}, inText {in_text}): got {got}, want {want}"
                ));
            }
        }
    }
    assert!(
        failures.is_empty(),
        "{} list strokes fail:\n  {}",
        failures.len(),
        failures.join("\n  ")
    );
}

/// The vectors keep naming outcomes this crate knows, and every style appears.
#[test]
fn the_vectors_cover_every_style() {
    let vectors = vectors();
    let styles: BTreeSet<&str> = vectors["lists"]
        .as_array()
        .expect("lists")
        .iter()
        .filter_map(|c| c["style"].as_str())
        .collect();
    for style in KeyStyle::ALL {
        assert!(styles.contains(style.as_setting()), "no list case for {}", style.as_setting());
    }
}
