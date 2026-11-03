//! Local Home's question delivery, in the cmux-tui daemon (not the Chief brain).
//! A conversation identity or text is never person authority. The app supplies an existing
//! ACP decision proof; acpmux alone verifies and spends it. No key lives here.

use std::time::Duration;

use cmux_conversation::{Question, QuestionAnswer, QuestionHarness, QuestionState};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::super::agent_session_attach::agent_session_link::AcpmuxLink;
use crate::mux::Mux;

const TIMEOUT: Duration = Duration::from_secs(3);

/// Ephemeral only: never part of the persisted answer or idempotency fingerprint.
#[derive(Deserialize)]
struct Decision {
    question: Question,
    request: Value,
    digest: String,
    instance: String,
    option_id: String,
    decision_nonce: String,
    person_decision: String,
}

#[derive(Debug)]
pub(super) struct Refusal(pub(super) &'static str);
impl std::fmt::Display for Refusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.0)
    }
}
impl std::error::Error for Refusal {}

fn refuse(reason: &'static str) -> anyhow::Error {
    Refusal(reason).into()
}

// Recursively sort keys, even in serde_json builds with preserve_order enabled.
fn canonical(value: &Value) -> Value {
    match value {
        Value::Object(map) => {
            let sorted: std::collections::BTreeMap<_, _> = map.iter().collect();
            Value::Object(sorted.into_iter().map(|(k, v)| (k.clone(), canonical(v))).collect())
        }
        Value::Array(items) => Value::Array(items.iter().map(canonical).collect()),
        _ => value.clone(),
    }
}
fn digest(value: &Value) -> String {
    format!("{:x}", Sha256::digest(canonical(value).to_string().as_bytes()))
}
fn hex64(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
}

pub(super) fn deliver(
    mux: &Mux,
    question: &Question,
    answer: &QuestionAnswer,
    decision: Option<&Value>,
) -> anyhow::Result<()> {
    let decision = decode(question, decision)?;
    let socket =
        mux.control_clients.agent_sessions.socket().ok_or_else(|| refuse("question.agent_gone"))?;
    let link = AcpmuxLink::connect(&socket, |_| {}).map_err(|_| refuse("question.agent_gone"))?;
    let result = deliver_with(question, answer, &decision, |method, params| {
        link.call(method, params, TIMEOUT).map_err(|error| {
            use super::super::agent_session_attach::agent_session_link::LinkError;
            refuse(match error {
                LinkError::Timeout => "question.delivery_unknown",
                LinkError::Closed => "question.agent_gone",
                _ => "question.refused",
            })
        })
    });
    link.close();
    result
}

fn decode(question: &Question, value: Option<&Value>) -> anyhow::Result<Decision> {
    let value = value.ok_or_else(|| refuse("question.person_decision_required"))?;
    if value.to_string().len() > 128 * 1024 {
        return Err(refuse("question.invalid_decision"));
    }
    let decision: Decision =
        serde_json::from_value(value.clone()).map_err(|_| refuse("question.invalid_decision"))?;
    if question.state != QuestionState::Pending
        || decision.question != *question
        || digest(&decision.request) != decision.digest
    {
        return Err(refuse("question.stale"));
    }
    // Match the stored content to the normalized request, not just a caller-provided hash.
    let mut normalized = decision
        .request
        .pointer("/toolCall/_meta/acpmux/question")
        .cloned()
        .ok_or_else(|| refuse("question.not_question"))?;
    let items = normalized
        .get_mut("items")
        .and_then(Value::as_array_mut)
        .ok_or_else(|| refuse("question.not_question"))?;
    for item in items {
        if let Some(map) = item.as_object_mut() {
            for (from, to) in [("multiSelect", "multi_select"), ("allowsOther", "allows_other")] {
                if let Some(value) = map.remove(from) {
                    map.insert(to.to_owned(), value);
                }
            }
        }
    }
    let request_items: Vec<cmux_conversation::QuestionItem> =
        serde_json::from_value(normalized["items"].clone())
            .map_err(|_| refuse("question.stale"))?;
    if request_items != question.items
        || normalized["harness"] != serde_json::to_value(question.harness)?
    {
        return Err(refuse("question.stale"));
    }
    if !hex64(&decision.person_decision)
        || !hex64(&decision.decision_nonce)
        || decision.instance.is_empty()
        || decision.option_id.is_empty()
    {
        return Err(refuse("question.invalid_decision"));
    }
    Ok(decision)
}

fn deliver_with(
    question: &Question,
    answer: &QuestionAnswer,
    decision: &Decision,
    mut call: impl FnMut(&str, Value) -> anyhow::Result<Value>,
) -> anyhow::Result<()> {
    let permission = question.permission.as_deref().ok_or_else(|| refuse("question.no_request"))?;
    call(
        "initialize",
        json!({"protocolVersion":1,
        "clientInfo":{"name":"cmux-home-question","version":"1"},"clientCapabilities":{}}),
    )?;
    let info = call("_acpmux/info", json!({"sessionId":question.session}))?;
    if !info.get("peer").is_none_or(Value::is_null) {
        return Err(refuse("question.not_local"));
    }
    let entry = info
        .get("pending")
        .and_then(Value::as_array)
        .and_then(|entries| entries.iter().find(|p| p["permissionId"] == permission))
        .ok_or_else(|| refuse("question.closed"))?;
    if entry["personInstance"] != decision.instance
        || entry["decisionNonce"] != decision.decision_nonce
        || entry.get("request").is_none_or(|request| digest(request) != decision.digest)
    {
        return Err(refuse("question.stale"));
    }
    let request = &entry["request"];
    // This route answers questions only. It never translates a tool permission into a question.
    if request.pointer("/toolCall/_meta/acpmux/question/items").and_then(Value::as_array).is_none()
    {
        return Err(refuse("question.not_question"));
    }
    let offered: Vec<_> = request["options"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|option| option["optionId"] == decision.option_id && option["kind"] == "allow_once")
        .collect();
    if offered.len() != 1 {
        return Err(refuse("question.stale"));
    }
    let answers = encode_answers(question, answer)?;
    // acpmux validates the nonce, option and actual answers under its pending-request lock.
    call(
        "_acpmux/permission_respond",
        json!({
            "sessionId":question.session,"permissionId":permission,"optionId":decision.option_id,
            "answers":answers,"_meta":{"acpmux":{
                "decisionNonce":decision.decision_nonce,"personDecision":decision.person_decision
            }}
        }),
    )?;
    Ok(())
}

fn encode_answers(question: &Question, answer: &QuestionAnswer) -> anyhow::Result<Value> {
    let mut answers = serde_json::Map::new();
    for item in &question.items {
        let selection =
            answer.selections.get(&item.id).ok_or_else(|| refuse("question.invalid_answer"))?;
        let mut labels: Vec<_> = item
            .options
            .iter()
            .filter(|o| selection.option_ids.contains(&o.id))
            .map(|o| o.label.clone())
            .collect();
        if let Some(other) = &selection.other {
            labels.push(other.trim().to_owned());
        }
        match question.harness {
            QuestionHarness::Claude | QuestionHarness::Chief => {
                if answers.insert(item.prompt.clone(), json!(labels.join(", "))).is_some() {
                    return Err(refuse("question.ambiguous"));
                }
            }
            QuestionHarness::Codex => {
                answers.insert(item.id.clone(), json!({"answers":labels}));
            }
            QuestionHarness::Acp => return Err(refuse("question.unsupported_harness")),
        }
    }
    Ok(Value::Object(answers))
}

#[cfg(test)]
#[path = "conversation_question_tests.rs"]
mod tests;
