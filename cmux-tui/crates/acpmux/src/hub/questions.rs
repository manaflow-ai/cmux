//! Agent questions inside permission requests (plans/cmux-next/agent-questions.md).
//!
//! Claude Code's AskUserQuestion and a Codex user-input request reach the
//! hub as `session/request_permission` with the questions in the tool input.
//! The hub adds one harness-neutral copy, `toolCall._meta.acpmux.question`
//! (`{harness, agent, items: [{id, header?, prompt, options: [{id, label,
//! detail?, preview?: {text, format}}], multiSelect, allowsOther}]}`), so
//! every client renders the same model, and it checks a client's `answers`
//! against it before they reach the agent.
//!
//! A question is never answered by policy: approve-all, approve rules and
//! the chat allowance do not apply to it (only deny-all and deny rules may
//! decline it), so an answer always comes from a person.

use crate::rpc::RpcError;
use serde_json::{Map, Value, json};

/// The normalized question of a request, when it carries one.
pub(super) fn question(request: &Value) -> Option<&Value> {
    request.pointer("/toolCall/_meta/acpmux/question").filter(|q| q["items"].is_array())
}

/// True when policy and batches must not answer the request: a question.
/// Other interactive requests (plan approval) keep their policy behavior.
pub(super) fn needs_person(request: &Value) -> bool {
    question(request).is_some()
        || matches!(
            request.pointer("/toolCall/_meta/claude/tool").and_then(Value::as_str),
            Some("AskUserQuestion")
        )
}

/// Checks a reply to `request`: answers go only with an allow option, and a
/// question is allowed only with answers (an empty allow would hand the
/// agent a blank answer nobody gave). A reject or a cancel needs none.
pub(super) fn check_reply(
    request: &Value,
    option_id: Option<&str>,
    answers: Option<&Value>,
) -> Result<(), RpcError> {
    let kind = option_id.and_then(|id| {
        request["options"].as_array()?.iter().find(|o| o["optionId"] == id)?["kind"].as_str()
    });
    let allows = kind.is_some_and(|k| k.starts_with("allow"));
    match answers {
        Some(_) if !allows => Err(RpcError::invalid_params("answers go only with an allow option")),
        Some(answers) => check_answers(request, answers),
        None if allows && needs_person(request) => Err(RpcError::invalid_params(
            "this is a question: answer it with `acpmux answer <session> --answer \"<question or id>=<choice>\"` (one --answer per question), in the agent tab or Home card, or decline it with `acpmux deny <session>`",
        )),
        None => Ok(()),
    }
}

/// The normalized items of Claude-shaped `questions` (`{question, header?,
/// options: [{label, description?, preview?}], multiSelect?}`), answered by
/// question text: the shape Grok's `x.ai/ask_user_question` also uses.
pub(super) fn items_by_text(questions: &[Value]) -> Vec<Value> {
    questions.iter().enumerate().filter_map(|(index, q)| item(q, index, false)).collect()
}

/// The normalized items of Codex-shaped `questions` (`{id, question,
/// options: [{label, description?}], multiSelect?, isOther?}`), answered by
/// item id with `{answers: [labels]}`: the shape Cursor's
/// `cursor/ask_question` maps onto.
pub(super) fn items_by_id(questions: &[Value]) -> Vec<Value> {
    questions.iter().enumerate().filter_map(|(index, q)| item(q, index, true)).collect()
}

/// Adds `toolCall._meta.acpmux.question` when the tool input holds
/// questions and no writer added one yet.
pub(super) fn normalize(request: &mut Value) {
    if question(request).is_some() {
        return;
    }
    let tool = &request["toolCall"];
    let questions =
        tool.pointer("/rawInput/questions").and_then(Value::as_array).cloned().unwrap_or_default();
    if questions.is_empty() {
        return;
    }
    let codex =
        tool.pointer("/_meta/codex").is_some() || questions.iter().any(|q| q["id"].is_string());
    let items: Vec<Value> =
        questions.iter().enumerate().filter_map(|(index, q)| item(q, index, codex)).collect();
    if items.is_empty() {
        return;
    }
    let (harness, agent) = if codex { ("codex", "Codex") } else { ("claude", "Claude Code") };
    let normalized = json!({"harness": harness, "agent": agent, "items": items});
    let Some(tool) = request.get_mut("toolCall").and_then(Value::as_object_mut) else { return };
    let meta = tool.entry("_meta").or_insert_with(|| json!({}));
    if !meta.is_object() {
        *meta = json!({});
    }
    if let Some(acpmux) =
        meta.as_object_mut().map(|m| m.entry("acpmux").or_insert_with(|| json!({})))
    {
        if !acpmux.is_object() {
            *acpmux = json!({});
        }
        if let Some(acpmux) = acpmux.as_object_mut() {
            acpmux.insert("question".into(), normalized);
        }
    }
}

