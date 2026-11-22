//! Grok's x.ai extension requests (cx-1785). `grok agent stdio` asks the
//! client two things outside plain ACP:
//!
//! - `x.ai/ask_user_question` (`{sessionId, toolCallId, questions: [{id?,
//!   question, options: [{label, description?, preview?}], multiSelect?}],
//!   mode}`): answered `{outcome: "accepted", answers: {<question text>:
//!   [<label>, ...]}, annotations?}` or `{outcome: "cancelled"}`;
//! - `x.ai/exit_plan_mode` (`{sessionId, toolCallId, planContent?}`):
//!   answered `{outcome: "approved" | "request_changes" | "abandoned"}`.
//!
//! Both may come with a leading underscore and may wrap their params as
//! `{method, params}`. Each becomes one `session/request_permission` through
//! the hub's normal path, so every client shows it, rules and records apply,
//! and a question is answered only by a person (questions.rs).
//!
//! The request and reply shapes follow t3code's Grok integration
//! (apps/server/src/provider/acp/XAiAcpExtension.ts).
//! Portions adapted from t3code, Copyright (c) 2026 T3 Tools Inc., MIT License
//! (https://github.com/pingdotgg/t3code; see THIRD_PARTY_LICENSES.md).

use super::*;
use serde_json::Map;

/// Which x.ai request a method is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum XaiRequest {
    AskUserQuestion,
    ExitPlanMode,
}

/// The x.ai request `method` names, with or without the `_` prefix.
pub(super) fn request_kind(method: &str) -> Option<XaiRequest> {
    match method.strip_prefix('_').unwrap_or(method) {
        "x.ai/ask_user_question" => Some(XaiRequest::AskUserQuestion),
        "x.ai/exit_plan_mode" => Some(XaiRequest::ExitPlanMode),
        _ => None,
    }
}

/// The params, unwrapped from `{method, params}` when Grok wraps them.
fn unwrap(params: Value) -> Value {
    match params.get("params") {
        Some(inner) if params.get("method").is_some() => inner.clone(),
        _ => params,
    }
}

// The question options keep the ids Claude's AskUserQuestion uses, so a
// client that answers questions by `allow_once` answers Grok's too.
const ANSWER: &str = "allow_once";
const DECLINE: &str = "reject_once";
const APPROVE_PLAN: &str = "approve";
const KEEP_PLANNING: &str = "keep-planning";

/// The permission request that asks `params`' questions.
fn question_request(params: &Value) -> Value {
    let questions = params["questions"].as_array().cloned().unwrap_or_default();
    let items = super::questions::items_by_text(&questions);
    json!({
        "sessionId": params["sessionId"],
        "toolCall": {
            "toolCallId": params["toolCallId"].as_str().unwrap_or("x.ai/ask_user_question"),
            "title": "Question",
            "kind": "other",
            "status": "pending",
            "rawInput": {"questions": questions},
            // `harness` names the answer's wire shape for every client
            // (CmuxAgentQuestion, the web pane, the TUI): Grok's answers are
            // keyed by question text like Claude's, so it asks as `claude`;
            // `agent` names who asked.
            "_meta": {"acpmux": {"question": {"harness": "claude", "agent": "Grok", "items": items}}},
        },
        "options": [
            {"optionId": ANSWER, "name": "Answer", "kind": "allow_once"},
            {"optionId": DECLINE, "name": "Decline", "kind": "reject_once"},
        ],
    })
}

