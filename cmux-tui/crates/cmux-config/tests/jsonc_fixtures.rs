//! The shared JSONC fixture table (fixtures/jsonc-cases.json), ported from
//! Swift `JSONCTests`. A later Swift test reads the same file.

use cmux_config::jsonc::{self, JsoncError};
use cmux_config::keypath::key_path;
use cmux_config::value::{canonical, value_at};
use serde_json::Value;

const CASES: &str = include_str!("../fixtures/jsonc-cases.json");

fn strings(value: &Value) -> Vec<String> {
    value
        .as_array()
        .expect("array")
        .iter()
        .map(|item| item.as_str().expect("string").to_string())
        .collect()
}

fn error_name(error: &JsoncError) -> &'static str {
    match error {
        JsoncError::UnterminatedComment => "unterminated_comment",
        JsoncError::UnterminatedString => "unterminated_string",
        JsoncError::Malformed { .. } => "malformed",
        JsoncError::Json(_) => "json",
        JsoncError::RootIsNotObject => "root_is_not_object",
        JsoncError::EmptyPath => "empty_path",
    }
}

fn check_document(name: &str, case: &Value, document: &Value) {
    if let Some(expected) = case.get("expect_value") {
        assert_eq!(document, &canonical(expected.clone()), "{name}");
    }
    for entry in case.get("expect_values").and_then(Value::as_array).into_iter().flatten() {
        let path = strings(&entry["path"]);
        assert_eq!(
            value_at(document, &path),
            Some(&canonical(entry["value"].clone())),
            "{name}: {path:?}"
        );
    }
}

#[test]
fn every_shared_jsonc_case_passes() {
    let doc: Value = serde_json::from_str(CASES).expect("fixture file parses");
    let cases = doc["cases"].as_array().expect("cases");
    assert!(cases.len() >= 25, "fixture table lost cases");
    for case in cases {
        let name = case["name"].as_str().expect("name");
        match case["op"].as_str().expect("op") {
            "parse" => match jsonc::parse(case["source"].as_str().unwrap()) {
                Ok(value) => {
                    assert!(case.get("error").is_none(), "{name}: expected an error");
                    check_document(name, case, &value);
                }
                Err(error) => {
                    assert_eq!(Some(error_name(&error)), case["error"].as_str(), "{name}: {error}");
                }
            },
            op @ ("set" | "remove") => {
                let source = case["source"].as_str().unwrap();
                let path = strings(&case["path"]);
                let result = if op == "set" {
                    jsonc::set(source, &path, &canonical(case["value"].clone()))
                } else {
                    jsonc::remove(source, &path)
                };
                let text = match result {
                    Ok(text) => text,
                    Err(error) => {
                        assert_eq!(
                            Some(error_name(&error)),
                            case["error"].as_str(),
                            "{name}: {error}"
                        );
                        continue;
                    }
                };
                assert!(case.get("error").is_none(), "{name}: expected an error");
                if let Some(expected) = case.get("expect").and_then(Value::as_str) {
                    assert_eq!(text, expected, "{name}");
                }
                for needle in case.get("expect_contains").map(strings).unwrap_or_default() {
                    assert!(text.contains(&needle), "{name}: missing {needle:?} in {text:?}");
                }
                check_document(name, case, &jsonc::parse(&text).expect("edited text parses"));
            }
            "key_path" => {
                assert_eq!(
                    key_path(case["dotted"].as_str().unwrap()),
                    strings(&case["expect_path"]),
                    "{name}"
                );
            }
            other => panic!("{name}: unknown op {other}"),
        }
    }
}

#[test]
fn strip_keeps_line_structure_and_drops_trailing_commas() {
    let stripped = jsonc::strip("{\n  // c\n  \"a\": [1, 2,], /* x\n y */\n}").unwrap();
    assert_eq!(stripped, "{\n  \n  \"a\": [1, 2] \n\n}");
}

#[test]
fn empty_paths_are_refused() {
    assert_eq!(jsonc::set("{}", &[], &Value::Null), Err(JsoncError::EmptyPath));
    assert_eq!(jsonc::remove("{}", &[]), Err(JsoncError::EmptyPath));
}

#[test]
fn a_duplicate_key_edits_the_last_one_which_the_parser_reads() {
    let source = "{\"ui\": {\"animationSpeed\": \"off\", \"animationSpeed\": \"fast\"}}";
    let path = vec!["ui".to_string(), "animationSpeed".to_string()];
    let written = cmux_config::jsonc::set(source, &path, &serde_json::json!("normal")).unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&written).unwrap();
    assert_eq!(parsed["ui"]["animationSpeed"], "normal");
}