fn text(value: &Value) -> Option<String> {
    value.as_str().map(str::trim).filter(|s| !s.is_empty()).map(str::to_owned)
}

fn item(q: &Value, index: usize, codex: bool) -> Option<Value> {
    // The prompt keeps its exact text: Claude Code matches answers by it.
    text(&q["question"])?;
    let prompt = q["question"].as_str()?.to_owned();
    let mut seen: Map<String, Value> = Map::new();
    let options: Vec<Value> = q["options"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|o| {
            let label = text(&o["label"])?;
            let count = seen.get(&label).and_then(Value::as_u64).unwrap_or(0) + 1;
            seen.insert(label.clone(), json!(count));
            let id = if count > 1 { format!("{label}#{count}") } else { label.clone() };
            let mut option = json!({"id": id, "label": label});
            if let Some(detail) = text(&o["description"]) {
                option["detail"] = json!(detail);
            }
            if let Some(preview) = text(&o["preview"]) {
                option["preview"] = json!({"text": preview, "format": "monospace"});
            }
            Some(option)
        })
        .collect();
    let id = if codex {
        text(&q["id"]).unwrap_or_else(|| format!("q{index}"))
    } else {
        format!("q{index}")
    };
    let allows_other =
        if codex { q["isOther"].as_bool().unwrap_or(false) || options.is_empty() } else { true };
    let mut item = json!({
        "id": id, "prompt": prompt, "options": options,
        "multiSelect": q["multiSelect"].as_bool().unwrap_or(false), "allowsOther": allows_other,
    });
    if let Some(header) = text(&q["header"]) {
        item["header"] = json!(header);
    }
    Some(item)
}

/// The most items one answer may hold.
pub(super) const MAX_ANSWER_ITEMS: usize = 64;
/// The most strings one item's list may hold.
pub(super) const MAX_ANSWER_LIST_STRINGS: usize = 64;
/// The most UTF-8 bytes of one item key, and of each string of an item's value.
pub(super) const MAX_ANSWER_BYTES: usize = 4096;

/// Checks a client's `answers` for `request`. Answers are accepted only for
/// a question, in the asking harness's shape: Claude Code (and the Chief) by
/// question text with one non-empty string each; Codex by item id with
/// `{answers: [string, ...]}`. Every item must be answered, nothing else.
/// The daemon bounds them itself (it does not trust a client's relay): at
/// most [`MAX_ANSWER_ITEMS`] items, [`MAX_ANSWER_LIST_STRINGS`] strings per
/// list and [`MAX_ANSWER_BYTES`] bytes per key or string, the limits of the
/// Swift pane relay (`AcpmuxPaneMethods+Answers`).
pub(super) fn check_answers(request: &Value, answers: &Value) -> Result<(), RpcError> {
    let invalid = |why: &str| Err(RpcError::invalid_params(format!("answers {why}")));
    let Some(question) = question(request) else {
        return invalid("are accepted only for a question");
    };
    let Some(answers) = answers.as_object() else { return invalid("must be an object") };
    if answers.len() > MAX_ANSWER_ITEMS {
        return invalid(&format!("may hold at most {MAX_ANSWER_ITEMS} items"));
    }
    let too_long = |text: &str| text.len() > MAX_ANSWER_BYTES;
    if answers.iter().any(|(key, value)| {
        too_long(key)
            || match value {
                Value::String(text) => too_long(text),
                Value::Object(codex) => {
                    codex.get("answers").and_then(Value::as_array).is_some_and(|list| {
                        list.len() > MAX_ANSWER_LIST_STRINGS
                            || list.iter().any(|s| s.as_str().is_some_and(too_long))
                    })
                }
                _ => false,
            }
    }) {
        return invalid(&format!(
            "may hold at most {MAX_ANSWER_LIST_STRINGS} strings per item and {MAX_ANSWER_BYTES} bytes per key or string"
        ));
    }
    let items = question["items"].as_array().cloned().unwrap_or_default();
    let codex = question["harness"] == "codex";
    let keys: Vec<String> = items
        .iter()
        .filter_map(|item| {
            if codex { text(&item["id"]) } else { item["prompt"].as_str().map(str::to_owned) }
        })
        .collect();
    if answers.len() != keys.len() || keys.iter().any(|k| !answers.contains_key(k)) {
        return invalid("must answer every question and nothing else");
    }
    for key in &keys {
        let value = &answers[key];
        let ok = if codex {
            // `{answers: [...]}` with that one key: nothing else rides along
            // into the agent's tool input unchecked.
            value.as_object().is_some_and(|o| o.len() == 1)
                && value["answers"]
                    .as_array()
                    .is_some_and(|list| !list.is_empty() && list.iter().all(|s| text(s).is_some()))
        } else {
            text(value).is_some()
        };
        if !ok {
            return invalid("must not be empty");
        }
    }
    Ok(())
}
