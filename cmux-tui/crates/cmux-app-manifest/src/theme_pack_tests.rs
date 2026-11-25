use super::*;
use crate::{Severity, is_valid, validate_manifest};
use serde_json::json;

fn manifest(options: Value) -> Value {
    json!({
        "manifestVersion": 2,
        "id": "local/dusk",
        "name": "Dusk",
        "version": "1.0.0",
        "description": "A theme pack.",
        "engines": { "cmux": "^2.0" },
        "implements": { "cmux.theme/1": { "title": "Dusk", "options": options } }
    })
}

fn codes(issues: &[Issue]) -> Vec<&'static str> {
    issues.iter().map(|i| i.code).collect()
}

#[test]
fn token_keys_are_the_camel_case_of_the_css_variables() {
    assert_eq!(token_key(AppToken::TextSecondary), "textSecondary");
    assert_eq!(token_key(AppToken::OnAccent), "onAccent");
    assert_eq!(token_key(AppToken::Window), "window");
    let file: Value = serde_json::from_str(
        crate::interfaces::interface_files().iter().find(|(n, _)| *n == INTERFACE).unwrap().1,
    )
    .unwrap();
    let schema_keys: Vec<&String> = file
        .pointer("/options/properties/tokens/properties")
        .unwrap()
        .as_object()
        .unwrap()
        .keys()
        .collect();
    let ours: Vec<String> = AppToken::ALL.iter().map(|t| token_key(*t)).collect();
    assert_eq!(schema_keys.len(), ours.len());
    for key in ours {
        assert!(schema_keys.contains(&&key), "{key} is missing from the interface's tokens");
    }
}

/// The interface's slot list is the slot registry's (schemas/theme/slots.json).
#[test]
fn the_interface_names_every_slot_and_variant_of_the_registry() {
    let registry: Value =
        serde_json::from_str(include_str!("../../../../schemas/theme/slots.json")).unwrap();
    let want: Vec<(String, Vec<String>)> = registry["slots"]
        .as_array()
        .unwrap()
        .iter()
        .map(|slot| {
            let variants = slot["variants"].as_array().into_iter().flatten();
            (
                slot["id"].as_str().unwrap().to_owned(),
                variants.map(|v| v["id"].as_str().unwrap().to_owned()).collect(),
            )
        })
        .collect();
    let mut have = known_slots();
    let mut want = want;
    have.sort();
    want.sort();
    assert_eq!(have, want);
}

#[test]
fn a_full_pack_that_meets_the_floor_is_valid_with_no_findings() {
    let issues = validate_manifest(&manifest(json!({
        "appearance": "dark",
        "tokens": { "window": "#101014", "sidebar": "#14141a", "text": "#f0f0f0", "accent": "#ff79c6", "onAccent": "#000000" },
        "type": { "ui": "Inter", "mono": "JetBrains Mono", "scale": 1.1 },
        "chrome": { "titleBar": "compact", "tabShape": "pill", "borderWidth": 1, "glass": { "sidebar": 0.4 } },
        "icons": { "tab.close": "icons/close.svg" },
        "sounds": { "turnDone": "sounds/done.wav" },
        "motion": { "quick": 60, "micro": 100, "standard": 160, "large": 220, "spinner": 1500 },
        "slots": { "chat.thinkingIndicator": "pulse" }
    })));
    assert!(is_valid(&issues), "{issues:?}");
    assert!(issues.iter().all(|i| !i.code.starts_with("theme")), "{issues:?}");
}

