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
        out["tool_use_id"] = Value::String(id);
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
    for item in question["questions"].as_array_mut()?.iter_mut() {
        for option in item["options"].as_array_mut().into_iter().flatten() {
            option.as_object_mut().map(|option| option.remove("description"));
        }
    }
    loop {
        let encoded = serde_json::to_string(&question).ok()?;
        if encoded.len() <= MAX_QUESTION_JSON_BYTES {
            return Some(encoded);
        }
        let questions = question["questions"].as_array_mut()?;
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
mod tests {
    use super::*;

    /// Claude Code fires PreToolUse (with `tool_use_id`) then PermissionRequest (without
    /// it, seen live in 2.1.309) for one AskUserQuestion. The second keeps the first's
    /// tool use id, so the phone matches an answer to that very question.
    #[test]
    fn the_second_hook_keeps_the_first_hooks_tool_use_id() {
        let first = json!({"harness":"claude","tool_use_id":"toolu_A","questions":[{"question":"Which?","options":[]}]});
        let mut second =
            json!({"harness":"claude","questions":[{"question":"Which?","options":[]}]});
        carry_tool_use_id(&mut second, Some(&first));
        assert_eq!(second["tool_use_id"], "toolu_A");
        // Another question keeps none; one with its own id keeps its own.
        let mut other =
            json!({"harness":"claude","questions":[{"question":"Other?","options":[]}]});
        carry_tool_use_id(&mut other, Some(&first));
        assert!(other.get("tool_use_id").is_none());
        let mut own = json!({"harness":"claude","tool_use_id":"toolu_B","questions":[{"question":"Which?","options":[]}]});
        carry_tool_use_id(&mut own, Some(&first));
        assert_eq!(own["tool_use_id"], "toolu_B");
    }

    fn claude(event: &str) -> Value {
        json!({
            "session_id": "s1",
            "hook_event_name": event,
            "tool_name": "AskUserQuestion",
            "tool_use_id": "toolu_1",
            "tool_input": {"questions": [
                {"question": "Which branch\u{202e}?", "header": "Branch", "multiSelect": false,
                 "options": [{"label": "main", "description": "the default"}, {"label": "dev"}, {"label": "release"}]},
                {"question": "Which checks?", "header": "Checks", "multiSelect": true,
                 "options": [{"label": "lint"}, {"label": "tests"}]}
            ]}
        })
    }

    #[test]
    fn claude_ask_user_question_is_kept_cleaned() {
        let kept: Value = serde_json::from_str(
            &agent_hook_live_question("PreToolUse", &claude("PreToolUse")).unwrap(),
        )
        .unwrap();
        assert_eq!(kept["harness"], "claude");
        assert_eq!(kept["tool_use_id"], "toolu_1");
        let first = &kept["questions"][0];
        // Bidi controls are dropped from shown text.
        assert_eq!(first["question"], "Which branch?");
        assert_eq!(first["header"], "Branch");
        assert_eq!(first["multiSelect"], false);
        assert_eq!(first["options"][0], json!({"label":"main","description":"the default"}));
        assert_eq!(first["options"].as_array().unwrap().len(), 3);
        assert_eq!(kept["questions"][1]["multiSelect"], true);
        assert!(
            agent_hook_live_question("PermissionRequest", &claude("PermissionRequest")).is_some()
        );
    }

    #[test]
    fn codex_request_user_input_is_kept_with_ids() {
        let native = json!({"tool_name":"request_user_input","tool_input":{"questions":[
            {"id":"deploy","header":"Deploy","question":"Deploy now?","isOther":true,"options":[{"label":"yes"},{"label":"no"}]}
        ]}});
        let kept: Value =
            serde_json::from_str(&agent_hook_live_question("PreToolUse", &native).unwrap())
                .unwrap();
        assert_eq!(kept["harness"], "codex");
        assert_eq!(kept["questions"][0]["id"], "deploy");
        assert_eq!(kept["questions"][0]["isOther"], true);
    }

    #[test]
    fn other_tools_events_and_empty_questions_are_not_questions() {
        let mut bash = claude("PreToolUse");
        bash["tool_name"] = json!("Bash");
        assert!(agent_hook_live_question("PreToolUse", &bash).is_none());
        assert!(agent_hook_live_question("PostToolUse", &claude("PostToolUse")).is_none());
        let empty =
            json!({"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"  "}]}});
        assert!(agent_hook_live_question("PreToolUse", &empty).is_none());
    }

    #[test]
    fn bounds_hold() {
        let many: Vec<Value> = (0..10)
            .map(|i| json!({"question": "q".repeat(5000), "header": "h".repeat(500),
                "options": (0..20).map(|j| json!({"label": format!("{i}-{j}-{}", "l".repeat(500)), "description": "d".repeat(5000)})).collect::<Vec<_>>()}))
            .collect();
        let native = json!({"tool_name":"AskUserQuestion","tool_input":{"questions":many}});
        let text = agent_hook_live_question("PreToolUse", &native).unwrap();
        assert!(text.len() <= MAX_QUESTION_JSON_BYTES, "{}", text.len());
        let kept: Value = serde_json::from_str(&text).unwrap();
        // Too big with descriptions: they go first, then the last questions.
        assert!(kept["questions"][0]["options"][0].get("description").is_none());
        let count = kept["questions"].as_array().unwrap().len();
        assert!((1..=MAX_QUESTIONS).contains(&count), "{count}");
        assert_eq!(kept["questions"][0]["options"].as_array().unwrap().len(), MAX_OPTIONS);
        assert_eq!(
            kept["questions"][0]["question"].as_str().unwrap().chars().count(),
            QUESTION_CHARS
        );
    }

    #[test]
    fn kept_question_refuses_anything_but_a_question() {
        assert!(kept_question("not json").is_none());
        assert!(kept_question(r#"{"questions":[]}"#).is_none());
        assert!(kept_question(&"x".repeat(MAX_QUESTION_JSON_BYTES + 1)).is_none());
        assert!(
            kept_question(r#"{"harness":"claude","questions":[{"question":"q","options":[]}]}"#)
                .is_some()
        );
    }
}
