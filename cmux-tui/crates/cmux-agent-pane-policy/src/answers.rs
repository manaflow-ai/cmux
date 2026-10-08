//! The answers rule (CmuxNextAgentPane `AcpmuxPaneMethods+Answers.swift`,
//! plans/cmux-next/agent-questions.md): what `answers` on
//! `_acpmux/permission_respond` may be. The daemon checks an answer against
//! its question again; the host refuses everything a question card cannot
//! have sent, before the daemon sees it.

use crate::gesture::PermissionOptions;
use serde_json::{Map, Value};

/// The most items one answer may hold.
pub const MAXIMUM_ANSWER_ITEMS: usize = 64;
/// The most strings one item's list may hold.
pub const MAXIMUM_ANSWER_LIST_STRINGS: usize = 64;
/// The most UTF-8 bytes of one item key, and of each string of an item's value.
pub const MAXIMUM_ANSWER_BYTES: usize = 4096;

/// Whether a page frame's `answers` breaks the rule (Swift
/// `breaksAnswersRule`). Answers go only to a pending question the daemon
/// sent this pane ([`PermissionOptions::question_keys`]), never to a tool
/// permission. They are an object of 1 to [`MAXIMUM_ANSWER_ITEMS`] of the
/// question's own items (an item id or prompt), and each value is a string,
/// a list of at most [`MAXIMUM_ANSWER_LIST_STRINGS`] strings, or Codex's
/// `{answers: [string]}` with that one key. Each key and each string is at
/// most [`MAXIMUM_ANSWER_BYTES`] UTF-8 bytes.
pub fn breaks_answers_rule(object: &Map<String, Value>, options: &PermissionOptions) -> bool {
    if object.get("method").and_then(Value::as_str) != Some("_acpmux/permission_respond") {
        return false;
    }
    let Some(params) = object.get("params").and_then(Value::as_object) else { return false };
    let Some(raw) = params.get("answers") else { return false };
    let Some(permission) = params.get("permissionId").and_then(Value::as_str) else { return true };
    let Some(keys) = options.question_keys(permission) else { return true };
    let Some(answers) = raw.as_object() else { return true };
    if !(1..=MAXIMUM_ANSWER_ITEMS).contains(&answers.len()) {
        return true;
    }
    answers.iter().any(|(key, value)| {
        key.len() > MAXIMUM_ANSWER_BYTES || !keys.contains(key) || !fits_answer(value)
    })
}

/// One item's value: a string, a list of strings, or `{answers: [string]}`.
fn fits_answer(value: &Value) -> bool {
    match value {
        Value::Object(codex) => codex.len() == 1 && codex.get("answers").is_some_and(fits_list),
        Value::String(text) => text.len() <= MAXIMUM_ANSWER_BYTES,
        Value::Array(_) => fits_list(value),
        _ => false,
    }
}

fn fits_list(value: &Value) -> bool {
    value.as_array().is_some_and(|list| {
        list.len() <= MAXIMUM_ANSWER_LIST_STRINGS
            && list.iter().all(|s| s.as_str().is_some_and(|t| t.len() <= MAXIMUM_ANSWER_BYTES))
    })
}
