//! The plain keys of Swift `CmuxConfigSnapshot.parse`: one read of cmux-next.json answers every
//! true/false, choice and number key's value and its diagnostic, from the schema's kinds,
//! defaults and choices, so the ~150 one-key Swift `XxxSetting.parse(root)` functions go.
//!
//! - `snapshot.read` `{root | source, keys?, unquoted?}` answers `{values, diagnostics,
//!   retiredKeys}`, or `{problem}` when `source` is not JSONC. `root` is a parsed document;
//!   `source` its text (empty is `{}`). `values` maps each dotted key to its value: the
//!   file's when valid, else the schema default (a key with no default is left out), so Swift
//!   keeps its own fallback. `keys` limits the read (default: every toggle and choice row; a
//!   number row is read only when named). `unquoted` names choice keys whose diagnostic lists
//!   the values bare (`expected one of a, b`), as some Swift settings word it. A diagnostic is
//!   `{kind, path, message}` in Swift's wording: `expected true or false`,
//!   `expected one of "a", "b"`, `expected a number`, `clamped to LO...HI`. A root that is not
//!   an object answers one `unreadable_file` diagnostic and no values.
//!   `retiredKeys` are the retired keys the file still sets, sorted.

use std::collections::BTreeSet;

use serde_json::{Map, Value, json};

use super::{OpError, jsonc};
use crate::schema::{self, Kind, Row, Schema};
use crate::value::value_at;

/// The ops this area answers; `None` for an op of another area.
pub fn call(op: &str, request: &Value) -> Option<Result<Value, OpError>> {
    match op {
        "snapshot.read" => Some(read(request)),
        _ => None,
    }
}

fn names(request: &Value, key: &str) -> Result<Option<BTreeSet<String>>, OpError> {
    match request.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Array(items)) => items
            .iter()
            .map(|item| item.as_str().map(str::to_owned))
            .collect::<Option<BTreeSet<_>>>()
            .map(Some)
            .ok_or_else(|| OpError::Invalid(format!("expected a string array `{key}`"))),
        Some(_) => Err(OpError::Invalid(format!("expected a string array `{key}`"))),
    }
}

fn diagnostic(path: &str, message: &str) -> Value {
    json!({ "kind": "invalid_value", "path": path, "message": message })
}

/// Swift's `Double` description: a whole number keeps `.0`.
fn swift_double(number: f64) -> String {
    if number.fract() == 0.0 && number.abs() < 1e15 {
        format!("{number:.1}")
    } else {
        format!("{number}")
    }
}

fn read(request: &Value) -> Result<Value, OpError> {
    let root = match (request.get("root"), request.get("source")) {
        (Some(root), _) => root.clone(),
        (None, Some(_)) => {
            let parsed = jsonc::parse(request)?;
            match parsed.get("value") {
                Some(value) => value.clone(),
                None => return Ok(parsed),
            }
        }
        _ => return Err(OpError::Invalid("expected `root` or `source`".to_owned())),
    };
    if !root.is_object() {
        return Ok(json!({
            "values": {},
            "diagnostics": [{ "kind": "unreadable_file", "path": "", "message": "root is not an object" }],
            "retiredKeys": [],
        }));
    }
    let only = names(request, "keys")?;
    let unquoted = names(request, "unquoted")?.unwrap_or_default();
    let mut values = Map::new();
    let mut diagnostics = Vec::new();
    for row in &Schema::embedded().rows {
        let wanted = match &only {
            Some(keys) => keys.contains(&row.key),
            None => matches!(row.kind, Kind::Toggle | Kind::Choice(_)),
        };
        if !wanted {
            continue;
        }
        let (value, problem) =
            read_row(row, value_at(&root, &row.path), unquoted.contains(&row.key));
        if let Some(message) = problem {
            diagnostics.push(diagnostic(&row.key, &message));
        }
        if let Some(value) = value {
            values.insert(row.key.clone(), value);
        }
    }
    let mut retired: Vec<&str> = schema::retired_keys()
        .iter()
        .map(|(key, _)| key.as_str())
        .filter(|key| value_at(&root, &key.split('.').collect::<Vec<_>>()).is_some())
        .collect();
    retired.sort_unstable();
    Ok(json!({ "values": values, "diagnostics": diagnostics, "retiredKeys": retired }))
}

