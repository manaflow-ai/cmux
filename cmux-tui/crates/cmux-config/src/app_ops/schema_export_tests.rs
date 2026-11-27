//! Pins the export to the checked-in files and to the Swift tests it replaces
//! (CmuxNextSettingsTests: SettingsSchemaExportTests exportIsFresh, everyRowHasConformanceSamples,
//! everyRowDeclaresSurfaceParity, missingKeyFailsTheExport), plus the writer's rules
//! (Swift `DeterministicJSON`).

use std::collections::BTreeSet;

use serde_json::{Map, Value, json};

use super::*;
use crate::app_ops::{OpError, call};

static SCHEMA_TEXT: &str = include_str!("../../../../../schemas/settings/settings-schema.json");
static MDM_TEXT: &str = include_str!("../../../../../docs/mdm/com.manaflow.cmux.json");

fn document() -> Value {
    serde_json::from_str(SCHEMA_TEXT).expect("settings-schema.json parses")
}

fn file_rows() -> Vec<Map<String, Value>> {
    document()["rows"]
        .as_array()
        .expect("rows")
        .iter()
        .map(|row| row.as_object().expect("row object").clone())
        .collect()
}

/// A file row as the app sends it: without what the export derives, with `palette_hidden`.
fn descriptor_row(mut row: Map<String, Value>) -> Map<String, Value> {
    let palette = row["surfaces"]["palette"].clone();
    let reason = palette["reason"].as_str().unwrap_or_default();
    let consumed = row["consumers"]
        .as_array()
        .is_some_and(|consumers| consumers.iter().any(|consumer| consumer == "cmux-next"));
    if consumed && !reason.is_empty() {
        row.insert("palette_hidden".to_owned(), json!(reason));
    }
    for derived in ["surfaces", "validation", "pattern", "kept_on_reset_all", "accepts", "refuses"]
    {
        row.remove(derived);
    }
    row
}

/// Every catalog key the document names.
fn all_keys(value: &Value, keys: &mut Vec<Value>) {
    match value {
        Value::Object(members) => {
            if let Some(Value::String(key)) = members.get("key")
                && members.get("text").is_some_and(Value::is_string)
            {
                keys.push(json!(key));
            }
            members.values().for_each(|member| all_keys(member, keys));
        }
        Value::Array(items) => items.iter().for_each(|item| all_keys(item, keys)),
        _ => {}
    }
}

fn export_request(rows: Vec<Map<String, Value>>, catalog: Vec<Value>) -> Value {
    let document = document();
    json!({
        "sections": document["sections"],
        "page": document["page"],
        "rows": rows,
        "catalog": catalog,
    })
}

// MARK: the files

#[test]
fn rewriting_the_checked_in_files_reproduces_their_bytes() {
    assert_eq!(json_text(&document(), true).expect("writes") + "\n", SCHEMA_TEXT);
    let mdm: Value = serde_json::from_str(MDM_TEXT).expect("mdm json parses");
    assert_eq!(json_text(&mdm, true).expect("writes") + "\n", MDM_TEXT);
}

/// exportIsFresh: the export of the descriptors' rows is the checked-in file.
#[test]
fn the_export_of_the_descriptor_rows_is_the_checked_in_file() {
    let document = document();
    let mut catalog = Vec::new();
    all_keys(&document, &mut catalog);
    let rows = file_rows().into_iter().map(descriptor_row).collect();
    let answer = call("schema.export", &export_request(rows, catalog)).expect("exports");
    let text = answer["text"].as_str().unwrap_or_else(|| panic!("no text: {answer}"));
    if text != SCHEMA_TEXT {
        let (ours, theirs): (Vec<_>, Vec<_>) =
            (text.lines().collect(), SCHEMA_TEXT.lines().collect());
        let first = ours.iter().zip(&theirs).position(|(a, b)| a != b).unwrap_or(ours.len());
        panic!(
            "export differs at line {}: ours {:?}, file {:?}",
            first + 1,
            ours.get(first),
            theirs.get(first)
        );
    }
}

