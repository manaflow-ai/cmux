//! The answers rule (the Swift relay calls it through the `frame_rules` op,
//! plans/cmux-next/agent-questions.md): what `answers` on
//! `_acpmux/permission_respond` may be. The daemon checks an answer against
//! its question again; the host refuses everything a question card cannot
//! have sent, before the daemon sees it. The bounds are `policy.json`
//! `question_answers` ([`crate::data::QuestionAnswers`]). The same rule
//! covers a question's `annotations` ([`answers_rule_violation`]).

use crate::data::{QuestionAnswers, policy};
use crate::gesture::PermissionOptions;
use serde_json::{Map, Value};
use std::collections::BTreeSet;

/// Whether a page frame's `answers` breaks the rule (Swift
/// `breaksAnswersRule`). Answers go only to a pending question the daemon
/// sent this pane ([`PermissionOptions::question_keys`]), never to a tool
/// permission. They are an object of 1 to `maximum_items` of the question's
/// own items (an item id or prompt), and each value is a string, a list of at
/// most `maximum_list_strings` strings, or Codex's `{answers: [string]}` with
/// that one key. Each key and each string is at most `maximum_value_bytes`
/// UTF-8 bytes (per string: a list's strings are not counted together). A
/// policy that did not parse (an empty `method`) refuses every frame that
/// carries `answers`.
pub fn breaks_answers_rule(object: &Map<String, Value>, options: &PermissionOptions) -> bool {
    answers_rule_violation(object, |permission| options.question_keys(permission)).is_some()
}

/// Which part of the answers rule a page frame breaks, for the refusal's
/// detail and the log ([`breaks_answers_rule`]); None when it keeps it.
/// `question_keys` gives a pending question's item keys by its permission
/// id (None: no question pending under that id). Never names an answer.
pub fn answers_rule_violation(
    object: &Map<String, Value>,
    question_keys: impl Fn(&str) -> Option<BTreeSet<String>>,
) -> Option<String> {
    let rule = &policy().question_answers;
    if rule.method.is_empty() {
        let carries = object.get("params").and_then(Value::as_object).is_some_and(|params| {
            params.contains_key("answers") || params.contains_key("annotations")
        });
        return carries.then(|| "answers rule did not load".into());
    }
    if object.get("method").and_then(Value::as_str) != Some(rule.method.as_str()) {
        return None;
    }
    let params = object.get("params").and_then(Value::as_object)?;
    if let Some(annotations) = params.get(&rule.annotations_param)
        && let Some(violation) =
            annotations_rule_violation(rule, annotations, params, &question_keys)
    {
        return Some(violation);
    }
    let raw = params.get(&rule.param)?;
    let Some(permission) = params.get("permissionId").and_then(Value::as_str) else {
        return Some("answers without a permissionId".into());
    };
    let Some(keys) = question_keys(permission) else {
        return Some("answers for no pending question".into());
    };
    let items = rule.maximum_items;
    let Some(answers) = raw.as_object().filter(|a| (1..=items).contains(&a.len())) else {
        return Some(format!("answers not an object of 1 to {items} items"));
    };
    let bytes = rule.maximum_value_bytes;
    for (key, value) in answers {
        if key.len() > bytes {
            return Some(format!("answers item key over {bytes} bytes"));
        }
        if !keys.contains(key) {
            return Some("answers item not one of the question's".into());
        }
        if !fits_answer(rule, value) {
            return Some("answers item value not a bounded string, list or {answers}".into());
        }
    }
    None
}

/// One item's value: a string, a list of strings, or `{answers: [string]}`.
fn fits_answer(rule: &QuestionAnswers, value: &Value) -> bool {
    match value {
        Value::Object(codex) => {
            codex.len() == 1 && codex.get("answers").is_some_and(|list| fits_list(rule, list))
        }
        Value::String(text) => text.len() <= rule.maximum_value_bytes,
        Value::Array(_) => fits_list(rule, value),
        _ => false,
    }
}

/// A list of at most `maximum_list_strings` strings, each at most
/// `maximum_value_bytes` UTF-8 bytes.
fn fits_list(rule: &QuestionAnswers, value: &Value) -> bool {
    value.as_array().is_some_and(|list| {
        list.len() <= rule.maximum_list_strings
            && list.iter().all(|s| s.as_str().is_some_and(|t| t.len() <= rule.maximum_value_bytes))
    })
}

/// Whether a frame's annotations (Claude Code's `{preview?, notes?}` per
/// question) break the rule (Swift `breaksAnnotationsRule`): only beside
/// `answers`, to a pending question, keyed by its own items, each value an
/// object of `preview` and `notes` strings of at most
/// `maximum_annotation_bytes` UTF-8 bytes.
fn annotations_rule_violation(
    rule: &QuestionAnswers,
    raw: &Value,
    params: &Map<String, Value>,
    question_keys: &impl Fn(&str) -> Option<BTreeSet<String>>,
) -> Option<String> {
    if !params.contains_key(&rule.param) {
        return Some("annotations without answers".into());
    }
    let Some(permission) = params.get("permissionId").and_then(Value::as_str) else {
        return Some("annotations without a permissionId".into());
    };
    let Some(keys) = question_keys(permission) else {
        return Some("annotations for no pending question".into());
    };
    let items = rule.maximum_items;
    let Some(annotations) = raw.as_object().filter(|a| (1..=items).contains(&a.len())) else {
        return Some(format!("annotations not an object of 1 to {items} items"));
    };
    let bytes = rule.maximum_annotation_bytes;
    for (key, value) in annotations {
        if !keys.contains(key) {
            return Some("annotations item not one of the question's".into());
        }
        let Some(note) = value.as_object().filter(|n| !n.is_empty()) else {
            return Some("annotations item not a non-empty object".into());
        };
        for (field, text) in note {
            if !matches!(field.as_str(), "preview" | "notes") {
                return Some("annotations item field other than preview or notes".into());
            }
            if text.as_str().is_none_or(|t| t.len() > bytes) {
                return Some(format!(
                    "annotations item {field} not a string of at most {bytes} bytes"
                ));
            }
        }
    }
    None
}