/// One answer's picks: `(labels, notes, preview)`. A multi-select answer is
/// the picks joined by ", " (the question model's one string per item), each
/// part mapped on its own; text that is not a label is a free answer, sent
/// as `Other` with the text as a note. A single pick of an option with a
/// preview returns that preview (t3code's annotation).
fn picked(question: &Value, answer: &str) -> (Vec<String>, Vec<String>, Option<String>) {
    let options: Vec<(&str, Option<&str>)> = question["options"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|o| {
            let label = o["label"].as_str()?.trim();
            (!label.is_empty())
                .then(|| (label, o["preview"].as_str().map(str::trim).filter(|p| !p.is_empty())))
        })
        .collect();
    let find = |part: &str| options.iter().find(|(label, _)| *label == part);
    let multi = question["multiSelect"].as_bool() == Some(true);
    let answer = answer.trim();
    let parts: Vec<&str> = if multi && find(answer).is_none() {
        answer.split(", ").map(str::trim).filter(|p| !p.is_empty()).collect()
    } else if answer.is_empty() {
        vec![]
    } else {
        vec![answer]
    };
    let (mut chosen, mut notes) = (Vec::new(), Vec::new());
    for part in parts {
        match find(part) {
            Some((label, _)) => chosen.push((*label).to_owned()),
            None => notes.push(part.to_owned()),
        }
    }
    let preview = match (multi, chosen.as_slice()) {
        (false, [label]) => find(label).and_then(|(_, p)| p.map(str::to_owned)),
        _ => None,
    };
    if chosen.is_empty() && !notes.is_empty() {
        chosen.push("Other".to_owned());
    }
    (chosen, notes, preview)
}

/// Grok's reply to a question from the permission outcome.
fn question_reply(params: &Value, outcome: &Value) -> Value {
    if outcome.pointer("/outcome/optionId").and_then(Value::as_str) != Some(ANSWER) {
        return json!({"outcome": "cancelled"});
    }
    let given = outcome.pointer("/_meta/updatedInput/answers").cloned().unwrap_or(json!({}));
    let mut answers = Map::new();
    let mut annotations = Map::new();
    for question in params["questions"].as_array().into_iter().flatten() {
        let Some(text) = question["question"].as_str() else { continue };
        let Some(answer) = given.get(text).and_then(Value::as_str) else { continue };
        let (chosen, notes, preview) = picked(question, answer);
        if chosen.is_empty() {
            continue;
        }
        let mut annotation = Map::new();
        if let Some(preview) = preview {
            annotation.insert("preview".into(), json!(preview));
        }
        if !notes.is_empty() {
            annotation.insert("notes".into(), json!(notes.join("\n")));
        }
        if !annotation.is_empty() {
            annotations.insert(text.to_owned(), Value::Object(annotation));
        }
        answers.insert(text.to_owned(), json!(chosen));
    }
    let mut reply = json!({"outcome": "accepted", "answers": answers});
    if !annotations.is_empty() {
        reply["annotations"] = Value::Object(annotations);
    }
    reply
}

/// Why `params`' questions cannot be asked: none with text, or two with
/// the same text (Grok's answers are keyed by text, so a person could
/// answer neither).
fn unaskable(params: &Value) -> Option<&'static str> {
    let questions = params["questions"].as_array()?;
    let items = super::questions::items_by_text(questions);
    if items.is_empty() {
        return Some("questions must hold at least one question with text");
    }
    let mut seen = std::collections::HashSet::new();
    if items.iter().any(|item| !seen.insert(item["prompt"].as_str().unwrap_or_default().to_owned()))
    {
        return Some("question texts must be unique");
    }
    None
}

/// The permission request that approves leaving plan mode with `params`' plan.
fn plan_request(params: &Value) -> Value {
    let plan = params["planContent"].as_str().map(str::trim).unwrap_or("");
    let mut tool = json!({
        "toolCallId": params["toolCallId"].as_str().unwrap_or("x.ai/exit_plan_mode"),
        "title": "Ready to code?",
        "kind": "switch_mode",
        "status": "pending",
        "rawInput": {"plan": plan},
    });
    if !plan.is_empty() {
        tool["content"] = json!([{"type": "content", "content": {"type": "text", "text": plan}}]);
    }
    json!({
        "sessionId": params["sessionId"],
        "toolCall": tool,
        "options": [
            {"optionId": APPROVE_PLAN, "name": "Yes, start coding", "kind": "allow_once"},
            {"optionId": KEEP_PLANNING, "name": "No, keep planning", "kind": "reject_once"},
        ],
    })
}

/// Grok's reply to a plan approval from the permission outcome.
fn plan_reply(outcome: &Value) -> Value {
    match outcome.pointer("/outcome/optionId").and_then(Value::as_str) {
        Some(APPROVE_PLAN) => json!({"outcome": "approved"}),
        Some(KEEP_PLANNING) => json!({"outcome": "request_changes"}),
        _ => json!({"outcome": "abandoned"}),
    }
}

