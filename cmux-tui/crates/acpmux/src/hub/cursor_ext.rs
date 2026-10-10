//! Cursor's `cursor/` extension requests (cx-1785). `cursor-agent acp`
//! (https://cursor.com/docs/cli/acp) asks the client two things outside
//! plain ACP and blocks until it answers:
//!
//! - `cursor/ask_question` (`{toolCallId, title?, questions: [{id, prompt,
//!   options: [{id, label}], allowMultiple?}]}`): answered
//!   `{outcome: {outcome: "answered", answers: [{questionId,
//!   selectedOptionIds}]}}`, `{outcome: {outcome: "skipped"}}` or
//!   `{outcome: {outcome: "cancelled"}}`;
//! - `cursor/create_plan` (`{toolCallId, name?, overview?, plan, todos}`):
//!   answered `{outcome: {outcome: "accepted" | "rejected" | "cancelled"}}`.
//!
//! Each becomes one `session/request_permission` through the hub's normal
//! path, like Grok's (xai.rs). Cursor's notifications (`cursor/update_todos`,
//! `cursor/task`, `cursor/generate_image`) need no reply.

use super::*;
use std::collections::HashSet;

/// Which `cursor/` request a method is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum CursorRequest {
    AskQuestion,
    CreatePlan,
}

/// The `cursor/` request `method` names.
pub(super) fn request_kind(method: &str) -> Option<CursorRequest> {
    match method {
        "cursor/ask_question" => Some(CursorRequest::AskQuestion),
        "cursor/create_plan" => Some(CursorRequest::CreatePlan),
        _ => None,
    }
}

const ANSWER: &str = "allow_once";
const SKIP: &str = "reject_once";
const ACCEPT_PLAN: &str = "accept";
const REJECT_PLAN: &str = "reject";

/// One of Cursor's questions, checked: its id as sent (the reply echoes
/// it), its trimmed id (the answer key), its prompt, and its options as
/// `(label, id)` with labels made unique so a label names one option.
#[derive(Debug, Clone, PartialEq)]
struct Asked {
    id: String,
    key: String,
    prompt: String,
    multi: bool,
    options: Vec<(String, String)>,
}

/// Cursor's questions, checked. Refused: no question, a question without
/// an id or prompt, a repeated id, or a question with no option that has
/// both an id and a label (Cursor's answer holds option ids only, so a free
/// answer would be lost).
fn asked(params: &Value) -> Result<Vec<Asked>, &'static str> {
    let questions = params["questions"]
        .as_array()
        .filter(|q| !q.is_empty())
        .ok_or("questions must be a non-empty array")?;
    let mut keys = HashSet::new();
    let mut out = Vec::new();
    for q in questions {
        let id = q["id"].as_str().ok_or("every question needs an id")?;
        let key = id.trim();
        let prompt = q["prompt"].as_str().map(str::trim).filter(|p| !p.is_empty());
        let prompt = prompt.ok_or("every question needs a prompt")?;
        if key.is_empty() {
            return Err("every question needs an id");
        }
        if !keys.insert(key.to_owned()) {
            return Err("question ids must be unique");
        }
        let mut labels = HashSet::new();
        let mut options = Vec::new();
        for o in q["options"].as_array().into_iter().flatten() {
            let (Some(label), Some(option_id)) = (
                o["label"].as_str().map(str::trim).filter(|l| !l.is_empty()),
                o["id"].as_str().filter(|i| !i.trim().is_empty()),
            ) else {
                continue;
            };
            let mut unique = label.to_owned();
            let mut n = 2;
            while !labels.insert(unique.clone()) {
                unique = format!("{label} ({n})");
                n += 1;
            }
            options.push((unique, option_id.to_owned()));
        }
        if options.is_empty() {
            return Err("every question needs at least one option with an id and a label");
        }
        out.push(Asked {
            id: id.to_owned(),
            key: key.to_owned(),
            prompt: prompt.to_owned(),
            multi: q["allowMultiple"].as_bool().unwrap_or(false),
            options,
        });
    }
    Ok(out)
}

/// The permission request that asks the checked questions, in the Codex
/// shape (`{id, question, options: [{label}], multiSelect}`, answered by id
/// with `{answers: [labels]}`).
fn question_request(params: &Value, questions: &[Asked]) -> Value {
    let raw: Vec<Value> = questions
        .iter()
        .map(|q| {
            let options: Vec<Value> =
                q.options.iter().map(|(label, _)| json!({"label": label})).collect();
            json!({"id": q.key, "question": q.prompt, "options": options,
                   "multiSelect": q.multi, "isOther": false})
        })
        .collect();
    let items = super::questions::items_by_id(&raw);
    let title =
        params["title"].as_str().map(str::trim).filter(|t| !t.is_empty()).unwrap_or("Question");
    json!({
        "toolCall": {
            "toolCallId": params["toolCallId"].as_str().unwrap_or("cursor/ask_question"),
            "title": title,
            "kind": "other",
            "status": "pending",
            "rawInput": {"questions": raw},
            // `harness` names the answer's wire shape (by item id, like
            // Codex); `agent` names who asked.
            "_meta": {"acpmux": {"question": {"harness": "codex", "agent": "Cursor", "items": items}}},
        },
        "options": [
            {"optionId": ANSWER, "name": "Answer", "kind": "allow_once"},
            {"optionId": SKIP, "name": "Skip", "kind": "reject_once"},
        ],
    })
}

