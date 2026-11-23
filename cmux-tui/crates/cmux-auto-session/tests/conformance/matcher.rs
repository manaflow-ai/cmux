//! Whether an answer is the one the vectors expect.

use cmux_auto_session::cloud::{AutoCloudError, CloudResult};
use serde_json::{Value, json};

use crate::vectors::Step;

/// How `actual` differs from `expected`, or None when it matches: an object by the keys the
/// vectors name (a field the answer leaves out reads as null), a list item by item, anything
/// else by value.
pub fn differs(expected: &Value, actual: &Value, at: &str) -> Option<String> {
    let unlike = || Some(format!("{at}: expected {expected}, got {actual}"));
    match (expected, actual) {
        (Value::Object(named), Value::Object(got)) => named.iter().find_map(|(key, expected)| {
            differs(expected, got.get(key).unwrap_or(&Value::Null), &format!("{at}.{key}"))
        }),
        (Value::Array(items), Value::Array(got)) if items.len() == got.len() => {
            let mut pairs = items.iter().zip(got).enumerate();
            pairs.find_map(|(n, (expected, actual))| {
                differs(expected, actual, &format!("{at}[{n}]"))
            })
        }
        (Value::Object(_) | Value::Array(_), _) => unlike(),
        _ if expected == actual => None,
        _ => unlike(),
    }
}

/// A refusal as the route's JSON body has it beside `error`.
fn refusal_body(error: &AutoCloudError) -> Value {
    match error {
        AutoCloudError::Http { session, last_seq, missing, .. } => {
            json!({ "session": session, "lastSeq": last_seq, "missing": missing })
        }
        AutoCloudError::Transport { .. } | AutoCloudError::Decoding { .. } => Value::Null,
    }
}

/// The step's answer against its `expect`, or its refusal against its `refuse`.
pub fn check(step: &Step, got: &CloudResult<Value>) -> Result<(), String> {
    let unmatched = |difference: Option<String>| difference.map_or(Ok(()), Err);
    match (&step.refuse, got) {
        (None, Ok(answer)) => {
            unmatched(step.expect.as_ref().and_then(|expected| differs(expected, answer, "answer")))
        }
        (None, Err(error)) => Err(format!("expected an answer, was refused: {error}")),
        (Some(refuse), Ok(answer)) => {
            Err(format!("expected {} {}, was answered {answer}", refuse.status, refuse.code))
        }
        (Some(refuse), Err(error)) => {
            let raw_code = match error {
                AutoCloudError::Http { raw_code, .. } => raw_code.as_str(),
                AutoCloudError::Transport { .. } | AutoCloudError::Decoding { .. } => "",
            };
            if error.status() != Some(refuse.status) || raw_code != refuse.code {
                return Err(format!("expected {} {}, got: {error}", refuse.status, refuse.code));
            }
            let mut named = serde_json::Map::new();
            if let Some(last_seq) = refuse.last_seq {
                named.insert("lastSeq".to_owned(), json!(last_seq));
            }
            if let Some(missing) = &refuse.missing {
                named.insert("missing".to_owned(), json!(missing));
            }
            if let Some(session) = &refuse.session {
                named.insert("session".to_owned(), session.clone());
            }
            unmatched(differs(&Value::Object(named), &refusal_body(error), "refusal"))
        }
    }
}

#[test]
fn an_object_matches_by_the_keys_named_and_a_list_item_by_item() {
    let same = |expected: Value, actual: Value| differs(&expected, &actual, "answer").is_none();
    assert!(same(json!({"a": 1, "b": {"c": null}}), json!({"a": 1, "b": {}, "d": 2})));
    assert!(same(json!({"a": [{"k": 1}]}), json!({"a": [{"k": 1, "more": 2}]})));
    assert!(!same(json!({"a": []}), json!({"a": [1]})));
    assert!(!same(json!({"a": 1}), json!({"a": 2})));
    assert!(!same(json!({"a": {"b": 1}}), json!({"a": null})));
}