impl Hub {
    /// Asks an x.ai request through the permission path and answers it in
    /// Grok's shape. A cancel (turn end, stop) answers `cancelled` /
    /// `abandoned`, so Grok's turn never waits on a dead ask.
    pub(super) async fn handle_xai_request(
        self: &Arc<Self>,
        session: &Arc<Session>,
        kind: XaiRequest,
        params: Value,
        epoch: u64,
        turn_id: Option<String>,
    ) -> Result<Value, RpcError> {
        let params = unwrap(params);
        if !params.is_object() {
            return Err(RpcError::invalid_params("x.ai request params must be an object"));
        }
        Ok(match kind {
            XaiRequest::AskUserQuestion => {
                if params["questions"].as_array().is_none_or(Vec::is_empty) {
                    return Err(RpcError::invalid_params("questions must be a non-empty array"));
                }
                if let Some(why) = unaskable(&params) {
                    return Err(RpcError::invalid_params(why));
                }
                let request = question_request(&params);
                let outcome =
                    self.handle_permission_for(session, request, epoch, turn_id, None).await;
                question_reply(&params, &outcome)
            }
            XaiRequest::ExitPlanMode => {
                let request = plan_request(&params);
                let outcome =
                    self.handle_permission_for(session, request, epoch, turn_id, None).await;
                plan_reply(&outcome)
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn both_method_spellings_are_recognized() {
        assert_eq!(request_kind("x.ai/ask_user_question"), Some(XaiRequest::AskUserQuestion));
        assert_eq!(request_kind("_x.ai/exit_plan_mode"), Some(XaiRequest::ExitPlanMode));
        assert_eq!(request_kind("x.ai/task_completed"), None);
        assert_eq!(request_kind("session/request_permission"), None);
    }

    #[test]
    fn wrapped_params_are_unwrapped() {
        let wrapped = json!({"method": "x.ai/exit_plan_mode", "params": {"sessionId": "s"}});
        assert_eq!(unwrap(wrapped), json!({"sessionId": "s"}));
        assert_eq!(unwrap(json!({"sessionId": "s"})), json!({"sessionId": "s"}));
    }

    #[test]
    fn multi_select_and_free_answers_map_to_labels_and_notes() {
        let q = json!({"question": "Which?", "multiSelect": true,
            "options": [{"label": " A "}, {"label": "B"}]});
        assert_eq!(picked(&q, "A, B"), (vec!["A".to_owned(), "B".to_owned()], vec![], None));
        assert_eq!(
            picked(&q, "A, custom"),
            (vec!["A".to_owned()], vec!["custom".to_owned()], None)
        );
        assert_eq!(
            picked(&q, "something else"),
            (vec!["Other".to_owned()], vec!["something else".to_owned()], None)
        );
        let single = json!({"question": "Which?", "options": [{"label": "A, B", "preview": "ab"}]});
        assert_eq!(
            picked(&single, "A, B"),
            (vec!["A, B".to_owned()], vec![], Some("ab".to_owned()))
        );
    }

    #[test]
    fn a_free_answer_rides_as_an_annotation() {
        let params = json!({"questions": [{"question": "Name?", "options": [{"label": "A"}]}]});
        let outcome = json!({"outcome": {"outcome": "selected", "optionId": ANSWER},
            "_meta": {"updatedInput": {"answers": {"Name?": "Zed"}}}});
        assert_eq!(
            question_reply(&params, &outcome),
            json!({"outcome": "accepted", "answers": {"Name?": ["Other"]},
                   "annotations": {"Name?": {"notes": "Zed"}}})
        );
    }

    #[test]
    fn questions_nobody_could_answer_are_refused() {
        let blank = json!({"questions": [{"question": "  ", "options": []}]});
        assert!(unaskable(&blank).is_some());
        let twice = json!({"questions": [{"question": "Same?"}, {"question": "Same?"}]});
        assert_eq!(unaskable(&twice), Some("question texts must be unique"));
        let fine = json!({"questions": [{"question": "One?"}, {"question": "Two?"}]});
        assert_eq!(unaskable(&fine), None);
    }

    #[test]
    fn a_cancelled_plan_is_abandoned() {
        assert_eq!(
            plan_reply(&json!({"outcome": {"outcome": "cancelled"}})),
            json!({"outcome": "abandoned"})
        );
    }
}
