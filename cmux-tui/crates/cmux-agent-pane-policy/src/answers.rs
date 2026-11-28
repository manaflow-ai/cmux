//! The answers rule (CmuxNextAgentPane `AcpmuxPaneMethods+Answers.swift`,
//! plans/cmux-next/agent-questions.md): what `answers` on
//! `_acpmux/permission_respond` may be. The daemon checks an answer against
//! its question again; the host refuses everything a question card cannot
//! have sent, before the daemon sees it. The bounds are `policy.json`
//! `question_answers` ([`crate::data::QuestionAnswers`]). The same rule
//! covers a question's `annotations` ([`breaks_annotations_rule`]).

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
    let rule = &policy().question_answers;
    if rule.method.is_empty() {
        return object.get("params").and_then(Value::as_object).is_some_and(|params| {
            params.contains_key("answers") || params.contains_key("annotations")
        });
    }
    if object.get("method").and_then(Value::as_str) != Some(rule.method.as_str()) {
        return false;
    }
    let Some(params) = object.get("params").and_then(Value::as_object) else { return false };
    if let Some(annotations) = params.get(&rule.annotations_param)
        && breaks_annotations_rule(rule, annotations, params, options)
    {
        return true;
    }
    let Some(raw) = params.get(&rule.param) else { return false };
    let Some(permission) = params.get("permissionId").and_then(Value::as_str) else { return true };
    let Some(keys) = options.question_keys(permission) else { return true };
    let Some(answers) = raw.as_object() else { return true };
    if !(1..=rule.maximum_items).contains(&answers.len()) {
        return true;
    }
    answers.iter().any(|(key, value)| {
        key.len() > rule.maximum_value_bytes || !keys.contains(key) || !fits_answer(rule, value)
    })
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
fn breaks_annotations_rule(
    rule: &QuestionAnswers,
    raw: &Value,
    params: &Map<String, Value>,
    options: &PermissionOptions,
) -> bool {
    if !params.contains_key(&rule.param) {
        return true;
    }
    let Some(permission) = params.get("permissionId").and_then(Value::as_str) else { return true };
    let Some(keys) = options.question_keys(permission) else { return true };
    let Some(annotations) = raw.as_object() else { return true };
    if !(1..=rule.maximum_items).contains(&annotations.len()) {
        return true;
    }
    annotations.iter().any(|(key, value)| {
        let Some(note) = value.as_object().filter(|n| !n.is_empty()) else { return true };
        !keys.contains(key)
            || note.iter().any(|(field, text)| {
                !matches!(field.as_str(), "preview" | "notes")
                    || text.as_str().is_none_or(|t| t.len() > rule.maximum_annotation_bytes)
            })
    })
}