/// missingKeyFailsTheExport.
#[test]
fn a_missing_catalog_key_fails_the_export() {
    let rows = file_rows().into_iter().take(3).map(descriptor_row).collect();
    let answer = call("schema.export", &export_request(rows, Vec::new())).expect("answers");
    let missing = answer["missing"].as_array().expect("missing keys");
    assert!(!missing.is_empty());
    let keys: Vec<&str> = missing.iter().filter_map(Value::as_str).collect();
    let mut sorted = keys.clone();
    sorted.sort_unstable();
    sorted.dedup();
    assert_eq!(keys, sorted);
    assert!(answer.get("text").is_none());
}

/// everyRowDeclaresSurfaceParity.
#[test]
fn every_row_declares_its_surfaces() {
    for row in file_rows() {
        let key = row["key"].as_str().expect("key").to_owned();
        let embedded = row["surfaces"].clone();
        let descriptor = Value::Object(descriptor_row(row));
        let facts = SurfaceFacts::of(&descriptor).expect("facts");
        assert_eq!(surfaces(&facts), embedded, "{key}");
    }
}

#[test]
fn the_surfaces_op_matches_the_plan() {
    let toggle = op_surfaces(json!({
        "key": "a.b", "kind": "toggle", "consumers": ["cmux-next"], "agent_settable": true,
    }));
    assert_eq!(toggle["palette"]["operations"], json!(["palette.toggleSetting"]));
    assert_eq!(toggle["palette"]["row"], json!("setting:a.b"));
    assert_eq!(toggle["palette"]["editor"], json!("toggle"));
    assert_eq!(toggle["palette"]["offered"], json!(true));
    assert_eq!(
        toggle["mcp"]["operations"],
        json!(MCP_READ.iter().chain(&MCP_WRITE).collect::<Vec<_>>())
    );
    assert_eq!(toggle["mcp"]["aliases"], json!(["settings.unset"]));
    assert_eq!(toggle["mcp"]["reason"], Value::Null);

    let choice = op_surfaces(json!({
        "key": "a.c", "kind": "choice", "consumers": ["cmux-next"], "agent_settable": false,
    }));
    assert_eq!(choice["palette"]["operations"], json!([]));
    assert_eq!(choice["palette"]["editor"], json!("options"));
    assert_eq!(choice["palette"]["offered"], json!(true));
    assert_eq!(choice["mcp"]["operations"], json!(["settings.list", "settings.get"]));
    assert_eq!(choice["mcp"]["reason"], json!("agent_settable_false"));
    assert_eq!(choice["socket"]["app_operations"], json!(APP_OPERATIONS));
    assert_eq!(choice["cli"]["aliases"], json!(["settings.unset"]));

    let hidden = op_surfaces(json!({
        "key": "a.d", "kind": "toggle", "consumers": ["cmux-next"], "agent_settable": false,
        "palette_hidden": "dangerous",
    }));
    assert_eq!(hidden["palette"]["offered"], json!(false));
    assert_eq!(hidden["palette"]["reason"], json!("dangerous"));
    assert_eq!(hidden["palette"]["row"], Value::Null);

    let elsewhere = op_surfaces(json!({
        "key": "a.e", "kind": "toggle", "consumers": ["cmux-browser"], "agent_settable": false,
    }));
    assert_eq!(elsewhere["palette"]["reason"], json!("not_consumed_by_cmux_next"));
    assert_eq!(elsewhere["palette"]["offered"], json!(false));
}

fn op_surfaces(request: Value) -> Value {
    call("schema.surfaces", &request).expect("surfaces")["surfaces"].clone()
}