/// The value to use and the diagnostic, for the file's `found` value of `row`.
fn read_row(row: &Row, found: Option<&Value>, unquoted: bool) -> (Option<Value>, Option<String>) {
    let default = row.default.clone();
    let Some(found) = found else { return (default, None) };
    match &row.kind {
        Kind::Toggle => match found {
            Value::Bool(_) => (Some(found.clone()), None),
            _ => (default, Some("expected true or false".to_owned())),
        },
        Kind::Choice(choices) => match found.as_str() {
            Some(text) if choices.iter().any(|choice| choice.value == text) => {
                (Some(found.clone()), None)
            }
            _ => {
                let listed: Vec<String> = choices
                    .iter()
                    .map(|choice| {
                        if unquoted {
                            choice.value.clone()
                        } else {
                            format!("\"{}\"", choice.value)
                        }
                    })
                    .collect();
                (default, Some(format!("expected one of {}", listed.join(", "))))
            }
        },
        Kind::Number(range) => match found.as_f64().filter(|number| number.is_finite()) {
            None => (default, Some("expected a number".to_owned())),
            Some(number) => {
                let clamped = number.clamp(range.min, range.max);
                let note = (clamped != number).then(|| {
                    format!("clamped to {}...{}", swift_double(range.min), swift_double(range.max))
                });
                (Some(json!(clamped)), note)
            }
        },
        _ => (None, None),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn op(request: Value) -> Value {
        call("snapshot.read", &request).expect("an op of this area").expect("a reply")
    }

    #[test]
    fn absent_keys_answer_their_default_without_a_diagnostic() {
        let reply = op(json!({ "root": {} }));
        assert_eq!(reply["diagnostics"], json!([]));
        assert_eq!(reply["values"]["browser.showAgentCursor"], json!(true));
        assert_eq!(reply["values"]["ui.calm"], json!("off"));
    }

    #[test]
    fn a_bad_toggle_keeps_its_default_and_says_so() {
        let reply = op(json!({ "root": { "browser": { "showAgentCursor": "yes" } } }));
        assert_eq!(reply["values"]["browser.showAgentCursor"], json!(true));
        assert_eq!(
            reply["diagnostics"],
            json!([{ "kind": "invalid_value", "path": "browser.showAgentCursor",
                     "message": "expected true or false" }])
        );
    }

    #[test]
    fn a_set_toggle_is_taken() {
        let reply = op(json!({ "root": { "browser": { "showAgentCursor": false } } }));
        assert_eq!(reply["values"]["browser.showAgentCursor"], json!(false));
        assert_eq!(reply["diagnostics"], json!([]));
    }

    #[test]
    fn a_choice_lists_its_values_quoted_or_bare() {
        let bad = json!({ "root": { "ui": { "calm": "loud" } } });
        let reply = op(bad.clone());
        assert_eq!(reply["values"]["ui.calm"], json!("off"));
        assert_eq!(
            reply["diagnostics"][0]["message"],
            json!("expected one of \"off\", \"calm\", \"still\"")
        );
        let mut bare = bad;
        bare["unquoted"] = json!(["ui.calm"]);
        assert_eq!(
            op(bare)["diagnostics"][0]["message"],
            json!("expected one of off, calm, still")
        );
        let good = op(json!({ "root": { "ui": { "calm": "still" } } }));
        assert_eq!(good["values"]["ui.calm"], json!("still"));
    }

    #[test]
    fn a_named_number_clamps_and_says_so() {
        let row = Schema::embedded()
            .rows
            .iter()
            .find(|row| matches!(row.kind, Kind::Number(_)))
            .expect("a number row");
        let Kind::Number(range) = &row.kind else { unreachable!() };
        let root = crate::value::with_value(&json!({}), json!(range.max + 1000.0), &row.path);
        let reply = op(json!({ "root": root, "keys": [row.key] }));
        assert_eq!(reply["values"][&row.key], json!(range.max));
        assert_eq!(
            reply["diagnostics"][0]["message"],
            json!(format!("clamped to {}...{}", swift_double(range.min), swift_double(range.max)))
        );
        let root = crate::value::with_value(&json!({}), json!("x"), &row.path);
        let reply = op(json!({ "root": root, "keys": [row.key] }));
        assert_eq!(reply["diagnostics"][0]["message"], json!("expected a number"));
    }

    #[test]
    fn keys_limit_the_read() {
        let reply = op(json!({ "root": {}, "keys": ["ui.calm"] }));
        assert_eq!(reply["values"].as_object().map(Map::len), Some(1));
    }

    #[test]
    fn a_source_is_parsed_and_a_broken_one_is_a_problem() {
        let reply = op(json!({ "source": "{ // c\n \"ui\": { \"calm\": \"calm\" } }" }));
        assert_eq!(reply["values"]["ui.calm"], json!("calm"));
        assert!(op(json!({ "source": "{ \"ui\": " }))["problem"].is_string());
    }

    #[test]
    fn a_root_that_is_not_an_object_is_unreadable() {
        let reply = op(json!({ "root": [1] }));
        assert_eq!(reply["diagnostics"][0]["kind"], json!("unreadable_file"));
        assert_eq!(reply["diagnostics"][0]["message"], json!("root is not an object"));
    }

    #[test]
    fn swift_doubles_keep_their_point() {
        assert_eq!(swift_double(0.0), "0.0");
        assert_eq!(swift_double(1.5), "1.5");
        assert_eq!(swift_double(1000.0), "1000.0");
    }
}
