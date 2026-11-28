use crate::driver::{DriverParams, TabPlace, deadline_ms, duration_text, timeout_message};
use serde_json::json;

fn params(json: serde_json::Value) -> DriverParams {
    DriverParams::new("page.click", &json).unwrap()
}

#[test]
fn params_must_be_an_object_or_null() {
    assert!(DriverParams::new("m", &json!(null)).is_ok());
    assert_eq!(DriverParams::new("m", &json!([1])).unwrap_err(), "m: params must be an object");
}

#[test]
fn null_reads_as_absent() {
    let p = params(json!({"a": null, "b": 1}));
    assert!(!p.has("a"));
    assert!(p.has("b"));
    assert!(!p.has("c"));
    assert_eq!(p.optional_string("a").unwrap(), None);
    assert_eq!(p.string("a").unwrap_err(), "page.click: a: expected a string");
}

#[test]
fn typed_reads_name_the_field_and_kind() {
    let p = params(json!({"s": "x", "n": 2.5, "b": true, "list": ["a", "b"], "mixed": ["a", 1]}));
    assert_eq!(p.string("s").unwrap(), "x");
    assert_eq!(p.number("n").unwrap(), 2.5);
    assert_eq!(p.number("missing").unwrap_err(), "page.click: missing: expected a number");
    assert_eq!(p.string("n").unwrap_err(), "page.click: n: expected a string, got a number");
    assert_eq!(p.number("s").unwrap_err(), "page.click: s: expected a finite number, got a string");
    assert!(p.bool("b", false).unwrap());
    assert!(p.bool("missing", true).unwrap());
    assert_eq!(p.bool("s", false).unwrap_err(), "page.click: s: expected a boolean, got a string");
    assert_eq!(p.strings("list").unwrap(), vec!["a", "b"]);
    assert!(p.strings("missing").unwrap().is_empty());
    assert_eq!(
        p.strings("mixed").unwrap_err(),
        "page.click: mixed: expected an array of strings, got an array"
    );
    assert_eq!(p.array("list").unwrap().len(), 2);
    assert_eq!(p.array("b").unwrap_err(), "page.click: b: expected an array, got a boolean");
}

#[test]
fn timeout_defaults_disables_and_caps() {
    assert_eq!(params(json!({})).timeout_ms(30_000.0).unwrap(), Some(30_000));
    assert_eq!(params(json!({"timeoutMs": 0})).timeout_ms(30_000.0).unwrap(), None);
    assert_eq!(params(json!({"timeoutMs": -5})).timeout_ms(30_000.0).unwrap(), None);
    assert_eq!(params(json!({"timeoutMs": 1500.5})).timeout_ms(30_000.0).unwrap(), Some(1501));
    assert_eq!(
        params(json!({"timeoutMs": 1e30})).timeout_ms(30_000.0).unwrap(),
        Some(31_622_400_000)
    );
    assert_eq!(
        params(json!({"timeoutMs": "1"})).timeout_ms(30_000.0).unwrap_err(),
        "page.click: timeoutMs: expected a finite number, got a string"
    );
    assert_eq!(deadline_ms(0.4), 0);
}

#[test]
fn timeout_text_matches_swift_duration() {
    assert_eq!(duration_text(30_000), "30.0 seconds");
    assert_eq!(duration_text(1_500), "1.5 seconds");
    assert_eq!(duration_text(1), "0.001 seconds");
    assert_eq!(timeout_message("page.goto", 30_000), "page.goto: Timeout 30.0 seconds exceeded");
}

#[test]
fn tab_place_reads_non_empty_strings() {
    let place = TabPlace::from_params(&json!({"callerWorkspace": "ws1", "callerTerminal": ""}));
    assert_eq!(place, TabPlace { workspace: Some("ws1".into()), terminal: None });
    let place = TabPlace::from_params(&json!({"callerWorkspace": 3, "callerTerminal": "term_a"}));
    assert_eq!(place, TabPlace { workspace: None, terminal: Some("term_a".into()) });
    assert_eq!(TabPlace::from_params(&json!(null)), TabPlace::default());
}