/// The option ids `labels` names, in option order; one at most for a
/// single-select question.
fn option_ids(question: &Asked, labels: &[&str]) -> Vec<String> {
    let mut ids: Vec<String> = question
        .options
        .iter()
        .filter(|(label, _)| labels.contains(&label.as_str()))
        .map(|(_, id)| id.clone())
        .collect();
    if !question.multi {
        ids.truncate(1);
    }
    ids
}

/// Cursor's reply to the checked questions from the permission outcome. An
/// answer that names no option of a question skips the whole ask: Cursor
/// cannot take a free answer.
fn question_reply(questions: &[Asked], outcome: &Value) -> Value {
    match outcome.pointer("/outcome/optionId").and_then(Value::as_str) {
        Some(ANSWER) => {}
        Some(_) => return json!({"outcome": {"outcome": "skipped"}}),
        None => return json!({"outcome": {"outcome": "cancelled"}}),
    }
    let given = outcome.pointer("/_meta/updatedInput/answers").cloned().unwrap_or(json!({}));
    let mut answers = Vec::new();
    for question in questions {
        let pointer = format!("/{}/answers", question.key.replace('~', "~0").replace('/', "~1"));
        let labels: Vec<&str> = given
            .pointer(&pointer)
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|l| l.as_str().map(str::trim))
            .collect();
        let ids = option_ids(question, &labels);
        if ids.is_empty() {
            return json!({"outcome": {"outcome": "skipped", "reason": "no option was picked"}});
        }
        answers.push(json!({"questionId": question.id, "selectedOptionIds": ids}));
    }
    json!({"outcome": {"outcome": "answered", "answers": answers}})
}

/// The permission request that approves `params`' plan.
fn plan_request(params: &Value) -> Value {
    let plan = params["plan"].as_str().map(str::trim).unwrap_or("");
    let name = params["name"].as_str().map(str::trim).filter(|n| !n.is_empty());
    let mut tool = json!({
        "toolCallId": params["toolCallId"].as_str().unwrap_or("cursor/create_plan"),
        "title": name.unwrap_or("Ready to code?"),
        "kind": "switch_mode",
        "status": "pending",
        "rawInput": {"plan": plan, "todos": params["todos"]},
    });
    if !plan.is_empty() {
        tool["content"] = json!([{"type": "content", "content": {"type": "text", "text": plan}}]);
    }
    json!({
        "toolCall": tool,
        "options": [
            {"optionId": ACCEPT_PLAN, "name": "Yes, start coding", "kind": "allow_once"},
            {"optionId": REJECT_PLAN, "name": "No, keep planning", "kind": "reject_once"},
        ],
    })
}

/// Cursor's reply to a plan approval from the permission outcome.
fn plan_reply(outcome: &Value) -> Value {
    let verdict = match outcome.pointer("/outcome/optionId").and_then(Value::as_str) {
        Some(ACCEPT_PLAN) => "accepted",
        Some(_) => "rejected",
        None => "cancelled",
    };
    json!({"outcome": {"outcome": verdict}})
}

impl Hub {
    /// Asks a `cursor/` request through the permission path and answers it
    /// in Cursor's shape. A cancel answers `cancelled`, so Cursor's turn
    /// never waits on a dead ask.
    pub(super) async fn handle_cursor_request(
        self: &Arc<Self>,
        session: &Arc<Session>,
        kind: CursorRequest,
        params: Value,
        epoch: u64,
        turn_id: Option<String>,
    ) -> Result<Value, RpcError> {
        if !params.is_object() {
            return Err(RpcError::invalid_params("cursor request params must be an object"));
        }
        let questions = match kind {
            CursorRequest::AskQuestion => asked(&params).map_err(RpcError::invalid_params)?,
            CursorRequest::CreatePlan => Vec::new(),
        };
        let mut request = match kind {
            CursorRequest::AskQuestion => question_request(&params, &questions),
            CursorRequest::CreatePlan => plan_request(&params),
        };
        // The agent's own session id, as in its session/request_permission.
        request["sessionId"] = json!(session.meta().agent_session_id);
        let outcome = self.handle_permission_for(session, request, epoch, turn_id, None).await;
        Ok(match kind {
            CursorRequest::AskQuestion => question_reply(&questions, &outcome),
            CursorRequest::CreatePlan => plan_reply(&outcome),
        })
    }
}
