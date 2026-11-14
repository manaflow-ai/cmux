//! The question a terminal agent asks (Claude Code's AskUserQuestion, a Codex
//! `request_user_input`), read from its hook before redaction so a phone can
//! show and answer it (cmux-next-ios `verify/rich-push.md`, "Terminal agents").
//!
//! Like the live prompt it travels beside the journal event
//! (`session.journal.append` `live_question`) and is kept in daemon memory only
//! while the agent waits (`agent_prompts.rs`): the journal, the notification
//! ledger and the logs never see it. The shape is CmuxAgentQuestion's tool
//! input (`questions: [{question, header, options: [{label, description}],
//! multiSelect}]`), cleaned and bounded:
//!
//! ```json
//! {"harness":"claude","tool_use_id":"toolu_1","questions":[{"question":"Which branch?","header":"Branch",
//!   "multiSelect":false,"options":[{"label":"main","description":"the default"}]}]}
//! ```

use cmux_json::JsonSet as _;
use serde_json::{Map, Value, json};

/// Questions kept at most (Claude Code asks at most 4).
pub const MAX_QUESTIONS: usize = 4;
/// Options kept per question.
pub const MAX_OPTIONS: usize = 8;
const QUESTION_CHARS: usize = 1000;
const HEADER_CHARS: usize = 60;
const LABEL_CHARS: usize = 200;
const DESCRIPTION_CHARS: usize = 400;
const ID_CHARS: usize = 128;
/// The whole question as JSON text, at most.
pub const MAX_QUESTION_JSON_BYTES: usize = 16 * 1024;

/// The tools whose input is a question for the person.
fn is_question_tool(tool: &str) -> Option<&'static str> {
    match crate::agent_hooks::semantic_key(tool).as_str() {
        "askuserquestion" => Some("claude"),
        "requestuserinput" => Some("codex"),
        _ => None,
    }
}

fn text(value: Option<&Value>, limit: usize) -> Option<String> {
    let shown = crate::program_status::shown_text(value?.as_str()?.trim(), limit);
    (!shown.is_empty()).then_some(shown)
}

fn first<'a>(native: &'a Value, keys: &[&str]) -> Option<&'a Value> {
    keys.iter().find_map(|key| native.get(*key)).filter(|value| !value.is_null())
}

/// The question in a hook's payload, as compact JSON text, or `None` when the
/// payload is no question for the person (any other tool, no questions, or a
/// question with no text). Claude Code fires PreToolUse and PermissionRequest
/// for one AskUserQuestion; both carry the same input.
pub fn agent_hook_live_question(native_event: &str, native: &Value) -> Option<String> {
    let event = crate::agent_hooks::semantic_key(native_event);
    if !matches!(event.as_str(), "pretooluse" | "permissionrequest" | "notification") {
        return None;
    }
    let tool = first(native, &["tool_name", "toolName"])?.as_str()?;
    let harness = is_question_tool(tool)?;
    let input = first(native, &["tool_input", "toolInput", "input"])?;
    let questions = input.get("questions")?.as_array()?;
    let questions: Vec<Value> = questions
        .iter()
        .take(MAX_QUESTIONS)
        .filter_map(|question| {
            let prompt = text(question.get("question"), QUESTION_CHARS)?;
            let options: Vec<Value> = question
                .get("options")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .take(MAX_OPTIONS)
                .filter_map(|option| {
                    let label = text(option.get("label"), LABEL_CHARS)?;
                    let mut out = Map::new();
                    out.insert("label".into(), Value::String(label));
                    if let Some(description) = text(option.get("description"), DESCRIPTION_CHARS) {
                        out.insert("description".into(), Value::String(description));
                    }
                    Some(Value::Object(out))
                })
                .collect();
            let mut out = Map::new();
            if let Some(id) = text(question.get("id"), ID_CHARS) {
                out.insert("id".into(), Value::String(id));
            }
            out.insert("question".into(), Value::String(prompt));
            if let Some(header) = text(question.get("header"), HEADER_CHARS) {
                out.insert("header".into(), Value::String(header));
            }
            out.insert(
                "multiSelect".into(),
                Value::Bool(question.get("multiSelect").and_then(Value::as_bool).unwrap_or(false)),
            );
            if let Some(other) = question.get("isOther").and_then(Value::as_bool) {
                out.insert("isOther".into(), Value::Bool(other));
            }
            out.insert("options".into(), Value::Array(options));
            Some(Value::Object(out))
        })
        .collect();
    if questions.is_empty() {
        return None;
    }
    let mut out = json!({"harness": harness, "questions": questions});
    if let Some(id) = text(first(native, &["tool_use_id", "toolUseId"]), ID_CHARS) {
        out.set("tool_use_id", Value::String(id));
    }
    fit(out)
}

/// See `the_second_hook_keeps_the_first_hooks_tool_use_id`.
pub(crate) fn carry_tool_use_id(question: &mut Value, previous: Option<&Value>) {
    if question.get("tool_use_id").is_some() {
        return;
    }
    let Some(previous) = previous else { return };
    if previous.get("questions") != question.get("questions") {
        return;
    }
    if let (Some(id), Some(object)) = (previous.get("tool_use_id"), question.as_object_mut()) {
        object.insert("tool_use_id".into(), id.clone());
    }
}

/// `question` as JSON text within `MAX_QUESTION_JSON_BYTES`: option descriptions go
/// first, then the last questions; never a question cut mid-text.
fn fit(mut question: Value) -> Option<String> {
    let encoded = serde_json::to_string(&question).ok()?;
    if encoded.len() <= MAX_QUESTION_JSON_BYTES {
        return Some(encoded);
    }
    for item in question.get_mut("questions").and_then(Value::as_array_mut)?.iter_mut() {
        for option in item.get_mut("options").and_then(Value::as_array_mut).into_iter().flatten() {
            option.as_object_mut().map(|option| option.remove("description"));
        }
    }
    loop {
        let encoded = serde_json::to_string(&question).ok()?;
        if encoded.len() <= MAX_QUESTION_JSON_BYTES {
            return Some(encoded);
        }
        let questions = question.get_mut("questions").and_then(Value::as_array_mut)?;
        if questions.len() <= 1 {
            return None;
        }
        questions.pop();
    }
}

/// `text` (a `live_question`) as the question the daemon keeps: valid JSON
/// with at least one question, within the byte bound. A hook that skipped
/// `agent_hook_live_question` cannot plant anything else.
pub(crate) fn kept_question(text: &str) -> Option<Value> {
    if text.len() > MAX_QUESTION_JSON_BYTES {
        return None;
    }
    let value: Value = serde_json::from_str(text).ok()?;
    let questions = value.get("questions")?.as_array()?;
    (!questions.is_empty() && questions.len() <= MAX_QUESTIONS).then_some(value)
}

#[cfg(test)]
mod tests;
