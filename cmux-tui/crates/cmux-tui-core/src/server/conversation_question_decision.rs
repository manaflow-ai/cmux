//! `conversation-question-decision`: what Home's native card has the person sign before it answers
//! a Chief question (`conversation-question-decision-v1`).
//!
//! The daemon reads the stored question and the live acpmux prompt it names, checks they are the
//! same question, and returns the unsigned decision ([`cmux_conversation::question_wire`]): the
//! prompt's run (`personInstance`), its one-use `decisionNonce`, the answer's option and the exact
//! `answers` the daemon will send. The app checks the run, nonce and request digest against its
//! own person-proven read of the same prompt, signs `decision_answers_proof` with the key it keeps
//! in memory, and sends the proof as the `question.answer` op's ephemeral `decision`. Nothing here
//! holds or sees a key, and a result grants nothing: acpmux alone verifies and spends the proof.

use cmux_conversation::question_wire::{self, UnsignedDecision, WireError};
use cmux_conversation::{Part, Question, QuestionAnswer};
use serde::Deserialize;
use serde_json::Value;

use crate::mux::Mux;

/// Advertised only where the daemon reaches acpmux (a Unix socket).
#[cfg(unix)]
pub const CAPABILITY: &str = "conversation-question-decision-v1";

#[derive(Deserialize)]
pub(in crate::server) struct DecisionParams {
    conversation: String,
    message_id: String,
    part_index: usize,
    answer: QuestionAnswer,
}

/// A refusal with a stable code (`question.*`), as the reply's error text.
#[derive(Debug)]
pub(in crate::server) struct DecisionRefused(pub &'static str);
impl std::fmt::Display for DecisionRefused {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.0)
    }
}
impl std::error::Error for DecisionRefused {}

fn refused(code: &'static str) -> anyhow::Error {
    DecisionRefused(code).into()
}

/// The refusal's code, for the reply's `code` field (responses.rs).
pub(super) fn error_code(error: &anyhow::Error) -> Option<String> {
    error.downcast_ref::<DecisionRefused>().map(|refused| refused.0.to_owned())
}

impl From<WireError> for DecisionRefused {
    fn from(error: WireError) -> Self {
        Self(error.code())
    }
}

/// The stored question part `message_id`/`part_index` of `conversation`.
fn stored_question(mux: &Mux, params: &DecisionParams) -> anyhow::Result<Question> {
    let message = mux
        .with_conversations(|store| store.message(&params.message_id))?
        .filter(|message| message.conversation == params.conversation)
        .ok_or_else(|| refused("question.not_found"))?;
    match message.parts.get(params.part_index) {
        Some(Part::Question(question)) => Ok(question.clone()),
        _ => Err(refused("question.not_found")),
    }
}

/// The reply: the unsigned decision, the stored question, and the live request it was read from
/// with its digest (sha256 of its JSON with keys sorted), which the app compares with its own read
/// of the prompt. With the person's proof added, the reply's `question`, `request`, `digest`,
/// `instance`, `option_id` and `decision_nonce` are the `question.answer` op's `decision`.
fn reply(
    question: &Question,
    decision: UnsignedDecision,
    request: &Value,
) -> anyhow::Result<Value> {
    let mut value = serde_json::to_value(decision)?;
    value["question"] = serde_json::to_value(question)?;
    value["request"] = request.clone();
    value["digest"] = Value::String(request_digest(request));
    Ok(value)
}

/// Lowercase hex sha256 of `request` as compact JSON with every object's keys sorted.
pub(in crate::server) fn request_digest(request: &Value) -> String {
    use sha2::{Digest, Sha256};
    fn sorted(value: &Value) -> Value {
        match value {
            Value::Object(map) => {
                let keys: std::collections::BTreeMap<_, _> = map.iter().collect();
                Value::Object(keys.into_iter().map(|(k, v)| (k.clone(), sorted(v))).collect())
            }
            Value::Array(items) => Value::Array(items.iter().map(sorted).collect()),
            other => other.clone(),
        }
    }
    format!("{:x}", Sha256::digest(sorted(request).to_string().as_bytes()))
}

/// The unsigned decision from `pending`, the prompt's live `_acpmux/info` pending entries.
pub(in crate::server) fn decide_from(
    question: &Question,
    answer: &QuestionAnswer,
    info: &Value,
) -> anyhow::Result<Value> {
    if !info.get("peer").is_none_or(Value::is_null) {
        // A peer's prompt is that machine's to decide; its key is not this app's.
        return Err(refused("question.not_local"));
    }
    if question_wire::is_native_approval(question) {
        // A tool-permission card: the app answers acpmux natively and only records the card.
        return Err(refused("question.native_approval"));
    }
    let permission =
        question.permission.as_deref().ok_or_else(|| refused("question.no_request"))?;
    let entry = info
        .get("pending")
        .and_then(Value::as_array)
        .and_then(|entries| {
            entries
                .iter()
                .find(|entry| entry.get("permissionId").and_then(Value::as_str) == Some(permission))
        })
        .ok_or_else(|| refused("question.closed"))?;
    let decision = question_wire::unsigned_decision(question, answer, entry)
        .map_err(|error| anyhow::Error::from(DecisionRefused::from(error)))?;
    reply(question, decision, &entry["request"])
}

#[cfg(unix)]
pub(in crate::server) fn decision(mux: &Mux, params: DecisionParams) -> anyhow::Result<Value> {
    use super::agent_session_attach::agent_session_link::{AcpmuxLink, LinkError};
    use serde_json::json;
    use std::time::Duration;

    let question = stored_question(mux, &params)?;
    let socket = mux
        .control_clients
        .agent_sessions
        .socket()
        .ok_or_else(|| refused("question.agent_gone"))?;
    let link = AcpmuxLink::connect(&socket, |_| {}).map_err(|_| refused("question.agent_gone"))?;
    let call = |method: &str, params: Value| {
        link.call(method, params, Duration::from_secs(3)).map_err(|error| {
            refused(match error {
                LinkError::Closed => "question.agent_gone",
                LinkError::Timeout => "question.agent_busy",
                _ => "question.refused",
            })
        })
    };
    let result = call(
        "initialize",
        json!({"protocolVersion": 1, "clientCapabilities": {},
               "clientInfo": {"name": "cmux-home-question-decision", "version": "1"}}),
    )
    .and_then(|_| call("_acpmux/info", json!({"sessionId": question.session})))
    .and_then(|info| decide_from(&question, &params.answer, &info));
    link.close();
    result
}

/// Other daemon builds reach no acpmux: they refuse, and do not advertise the capability.
#[cfg(not(unix))]
pub(in crate::server) fn decision(_mux: &Mux, _params: DecisionParams) -> anyhow::Result<Value> {
    Err(refused("question.unsupported_platform"))
}

#[cfg(test)]
#[path = "conversation_question_decision_tests.rs"]
mod tests;