#[test]
fn a_pair_under_the_floor_is_adjusted_and_names_the_color_drawn() {
    let tokens = json!({ "window": "#ffffff", "text": "#aaaaaa" });
    let report = theme_contrast(&tokens);
    assert_eq!(report.findings.len(), 1);
    let finding = &report.findings[0];
    assert_eq!(
        (finding.token.as_str(), finding.on.as_str(), finding.minimum),
        ("text", "window", 4.5)
    );
    assert!(finding.ratio < 4.5);
    let drawn = finding.adjusted.clone().unwrap();
    assert_eq!(report.tokens["text"], drawn);
    let rgb = parse_hex(&drawn).unwrap();
    assert!(rgb.contrast(Rgb::WHITE) >= 4.5);
    assert!(!report.refused());

    let issues = validate_manifest(&manifest(json!({ "tokens": tokens })));
    assert!(is_valid(&issues), "{issues:?}");
    let issue = issues.iter().find(|i| i.code == "theme.contrast.adjusted").unwrap();
    assert_eq!(issue.severity, Severity::Warning);
    assert_eq!(issue.path, "/implements/cmux.theme~11/options/tokens/text");
    assert!(
        issue.message.contains("text on window") && issue.message.contains(&drawn),
        "{}",
        issue.message
    );
}

/// Text on a black window, a white sidebar and a mid-gray content: no gray reaches 4.5:1 on all three.
#[test]
fn a_pair_no_lightness_can_fix_is_refused_with_the_reason() {
    let tokens = json!({ "window": "#000000", "sidebar": "#ffffff", "content": "#777777", "text": "#777777" });
    assert!(theme_contrast(&tokens).refused());
    let issues = validate_manifest(&manifest(json!({ "tokens": tokens })));
    assert!(!is_valid(&issues));
    let issue = issues.iter().find(|i| i.code == "theme.contrast").unwrap();
    assert!(issue.message.contains("no lightness of text"), "{}", issue.message);
}

#[test]
fn a_pair_with_a_token_the_pack_leaves_out_is_not_checked() {
    let report = theme_contrast(&json!({ "text": "#777777" }));
    assert!(report.findings.is_empty());
}

#[test]
fn an_adjusted_accent_is_the_surface_on_accent_is_fitted_against() {
    // A dim accent on a dark window moves lighter; onAccent is held to the accent cmux draws.
    let tokens = json!({ "window": "#000000", "accent": "#202020", "onAccent": "#303030" });
    let report = theme_contrast(&tokens);
    assert!(!report.refused(), "{:?}", report.findings);
    let accent = parse_hex(&report.tokens["accent"]).unwrap();
    let on_accent = parse_hex(&report.tokens["onAccent"]).unwrap();
    assert!(accent.contrast(Rgb::BLACK) >= 3.0);
    assert!(on_accent.contrast(accent) >= 4.5);
}

#[test]
fn unknown_slots_and_variants_warn_and_fall_back() {
    let issues = validate_manifest(&manifest(json!({
        "slots": { "chat.thinkingIndicator": "sparkles", "toast.enter": "slide" }
    })));
    assert!(is_valid(&issues), "{issues:?}");
    let found = codes(&issues);
    assert!(
        found.contains(&"theme.slot.variant") && found.contains(&"theme.slot.unknown"),
        "{found:?}"
    );
}

#[test]
fn motion_steps_keep_the_scales_order() {
    let issues =
        validate_manifest(&manifest(json!({ "motion": { "quick": 200, "standard": 100 } })));
    let issue = issues.iter().find(|i| i.code == "theme.motion.order").unwrap();
    assert_eq!(issue.path, "/implements/cmux.theme~11/options/motion/standard");
}

#[test]
fn the_schema_refuses_raw_colors_outside_paths_and_scripts() {
    for options in [
        json!({ "tokens": { "text": "red" } }),
        json!({ "tokens": { "brand": "#ffffff" } }),
        json!({ "icons": { "tab.close": "../close.svg" } }),
        json!({ "sounds": { "turnDone": "/etc/done.wav" } }),
        json!({ "chrome": { "tabShape": "hexagon" } }),
    ] {
        let issues = validate_manifest(&manifest(options.clone()));
        assert!(!is_valid(&issues), "{options}");
    }
    // A theme pack is data: no export, no script.
    let mut m = manifest(json!({}));
    m["implements"]["cmux.theme/1"]["export"] = json!("render");
    assert!(!is_valid(&validate_manifest(&m)));
}
