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

/// True when policy must not answer the request: a question, or any
/// request a harness marks as needing a person.
pub(super) fn needs_person(request: &Value) -> bool {
    let tool = &request["toolCall"];
    question(request).is_some()
        || tool.pointer("/_meta/acpmux/interactive").and_then(Value::as_bool) == Some(true)
        || tool.pointer("/_meta/claude/interactive").and_then(Value::as_bool) == Some(true)
        || matches!(
            tool.pointer("/_meta/claude/tool").and_then(Value::as_str),
            Some("AskUserQuestion")
        )
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
    let prompt = text(&q["question"])?;
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

/// Checks a client's `answers` for `request`. Answers are accepted only for
/// a question, in the asking harness's shape: Claude Code (and the Chief) by
/// question text with one non-empty string each; Codex by item id with
/// `{answers: [string, ...]}`. Every item must be answered, nothing else.
pub(super) fn check_answers(request: &Value, answers: &Value) -> Result<(), RpcError> {
    let invalid = |why: &str| Err(RpcError::invalid_params(format!("answers {why}")));
    let Some(question) = question(request) else {
        return invalid("are accepted only for a question");
    };
    let Some(answers) = answers.as_object() else { return invalid("must be an object") };
    let items = question["items"].as_array().cloned().unwrap_or_default();
    let codex = question["harness"] == "codex";
    let keys: Vec<String> = items
        .iter()
        .filter_map(|item| if codex { text(&item["id"]) } else { text(&item["prompt"]) })
        .collect();
    if answers.len() != keys.len() || keys.iter().any(|k| !answers.contains_key(k)) {
        return invalid("must answer every question and nothing else");
    }
    for key in &keys {
        let value = &answers[key];
        let ok = if codex {
            value["answers"]
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

#[cfg(test)]
mod tests {
    use super::*;

    fn claude_request() -> Value {
        json!({"toolCall": {"toolCallId": "t", "kind": "other", "rawInput": {"questions": [
            {"question": "Which auth?", "header": "Auth", "multiSelect": false, "options": [
                {"label": "OAuth", "description": "Delegated"}, {"label": "Keys", "preview": "KEY=1"}, {"label": "Keys"}]}]},
            "_meta": {"claude": {"tool": "AskUserQuestion", "interactive": true}}},
            "options": [{"optionId": "allow_once", "kind": "allow_once"}, {"optionId": "reject_once", "kind": "reject_once"}]})
    }

    #[test]
    fn claude_questions_are_normalized() {
        let mut request = claude_request();
        normalize(&mut request);
        let q = question(&request).expect("normalized");
        assert_eq!(q["harness"], "claude");
        assert_eq!(q["items"][0]["id"], "q0");
        assert_eq!(q["items"][0]["header"], "Auth");
        assert_eq!(q["items"][0]["allowsOther"], true);
        assert_eq!(
            q["items"][0]["options"][1]["preview"],
            json!({"text": "KEY=1", "format": "monospace"})
        );
        assert_eq!(q["items"][0]["options"][2]["id"], "Keys#2");
        assert!(needs_person(&request));
    }

    #[test]
    fn codex_questions_key_by_id() {
        let mut request = json!({"toolCall": {"rawInput": {"questions": [
            {"id": "name", "question": "Name?", "options": null}]}, "_meta": {"codex": {}}}});
        normalize(&mut request);
        let q = question(&request).expect("normalized");
        assert_eq!(q["harness"], "codex");
        assert_eq!(q["items"][0]["id"], "name");
        assert_eq!(q["items"][0]["allowsOther"], true);
        assert!(check_answers(&request, &json!({"name": {"answers": ["ledger"]}})).is_ok());
        assert!(check_answers(&request, &json!({"name": {"answers": []}})).is_err());
        assert!(check_answers(&request, &json!({"Name?": "ledger"})).is_err());
    }

    #[test]
    fn an_existing_normalized_question_is_kept() {
        let mut request = json!({"toolCall": {"rawInput": {"questions": [{"question": "raw"}]},
            "_meta": {"acpmux": {"question": {"harness": "chief", "items": [{"id": "q0", "prompt": "kept"}]}}}}});
        normalize(&mut request);
        assert_eq!(question(&request).unwrap()["items"][0]["prompt"], "kept");
    }

    #[test]
    fn claude_answers_must_cover_every_question() {
        let mut request = claude_request();
        normalize(&mut request);
        assert!(check_answers(&request, &json!({"Which auth?": "OAuth"})).is_ok());
        assert!(check_answers(&request, &json!({"Which auth?": " "})).is_err());
        assert!(check_answers(&request, &json!({})).is_err());
        assert!(check_answers(&request, &json!({"Which auth?": "OAuth", "extra": "x"})).is_err());
        assert!(check_answers(&request, &json!("OAuth")).is_err());
    }

    #[test]
    fn answers_for_an_ordinary_tool_are_refused() {
        let mut request = json!({"toolCall": {"kind": "execute", "rawInput": {"command": "ls"}}});
        normalize(&mut request);
        assert!(question(&request).is_none());
        assert!(!needs_person(&request));
        assert!(check_answers(&request, &json!({"command": "rm -rf /"})).is_err());
    }
}
