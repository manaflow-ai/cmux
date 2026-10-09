//! The answers rule (CmuxNextAgentPane `AcpmuxPaneMethods+Answers.swift`,
//! plans/cmux-next/agent-questions.md): what `answers` on
//! `_acpmux/permission_respond` may be. The daemon checks an answer against
//! its question again; the host refuses everything a question card cannot
//! have sent, before the daemon sees it. The bounds are `policy.json`
//! `question_answers` ([`crate::data::QuestionAnswers`]).

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
/// UTF-8 bytes, and the strings of one list are bounded together by the same
/// limit.
pub fn breaks_answers_rule(object: &Map<String, Value>, options: &PermissionOptions) -> bool {
    let rule = &policy().question_answers;
    if object.get("method").and_then(Value::as_str) != Some(rule.method.as_str()) {
        return false;
    }
    let Some(params) = object.get("params").and_then(Value::as_object) else { return false };
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

/// A list of at most `maximum_list_strings` strings of at most
/// `maximum_value_bytes` UTF-8 bytes together.
fn fits_list(rule: &QuestionAnswers, value: &Value) -> bool {
    let Some(list) = value.as_array() else { return false };
    if list.len() > rule.maximum_list_strings {
        return false;
    }
    let bytes: Option<usize> = list.iter().map(|s| s.as_str().map(str::len)).sum();
    bytes.is_some_and(|total| total <= rule.maximum_value_bytes)
}