/// everyRowHasConformanceSamples: the row's validator accepts every accept sample and refuses
/// every refuse sample, and every row refuses something.
#[test]
fn every_row_has_conformance_samples() {
    for row in file_rows() {
        let key = row["key"].as_str().expect("key").to_owned();
        let parsed = Row::from_export(Value::Object(row.clone())).expect("row parses");
        let (accept, refuse) = samples(&row);
        assert!(!refuse.is_empty(), "{key} has no refused sample");
        for value in &accept {
            assert!(accepts(&parsed, value), "{key}: accept sample {value} is refused");
        }
        for value in &refuse {
            assert!(!accepts(&parsed, value), "{key}: refuse sample {value} is accepted");
        }
        assert_eq!(Value::Array(accept), row["accepts"], "{key}: accepts");
        assert_eq!(Value::Array(refuse), row["refuses"], "{key}: refuses");
    }
}

#[test]
fn row_facts_answer_validation_and_reset() {
    assert!(kept_on_reset_all("appearance.theme"));
    assert!(kept_on_reset_all("terminal.fontSize"));
    assert!(!kept_on_reset_all("terminal.cursorStyle"));
    assert_eq!(validation("no.such", "theme"), "domain:theme");
    assert_eq!(validation("no.such", "toggle"), "portable");
}

// MARK: the writer

fn text(value: Value, pretty: bool) -> String {
    call("schema.json_text", &json!({"value": value, "pretty": pretty})).expect("writes")["text"]
        .as_str()
        .expect("text")
        .to_owned()
}

#[test]
fn numbers_print_in_their_shortest_form() {
    // Swift's description, with the exponent's sign and padding dropped.
    let cases: [(f64, &str); 11] = [
        (1.0, "1"),
        (-3.0, "-3"),
        (0.5, "0.5"),
        (0.1, "0.1"),
        (1.25, "1.25"),
        (0.0001, "0.0001"),
        (0.00001, "1e-5"),
        (1e-7, "1e-7"),
        (1e15, "1000000000000000.0"),
        (1.5e17, "1.5e17"),
        (-2.5e-6, "-2.5e-6"),
    ];
    for (value, expected) in cases {
        assert_eq!(double_text(value).expect("finite"), expected, "{value}");
    }
    assert_eq!(text(json!(7), false), "7");
    assert_eq!(text(json!(2.0), false), "2");
    assert!(matches!(double_text(f64::NAN), Err(OpError::Invalid(_))));
    assert!(matches!(double_text(f64::INFINITY), Err(OpError::Invalid(_))));
}

#[test]
fn strings_escape_only_quotes_backslashes_and_controls() {
    assert_eq!(
        text(json!("a\"b\\c\nd\re\tf\u{8}g\u{c}h\u{1}i/j é"), false),
        "\"a\\\"b\\\\c\\nd\\re\\tf\\bg\\fh\\u0001i/j é\""
    );
}

#[test]
fn keys_sort_case_insensitively_then_by_scalar() {
    assert_eq!(
        text(json!({"b": 1, "B": 2, "a": 3, "C": 4}), false),
        "{\"a\":3,\"B\":2,\"b\":1,\"C\":4}"
    );
    let mut keys = vec!["Zeta", "alpha", "Alpha", "beta"];
    keys.sort_by(|a, b| key_order(a, b));
    assert_eq!(keys, ["Alpha", "alpha", "beta", "Zeta"]);
}

#[test]
fn pretty_layout_matches_json_serialization() {
    assert_eq!(text(json!({}), true), "{\n\n}");
    assert_eq!(text(json!([]), true), "[\n\n]");
    assert_eq!(
        text(json!({"a": [1, {}], "b": null}), true),
        "{\n  \"a\" : [\n    1,\n    {\n\n    }\n  ],\n  \"b\" : null\n}"
    );
    assert_eq!(text(json!({"a": [1, true]}), false), "{\"a\":[1,true]}");
}

#[test]
fn missing_keys_skip_settings_values() {
    let document = json!({
        "title": {"text": "T", "key": "k.title"},
        "default": {"text": "x", "key": "not.a.text"},
        "accepts": [{"text": "x", "key": "no"}],
        "rows": [{"help": {"text": "H", "key": "k.help"}}],
    });
    let catalog: BTreeSet<&str> = ["k.title"].into_iter().collect();
    assert_eq!(missing_keys(&document, &catalog), ["k.help"]);
}
