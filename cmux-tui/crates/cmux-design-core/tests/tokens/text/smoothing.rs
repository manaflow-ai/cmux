//! `FontSmoothing.swift` and `ProcessFontSmoothing.swift`.

use cmux_design_core::ops::call;
use cmux_design_core::tokens::text::smoothing::*;
use serde_json::json;

#[test]
fn raw_and_css_values() {
    assert_eq!(FontSmoothing::default(), FontSmoothing::Auto);
    let raws: Vec<_> = FontSmoothing::ALL.iter().map(|m| m.raw_value()).collect();
    assert_eq!(raws, ["auto", "antialiased", "subpixel"]);
    assert_eq!(FontSmoothing::Auto.css_value(), None);
    assert_eq!(FontSmoothing::Antialiased.css_value(), Some("antialiased"));
    assert_eq!(FontSmoothing::Subpixel.css_value(), Some("subpixel-antialiased"));
    assert_eq!(FontSmoothing::from_raw("subpixel"), Some(FontSmoothing::Subpixel));
    assert_eq!(FontSmoothing::from_raw("Subpixel"), None);
    assert_eq!(FontSmoothing::from_raw(""), None);
    assert_eq!(DEFAULTS_KEY, "AppleFontSmoothing");
    assert_eq!((ANTIALIASED_VALUE, SUBPIXEL_VALUE), (0, 2));
}

/// ProcessFontSmoothingTests: 1, 2 and 3 smooth stems, 0 does not; unset follows the system (on).
#[test]
fn smooths_stems_values() {
    for v in [1, 2, 3] {
        assert!(smooths_stems(Some(v)));
    }
    assert!(!smooths_stems(Some(0)));
    assert!(smooths_stems(None));
    assert!(smooths_stems(Some(-1)));
}

/// ProcessFontSmoothingTests `antialiasedWritesZero`: 0 over a saved 2.
#[test]
fn antialiased_writes_zero_over_two() {
    let out = apply(FontSmoothing::Antialiased, Some(2), None);
    assert_eq!(out.write, DefaultsWrite::Set(0));
    assert_eq!(out.value, Some(0));
    assert!(!out.smooths_stems);
    assert!(out.refreshes_chrome);
    // Already 0: kept, no refresh.
    let kept = apply(FontSmoothing::Antialiased, Some(0), None);
    assert_eq!(kept.write, DefaultsWrite::Keep);
    assert!(!kept.refreshes_chrome);
    // Unset: written.
    assert_eq!(apply(FontSmoothing::Antialiased, None, None).write, DefaultsWrite::Set(0));
}

/// ProcessFontSmoothingTests `subpixelWritesNonZero`: 2 over a saved 0; a saved non-zero stays.
#[test]
fn subpixel_writes_two_over_zero() {
    let out = apply(FontSmoothing::Subpixel, Some(0), None);
    assert_eq!(out.write, DefaultsWrite::Set(2));
    assert!(out.smooths_stems);
    assert!(out.refreshes_chrome);
    let kept = apply(FontSmoothing::Subpixel, Some(1), None);
    assert_eq!(kept.write, DefaultsWrite::Keep);
    assert_eq!(kept.value, Some(1));
    assert!(!kept.refreshes_chrome);
    // Unset: 2 written, but stems already smoothed (unset reads as on).
    let unset = apply(FontSmoothing::Subpixel, None, None);
    assert_eq!(unset.write, DefaultsWrite::Set(2));
    assert!(!unset.refreshes_chrome);
}

/// ProcessFontSmoothingTests `autoRemovesAppValue`: the app value goes and the global shows.
#[test]
fn auto_removes_and_follows_global() {
    let out = apply(FontSmoothing::Auto, Some(0), Some(0));
    assert_eq!(out.write, DefaultsWrite::Remove);
    assert_eq!(out.value, Some(0));
    assert!(!out.smooths_stems);
    assert!(!out.refreshes_chrome);
    let to_system = apply(FontSmoothing::Auto, Some(0), None);
    assert_eq!(to_system.value, None);
    assert!(to_system.smooths_stems);
    assert!(to_system.refreshes_chrome);
}

/// FontSmoothingSettingTests `theFileIsWrittenBeforeAppKitStarts`: the stored value per mode.
#[test]
fn written_before_appkit_starts() {
    assert_eq!(apply(FontSmoothing::Subpixel, Some(0), None).value, Some(2));
    assert_eq!(apply(FontSmoothing::Antialiased, Some(2), None).value, Some(0));
    assert_eq!(apply(FontSmoothing::Auto, Some(0), None).value, None);
}

#[test]
fn ops() {
    assert_eq!(
        call("tokens.text_font_smoothing", &json!({"mode": "subpixel"})).unwrap(),
        json!({"rawValue": "subpixel", "cssValue": "subpixel-antialiased"})
    );
    assert_eq!(
        call("tokens.text_font_smoothing", &json!({"mode": "auto"})).unwrap(),
        json!({"rawValue": "auto", "cssValue": null})
    );
    assert_eq!(
        call("tokens.text_font_smoothing_parse", &json!({"raw": "antialiased"})).unwrap(),
        json!({"mode": "antialiased"})
    );
    assert_eq!(
        call("tokens.text_font_smoothing_parse", &json!({"raw": "x"})).unwrap(),
        json!({"mode": null})
    );
    assert_eq!(
        call("tokens.text_smooths_stems", &json!({"value": 0})).unwrap(),
        json!({"smoothsStems": false, "defaultsKey": "AppleFontSmoothing"})
    );
    assert_eq!(call("tokens.text_smooths_stems", &json!({})).unwrap()["smoothsStems"], json!(true));
    assert_eq!(
        call("tokens.text_apply_smoothing", &json!({"mode": "antialiased", "saved": 2})).unwrap(),
        json!({"write": {"kind": "set", "value": 0}, "value": 0, "smoothsStems": false, "refreshesChrome": true})
    );
    assert_eq!(
        call("tokens.text_apply_smoothing", &json!({"mode": "auto", "saved": 0})).unwrap()["write"],
        json!({"kind": "remove"})
    );
}
