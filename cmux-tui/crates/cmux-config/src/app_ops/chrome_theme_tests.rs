//! Cases of Swift `TabShapeSettingTests`, `GooeyTabsSettingTests`,
//! `CornerFlushSettingTests`, `TitleAreaContrastTests` (the parse cases),
//! `ThemeFileTests` (`applied`, `density(under:)`) and `ChatFontFacesTests`.

use serde_json::{Value, json};

use super::call;

fn run(op: &str, request: &Value) -> Value {
    call(op, request).expect("op").expect("reply")
}

fn parsed(appearance: &Value) -> Value {
    run("chrome_placement.parse", &json!({ "root": { "appearance": appearance } }))
}

fn flagged(reply: &Value, path: &str) -> bool {
    reply["diagnostics"]
        .as_array()
        .unwrap()
        .iter()
        .any(|d| d["path"] == path && d["kind"] == "invalidValue")
}

#[test]
fn a_missing_tab_shape_is_block() {
    let reply = parsed(&json!({}));
    assert_eq!(reply["values"]["appearance.tabShape"], "block");
    assert!(!flagged(&reply, "appearance.tabShape"));
}

#[test]
fn every_tab_shape_reads() {
    for shape in ["block", "rounded"] {
        let reply = parsed(&json!({ "tabShape": shape }));
        assert_eq!(reply["values"]["appearance.tabShape"], shape);
        assert!(!flagged(&reply, "appearance.tabShape"));
    }
}

#[test]
fn a_bad_tab_shape_is_block_and_reported() {
    let reply = parsed(&json!({ "tabShape": "wobbly" }));
    assert_eq!(reply["values"]["appearance.tabShape"], "block");
    let note = &reply["diagnostics"][0];
    assert_eq!(note["path"], "appearance.tabShape");
    assert!(note["message"].as_str().unwrap().starts_with("expected one of"));
}

#[test]
fn gooey_tabs_default_off_and_each_value_parses() {
    assert_eq!(parsed(&json!({}))["values"]["appearance.gooeyTabs"], "off");
    for level in ["off", "subtle", "full"] {
        let reply = parsed(&json!({ "gooeyTabs": level }));
        assert_eq!(reply["values"]["appearance.gooeyTabs"], level);
        assert!(!flagged(&reply, "appearance.gooeyTabs"));
    }
}

#[test]
fn a_bad_gooey_tabs_value_is_the_default_with_a_diagnostic() {
    let bad = parsed(&json!({ "gooeyTabs": "very" }));
    assert_eq!(bad["values"]["appearance.gooeyTabs"], "off");
    assert!(flagged(&bad, "appearance.gooeyTabs"));
}

#[test]
fn corner_flush_is_unset_by_default_and_each_value_parses() {
    assert!(parsed(&json!({}))["values"].get("appearance.cornerFlush").is_none());
    for value in ["off", "flush", "flush-tight", "flush-goo"] {
        let reply = parsed(&json!({ "cornerFlush": value }));
        assert_eq!(reply["values"]["appearance.cornerFlush"], value);
    }
}

#[test]
fn a_bad_corner_flush_is_unset_with_a_diagnostic() {
    let bad = parsed(&json!({ "cornerFlush": "goo" }));
    assert!(bad["values"].get("appearance.cornerFlush").is_none());
    assert!(flagged(&bad, "appearance.cornerFlush"));
}

#[test]
fn a_missing_contrast_is_one() {
    let reply = parsed(&json!({}));
    assert_eq!(reply["values"]["appearance.titleAreaContrast"], 1.0);
    assert!(!flagged(&reply, "appearance.titleAreaContrast"));
}

#[test]
fn a_contrast_in_range_is_taken_and_one_outside_is_clamped_with_a_diagnostic() {
    let path = "appearance.titleAreaContrast";
    assert_eq!(parsed(&json!({ "titleAreaContrast": 0.5 }))["values"][path], 0.5);
    let loud = parsed(&json!({ "titleAreaContrast": 9 }));
    let max = loud["values"][path].as_f64().unwrap();
    assert!(max < 9.0);
    assert!(flagged(&loud, path));
    assert!(loud["diagnostics"][0]["message"].as_str().unwrap().ends_with("; clamped"));
    let word = parsed(&json!({ "titleAreaContrast": "loud" }));
    assert_eq!(word["values"][path], 1.0);
    assert!(flagged(&word, path));
}

#[test]
fn the_tone_parses() {
    let path = "appearance.titleAreaTone";
    assert_eq!(parsed(&json!({}))["values"][path], "oneColor");
    assert_eq!(parsed(&json!({ "titleAreaTone": "subtleTone" }))["values"][path], "subtleTone");
    let bad = parsed(&json!({ "titleAreaTone": "twoTone" }));
    assert_eq!(bad["values"][path], "oneColor");
    assert!(flagged(&bad, path));
}

#[test]
fn a_theme_file_sets_look_settings_over_the_root() {
    let reply = run(
        "theme.applied",
        &json!({
            "values": [
                { "path": ["appearance", "accent"], "value": "blue" },
                { "path": ["appearance", "borders"], "value": "none" },
            ],
            "root": { "appearance": { "accent": "red", "density": "compact" } },
        }),
    );
    assert_eq!(
        reply["root"],
        json!({ "appearance": { "accent": "blue", "borders": "none", "density": "compact" } })
    );
}

#[test]
fn a_managed_key_keeps_the_file_from_applying() {
    let reply = run(
        "theme.applied",
        &json!({
            "values": [{ "path": ["appearance", "accent"], "value": "blue" }],
            "root": { "appearance": { "accent": "red" } },
            "managed": ["appearance.accent"],
        }),
    );
    assert_eq!(reply["root"], json!({ "appearance": { "accent": "red" } }));
}

#[test]
fn a_font_faces_object_applies_whole() {
    let faces = json!({
        "Pack Sans": "file:/tmp/cmux-config/fonts/PackSans.woff2",
        "Pack Serif:italic": "file:/Library/Fonts/P.otf",
    });
    let reply = run(
        "theme.applied",
        &json!({
            "values": [{ "path": ["agentPane", "display", "font", "faces"], "value": faces }],
            "root": {},
        }),
    );
    assert_eq!(reply["root"]["agentPane"]["display"]["font"]["faces"], faces);
}

#[test]
fn a_managed_density_keeps_the_themes_from_applying() {
    let blocked = |managed: Value| {
        run("theme.density_blocked", &json!({ "managed": managed }))["blocked"].clone()
    };
    assert_eq!(blocked(json!(["appearance.density"])), true);
    assert_eq!(blocked(json!(["appearance"])), true);
    assert_eq!(blocked(json!(["appearance.accent"])), false);
}
