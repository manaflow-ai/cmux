//! Local Home's question delivery, in the cmux-tui daemon (not the Chief brain).
//! A conversation identity or text is never person authority. The app supplies an existing
//! ACP decision proof; acpmux alone verifies and spends it. No key lives here.

#[cfg(unix)]
use std::time::Duration;

#[cfg(unix)]
use cmux_conversation::QuestionHarness;
#[cfg(any(unix, test))]
use cmux_conversation::QuestionState;
use cmux_conversation::{Question, QuestionAnswer};
#[cfg(any(unix, test))]
use serde::Deserialize;
use serde_json::Value;
#[cfg(any(unix, test))]
use serde_json::json;
#[cfg(any(unix, test))]
use sha2::{Digest, Sha256};

#[cfg(unix)]
use super::super::agent_session_attach::agent_session_link::AcpmuxLink;
use crate::mux::Mux;

#[cfg(unix)]
const TIMEOUT: Duration = Duration::from_secs(3);

#[cfg(unix)]
#[path = "conversation_question_delivery.rs"]
mod delivery;
#[cfg(unix)]
pub(super) use delivery::answer;

/// Ephemeral only: never part of the persisted answer or idempotency fingerprint.
#[cfg(any(unix, test))]
#[derive(Deserialize)]
struct Decision {
    question: Question,
    /// The exact canonical text of the request the daemon returned and the app verified and
    /// signed for: `digest` is the sha256 of these bytes. It is parsed only to compare the
    /// question's items and harness, so no number passes through a lossy value on the way.
    request_json: String,
    digest: String,
    instance: String,
    option_id: String,
    decision_nonce: String,
    person_decision: String,
}

#[derive(Debug)]
pub(super) struct Refusal(pub(super) String);
impl std::fmt::Display for Refusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}
impl std::error::Error for Refusal {}

fn refuse(reason: &str) -> anyhow::Error {
    Refusal(reason.to_owned()).into()
}

// The request's canonical JSON (keys in UTF-8 byte order, as acpmux and the app write it), even in
// serde_json builds with preserve_order enabled.
#[cfg(any(unix, test))]
fn digest(value: &Value) -> String {
    let canonical = cmux_conversation::question_wire::canonical_json(value);
    format!("{:x}", Sha256::digest(canonical.as_bytes()))
}
/// Lowercase hex sha256 of `text`'s bytes: the request digest of its canonical text.
#[cfg(any(unix, test))]
fn text_digest(text: &str) -> String {
    format!("{:x}", Sha256::digest(text.as_bytes()))
}
#[cfg(any(unix, test))]
fn hex64(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
}

/// ACP delivery uses a Unix socket. Other daemon builds refuse without recording an answer.
#[cfg(not(unix))]
pub(super) fn answer(
    _mux: &Mux,
    _client: u64,
    _conversation: &str,
    _key: &str,
    _actor: &str,
    _op: &cmux_conversation::Op,
    _decision: Option<&Value>,
    _transaction: &Option<std::sync::Arc<str>>,
) -> anyhow::Result<crate::conversation_store::OpOutcome> {
    Err(refuse("question.unsupported_platform"))
}

#[cfg(any(unix, test))]
fn decode(question: &Question, value: Option<&Value>) -> anyhow::Result<Decision> {
    let value = value.ok_or_else(|| refuse("question.person_decision_required"))?;
    let decision: Decision =
        serde_json::from_value(value.clone()).map_err(|_| refuse("question.invalid_decision"))?;
    if question.state != QuestionState::Pending
        || decision.question != *question
        || text_digest(&decision.request_json) != decision.digest
    {
        return Err(refuse("question.stale"));
    }
    let request: Value = serde_json::from_str(&decision.request_json)
        .map_err(|_| refuse("question.invalid_decision"))?;
    // Match the stored content to the normalized request, not just a caller-provided hash.
    let mut normalized = request
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

#[cfg(any(unix, test))]
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

/// The one encoder the app signs over (`decision_answers_proof`): a different byte here would make
/// acpmux refuse every Home answer.
#[cfg(any(unix, test))]
fn encode_answers(question: &Question, answer: &QuestionAnswer) -> anyhow::Result<Value> {
    cmux_conversation::question_wire::acpmux_answers(question, answer)
        .map_err(|error| refuse(error.code()))
}

#[cfg(test)]
#[path = "conversation_question_tests.rs"]
mod tests;
