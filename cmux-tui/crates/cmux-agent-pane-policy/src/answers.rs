//! The answers rule (CmuxNextAgentPane `AcpmuxPaneMethods+Answers.swift`,
//! plans/cmux-next/agent-questions.md): what `answers` on
//! `_acpmux/permission_respond` may be. The daemon checks an answer against
//! its question again; the host refuses everything a question card cannot
//! have sent, before the daemon sees it. The bounds are `policy.json`
//! `question_answers` ([`crate::data::QuestionAnswers`]). The same rule
//! covers a question's `annotations` ([`annotations_rule_violation`]).

use crate::data::{QuestionAnswers, policy};
use crate::gesture::PermissionOptions;
use serde_json::{Map, Value};

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
    answers_rule_violation(object, options).is_some()
}

/// The value-free reason a permission answer or annotation breaks its rule,
/// matching Swift's `answersRuleViolation`.
pub fn answers_rule_violation(
    object: &Map<String, Value>,
    options: &PermissionOptions,
) -> Option<String> {
    let rule = &policy().question_answers;
    if rule.method.is_empty() {
        return object.get("params").and_then(Value::as_object).and_then(|params| {
            (params.contains_key("answers") || params.contains_key("annotations"))
                .then(|| "question answers policy is unavailable".into())
        });
    }
    if object.get("method").and_then(Value::as_str) != Some(rule.method.as_str()) {
        return None;
    }
    let Some(params) = object.get("params").and_then(Value::as_object) else { return None };
    if let Some(annotations) = params.get(&rule.annotations_param)
        && let Some(violation) = annotations_rule_violation(rule, annotations, params, options)
    {
        return Some(violation);
    }
    let Some(raw) = params.get(&rule.param) else { return None };
    let Some(permission) = params.get("permissionId").and_then(Value::as_str) else {
        return Some("answers without a permissionId".into());
    };
    let Some(keys) = options.question_keys(permission) else {
        return Some("answers for no pending question".into());
    };
    let Some(answers) = raw.as_object() else {
        return Some(format!("answers not an object of 1 to {} items", rule.maximum_items));
    };
    if !(1..=rule.maximum_items).contains(&answers.len()) {
        return Some(format!("answers not an object of 1 to {} items", rule.maximum_items));
    }
    for (key, value) in answers {
        if key.len() > rule.maximum_value_bytes {
            return Some(format!("answers item key over {} bytes", rule.maximum_value_bytes));
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
    options: &PermissionOptions,
) -> Option<String> {
    if !params.contains_key(&rule.param) {
        return Some("annotations without answers".into());
    }
    let Some(permission) = params.get("permissionId").and_then(Value::as_str) else {
        return Some("annotations without a permissionId".into());
    };
    let Some(keys) = options.question_keys(permission) else {
        return Some("annotations for no pending question".into());
    };
    let Some(annotations) = raw.as_object() else {
        return Some(format!("annotations not an object of 1 to {} items", rule.maximum_items));
    };
    if !(1..=rule.maximum_items).contains(&annotations.len()) {
        return Some(format!("annotations not an object of 1 to {} items", rule.maximum_items));
    }
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
            if text.as_str().is_none_or(|t| t.len() > rule.maximum_annotation_bytes) {
                return Some(format!(
                    "annotations item {field} not a string of at most {} bytes",
                    rule.maximum_annotation_bytes
                ));
            }
        }
    }
    None
}
